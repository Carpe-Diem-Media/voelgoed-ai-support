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

  def reserve(binding, now) do
    {generation, failures, retry_at, probe_until} = state(binding)

    cond do
      retry_at == nil ->
        {:closed, generation}

      DateTime.before?(now, retry_at) ->
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
          save(binding, generation + 1, 0, nil, nil)
        else
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

  defp open(binding, generation, failures, now),
    do: save(binding, generation + 1, failures, DateTime.add(now, @cooldown), nil)

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
