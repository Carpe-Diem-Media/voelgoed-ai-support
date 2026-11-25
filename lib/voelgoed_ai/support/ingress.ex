defmodule VoelgoedAi.Support.Ingress do
  @moduledoc """
  Persists authenticated receipts and processing jobs on the same Repo
  transaction. The original timestamp survives replay.
  """

  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, InboundEvent, WorkStore}

  @inbox [:installation_ref, :external_account_id, :external_inbox_id]
  @identity [:installation_ref, :external_account_id, :event_type, :message_id]

  @doc false
  def accept(event) do
    scope = Map.take(event, @inbox)

    with %{} = fixture <- ChatwootAdapter.fixture(),
         true <- Map.take(fixture, @inbox) == scope do
      receipt_transaction(event, scope)
    else
      _ -> {:error, :scope_denied}
    end
  rescue
    # Oban's storage may raise, including when PostgreSQL aborts an insert.
    # The transaction has rolled back before the HTTP boundary sees failure.
    _ in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :receipt_storage}
  end

  defp receipt_transaction(event, scope) do
    Repo.transact(fn ->
      with {:ok, config} <- Configuration.lock_inbox(scope),
           {:ok, existing} <- find_receipt(event) do
        case existing do
          nil -> register(event, config)
          receipt -> acknowledge(receipt, event)
        end
      end
    end)
  end

  defp find_receipt(%{message_id: id} = event) when is_integer(id),
    do: WorkStore.read(InboundEvent, :by_identity, %{}, Map.take(event, @identity))

  defp find_receipt(_event), do: {:ok, nil}

  defp acknowledge(%{state: state} = receipt, event)
       when state in [:dispatched, :ignored, :quarantined] do
    if receipt.conversation_id == event.conversation_id and
         receipt.external_inbox_id == event.external_inbox_id do
      {:ok, receipt.id}
    else
      {:error, :scope_denied}
    end
  end

  defp acknowledge(_, _), do: {:error, :receipt_storage}

  defp register(event, config) do
    attrs = Map.put(event, :correlation_id, Ash.UUIDv7.generate())

    with {:ok, event} <- WorkStore.create(InboundEvent, :register, attrs),
         {:ok, event} <- finish_receipt(event, config) do
      {:ok, event.id}
    end
  end

  defp finish_receipt(%{kind: kind} = event, _config) when kind in [:ignored, :oversize] do
    {action, state, disposition, reason} =
      if kind == :ignored,
        do: {:ignore, :ignored, :ignored, :ignored},
        else: {:quarantine, :quarantined, :triage, :oversize}

    WorkStore.update(event, action, %{
      state: state,
      disposition: disposition,
      reason_code: reason,
      processed_at: DateTime.utc_now()
    })
  end

  defp finish_receipt(event, _config) do
    job =
      Oban.Job.new(%{"event_id" => event.id},
        worker: VoelgoedAi.Support.Workers.ProcessEvent,
        queue: :support,
        max_attempts: 1
      )

    with {:ok, event} <- WorkStore.update(event, :dispatch, %{state: :dispatched}),
         {:ok, _job} <- Oban.insert(job) do
      {:ok, event}
    end
  end
end
