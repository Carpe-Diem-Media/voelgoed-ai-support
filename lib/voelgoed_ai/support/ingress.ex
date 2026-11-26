defmodule VoelgoedAi.Support.Ingress do
  @moduledoc """
  Persists authenticated receipts and processing jobs on the same Repo
  transaction. The original timestamp survives replay.
  """

  use VoelgoedAi.Support.WorkStore, [:read, :create, :update]

  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.{
    ChatwootAdapter,
    Configuration,
    InboundEvent,
    Ownership,
    SupportRun
  }

  @inbox [:installation_ref, :external_account_id, :external_inbox_id]
  @identity [:installation_ref, :external_account_id, :event_type]

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
    do: store_read(InboundEvent, :by_identity, %{}, Map.take(event, [:message_id | @identity]))

  defp find_receipt(%{stable_event_key: key} = event) when is_binary(key),
    do:
      store_read(
        InboundEvent,
        :by_identity,
        %{},
        Map.take(event, [:stable_event_key | @identity])
      )

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

    with {:ok, context} <- signed_human_inhibit(event, config),
         {:ok, event} <- store_create(InboundEvent, :register, attrs),
         {:ok, event} <- finish_receipt(event, context) do
      {:ok, event.id}
    end
  end

  defp finish_receipt(%{kind: :ignored} = event, _context),
    do: store_update(event, :ignore, %{processed_at: ChatwootAdapter.now()})

  defp finish_receipt(%{kind: :oversize} = event, _context),
    do:
      store_update(event, :quarantine, %{
        reason_code: :oversize,
        processed_at: ChatwootAdapter.now()
      })

  defp finish_receipt(event, session) do
    attrs = if session, do: %{session_id: session.id}, else: %{}

    with {:ok, receipts} <-
           store_read(
             InboundEvent,
             :pending,
             %{},
             %{state: :dispatched, disposition: :pending},
             many: true,
             limit: 100
           ),
         {:ok, runs} <-
           store_read(
             SupportRun,
             :active,
             %{},
             %{state: %{in: [:queued, :running, :retry_wait]}},
             many: true,
             limit: 100
           ) do
      if length(receipts) + length(runs) >= 100 do
        store_update(
          event,
          :quarantine,
          Map.merge(attrs, %{
            reason_code: :admission_limited,
            processed_at: ChatwootAdapter.now()
          })
        )
      else
        dispatch(event, attrs)
      end
    end
  end

  defp signed_human_inhibit(%{kind: :human_outbound} = event, config) do
    with {:ok, session} <- Ownership.ensure_session(config, event),
         true <- session.contact_id == event.contact_id do
      Ownership.human_takeover(session, %{}, ChatwootAdapter.now())
    else
      false -> {:error, :scope_denied}
      error -> error
    end
  end

  defp signed_human_inhibit(_, _), do: {:ok, nil}

  defp dispatch(event, attrs) do
    job =
      Oban.Job.new(%{"event_id" => event.id},
        worker: VoelgoedAi.Support.Workers.ProcessEvent,
        queue: :support,
        max_attempts: 1
      )

    with {:ok, event} <- store_update(event, :dispatch, attrs),
         {:ok, _job} <- Oban.insert(job) do
      {:ok, event}
    end
  end
end
