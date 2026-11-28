defmodule VoelgoedAi.Support.BindingCircuit do
  @moduledoc """
  Persists a read-only recovery probe and a write gate for each integration.
  Callers hold the binding lock. A probe lease prevents a worker crash from
  blocking recovery indefinitely, and its generation fences late results.
  """

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  @threshold 5
  @cooldown 60
  @probe_lease 2

  def label(binding) do
    {_, _, retry_at, probe_until} = state(binding)

    projection_label(
      retry_at,
      probe_until,
      permanent_epoch(binding),
      VoelgoedAi.Support.ChatwootAdapter.now()
    )
  end

  @doc false
  def projection_label(nil, nil, _, _), do: :closed

  def projection_label(_, %DateTime{} = probe_until, permanent_epoch, now) do
    if DateTime.before?(now, probe_until),
      do: :probe_pending,
      else: open_label(permanent_epoch)
  end

  def projection_label(_, _, permanent_epoch, _), do: open_label(permanent_epoch)

  defp open_label(permanent_epoch),
    do: if(permanent_epoch, do: :configuration_inhibited, else: :open)

  def reserve_for_admin(binding, now) do
    case permanent_epoch(binding) do
      nil ->
        reserve(binding, now)

      epoch when epoch < binding.security_epoch ->
        {generation, failures, retry_at, probe_until} = state(binding)

        if probe_until == nil or not DateTime.before?(now, probe_until) do
          save(binding, generation + 1, failures, retry_at, DateTime.add(now, @probe_lease))
          {:probe, generation + 1}
        else
          :open
        end

      _ ->
        :open
    end
  end

  def reserve(binding, now) do
    {generation, failures, retry_at, probe_until} = state(binding)

    cond do
      retry_at == nil ->
        {:closed, generation}

      permanent_epoch(binding) != nil or DateTime.before?(now, retry_at) ->
        :open

      probe_until != nil and DateTime.before?(now, probe_until) ->
        :open

      true ->
        save(binding, generation + 1, failures, retry_at, DateTime.add(now, @probe_lease))
        {:probe, generation + 1}
    end
  end

  def closed?(binding, generation) do
    match?({^generation, _, nil, nil}, state(binding))
  end

  def finish_probe(binding, generation, now, observation) do
    case state(binding) do
      {^generation, failures, _, %DateTime{} = until} ->
        if DateTime.before?(now, until) and match?({:ok, _}, observation) do
          set_permanent(binding, nil)
          save(binding, generation + 1, 0, nil, nil)
        else
          if classify(observation) == :permanent,
            do: set_permanent(binding, binding.security_epoch)

          open(binding, generation, failures, now)
        end

      _ ->
        :ok
    end
  end

  def record(binding, generation, now, result) do
    case state(binding) do
      {^generation, failures, nil, nil} ->
        case classify(result) do
          :permanent ->
            set_permanent(binding, binding.security_epoch)
            open(binding, generation, failures, now)

          :transient when failures + 1 >= @threshold ->
            open(binding, generation, failures + 1, now)

          :transient ->
            save(binding, generation, failures + 1, nil, nil)

          :success when failures > 0 ->
            save(binding, generation, 0, nil, nil)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp classify({:error, {:not_issued, reason}}), do: classify({:error, reason})

  defp classify({:error, reason}) when reason in [:forbidden, :unauthorized, :configuration],
    do: :permanent

  defp classify({:error, reason})
       when reason in [:uncertain, :timeout, :reset, :server_error, :unavailable, :rate_limited],
       do: :transient

  defp classify({:ok, _}), do: :success
  defp classify({:ok, _, id}) when is_integer(id) and id > 0, do: :success
  defp classify(:ok), do: :success
  defp classify(_), do: :unclassified

  defp open(binding, generation, failures, now) do
    generation = generation + 1
    :ok = save(binding, generation, failures, DateTime.add(now, @cooldown), nil)

    # The current circuit row can close before the alert sink recovers.
    # Keep each opening until a separate sweep commits its alert.
    SQL.query!(
      Repo,
      """
      INSERT INTO support_circuit_alerts_pending (binding_id, generation, opened_at)
      VALUES ($1, $2, $3)
      ON CONFLICT (binding_id, generation) DO NOTHING
      """,
      [Ecto.UUID.dump!(binding.id), generation, now],
      log: false,
      telemetry_event: nil
    )

    :ok
  end

  defp permanent_epoch(binding) do
    case SQL.query!(
           Repo,
           "SELECT permanent_epoch FROM support_binding_circuits WHERE binding_id = $1",
           [Ecto.UUID.dump!(binding.id)],
           telemetry_event: nil
         ).rows do
      [[epoch]] -> epoch
      [] -> nil
    end
  end

  defp set_permanent(binding, epoch) do
    SQL.query!(
      Repo,
      """
      INSERT INTO support_binding_circuits (binding_id, permanent_epoch, generation, failures)
      VALUES ($1, $2, 0, 0)
      ON CONFLICT (binding_id) DO UPDATE SET permanent_epoch = EXCLUDED.permanent_epoch
      """,
      [Ecto.UUID.dump!(binding.id), epoch],
      telemetry_event: nil
    )

    :ok
  end

  defp state(binding) do
    case SQL.query!(
           Repo,
           """
           SELECT generation, failures, retry_at, probe_until
           FROM support_binding_circuits WHERE binding_id = $1
           """,
           [Ecto.UUID.dump!(binding.id)]
         ).rows do
      [[generation, failures, retry_at, probe_until]] ->
        {generation, failures, retry_at, probe_until}

      [] ->
        {0, 0, nil, nil}
    end
  end

  defp save(binding, generation, failures, retry_at, probe_until) do
    SQL.query!(
      Repo,
      """
      INSERT INTO support_binding_circuits (binding_id, generation, failures, retry_at, probe_until)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (binding_id) DO UPDATE SET
        generation = EXCLUDED.generation, failures = EXCLUDED.failures,
        retry_at = EXCLUDED.retry_at, probe_until = EXCLUDED.probe_until
      """,
      [Ecto.UUID.dump!(binding.id), generation, failures, retry_at, probe_until]
    )

    :ok
  end
end
