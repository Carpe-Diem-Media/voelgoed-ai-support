defmodule VoelgoedAi.Support.Ownership do
  @moduledoc """
  Serializes local ownership under the configuration and qualified session locks.
  A human inhibit survives delivery failure and a closed session generation.
  """

  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, InboundEvent, OutboundDelivery}
  alias VoelgoedAi.Support.{SupportRun, SupportSession, WorkStore}
  alias VoelgoedAi.Support.Workers.{Deliver, Sweep}

  @inbox [:installation_ref, :external_account_id, :external_inbox_id]
  @conversation [:conversation_id | @inbox]
  @active_runs [:queued, :running, :retry_wait]

  @doc false
  def locked_session(id, operation) do
    with {:ok, %SupportSession{} = candidate} <- get(SupportSession, id),
         true <- ChatwootAdapter.in_scope?(candidate),
         {:ok, config} <- Configuration.lock_inbox(Map.take(candidate, @inbox)),
         {:ok, %SupportSession{} = session} <- get(SupportSession, id, lock: true) do
      operation.(config, session, ChatwootAdapter.now())
    else
      {:ok, nil} -> {:error, :scope_denied}
      false -> {:error, :scope_denied}
      error -> error
    end
  end

  @doc false
  def lock_event(event) do
    with {:ok, config} <- Configuration.lock_inbox(Map.take(event, @inbox)),
         {:ok, session} <- ensure_session(config, event),
         {:ok, %InboundEvent{} = event} <- get(InboundEvent, event.id, lock: true) do
      {:ok, config, session, event, ChatwootAdapter.now()}
    end
  end

  @doc false
  def ensure_session(config, event) do
    where = Map.take(event, @conversation)

    with {:ok, sessions} <-
           WorkStore.read(SupportSession, :by_conversation, %{}, where,
             many: true,
             sort: [generation: :desc],
             limit: 1,
             lock: true
           ) do
      case sessions do
        [%{state: state} = session] when state != :closed -> {:ok, session}
        sessions -> register(config, event, where, List.first(sessions))
      end
    end
  end

  defp register(config, event, where, prior) do
    attrs = %{
      binding_id: config.binding.id,
      generation: if(prior, do: prior.generation + 1, else: 1),
      ownership_epoch: if(prior, do: prior.ownership_epoch + 1, else: 0),
      human_inhibit: prior != nil and prior.human_inhibit,
      contact_id: event.contact_id,
      correlation_id: Ash.UUIDv7.generate()
    }

    WorkStore.create(SupportSession, :register, Map.merge(where, attrs))
  end

  @doc false
  def get(resource, id, opts \\ []),
    do: WorkStore.read(resource, :by_id, %{}, %{id: id}, opts)

  @doc false
  def permitted?(config) do
    ChatwootAdapter.in_scope?(config.binding) and config.binding.status == :enabled and
      config.assistant.status == :active and
      config.assistant.audience == :public
  end

  @doc false
  def write_enabled?(config) do
    permitted?(config) and config.binding.operating_mode == :automatic and
      config.control.status == :enabled and config.control.mode == :fake and
      match?(%{adapter: {_, _}}, ChatwootAdapter.fixture())
  end

  @doc false
  def epoch_snapshot(config, session) do
    %{
      ownership_epoch: session.ownership_epoch,
      assistant_epoch: config.assistant.security_epoch,
      binding_epoch: config.binding.security_epoch,
      control_epoch: config.control.security_epoch
    }
  end

  @doc false
  def current?(config, session, row) do
    epochs = epoch_snapshot(config, session)
    Map.take(row, Map.keys(epochs)) == epochs
  end

  @doc false
  def active_run(session, opts \\ []),
    do:
      WorkStore.read(
        SupportRun,
        :active,
        %{},
        %{session_id: session.id, state: %{in: @active_runs}},
        opts
      )

  @doc false
  def blocking_delivery(session, opts \\ []) do
    # An UNKNOWN intent still blocks this conversation if the old generation closed.
    with {:ok, sessions} <-
           WorkStore.read(SupportSession, :by_conversation, %{}, Map.take(session, @conversation),
             many: true,
             sort: [:id]
           ) do
      opts = Keyword.merge([many: true, sort: [:id], limit: 1], opts)

      case WorkStore.read(
             OutboundDelivery,
             :for_session,
             %{},
             %{
               session_id: %{in: Enum.map(sessions, & &1.id)},
               state: %{in: [:pending, :sending, :unknown]}
             },
             opts
           ) do
        {:ok, rows} -> {:ok, List.first(rows)}
        error -> error
      end
    end
  end

  @doc false
  def observe(config, session, observation, now) do
    attrs = %{
      observed_status: observation.status,
      observed_assignee: observation.assignee,
      observed_at: now
    }

    cond do
      session.state == :closed ->
        {:ok, session}

      observation.status == :resolved ->
        close_locked(session, attrs, now, :resolved)

      observation.assignee == :human ->
        human_takeover(session, attrs, now)

      eligible_bot?(config, session, observation) and session.state == :unverified ->
        WorkStore.update(
          session,
          :activate_bot,
          Map.merge(attrs, next(session, :bot_active, false))
        )

      true ->
        WorkStore.update(session, :verify_owner, attrs)
    end
  end

  @doc false
  def eligible_bot?(config, session, observation) do
    permitted?(config) and not session.human_inhibit and observation.status == :pending and
      observation.assignee == :bot and observation.can_reply and
      observation.team == config.binding.handoff_team_id
  end

  @doc false
  def human_takeover(%{state: state} = session, attrs, now)
      when state in [:unverified, :bot_active] do
    with :ok <- fence(session, now, :human_takeover),
         {:ok, updated} <-
           WorkStore.update(
             session,
             :observe_human_takeover,
             Map.merge(attrs, next(session, :human_active, true))
           ) do
      {:ok, updated}
    end
  end

  def human_takeover(session, attrs, _now), do: WorkStore.update(session, :verify_owner, attrs)

  @doc false
  def close_locked(session, attrs, now, reason) do
    with :ok <- fence(session, now, reason) do
      WorkStore.update(
        session,
        :close,
        Map.merge(
          attrs,
          Map.merge(
            next(session, :closed, attrs[:human_inhibit] == true or session.human_inhibit),
            %{closed_at: now, reason_code: reason}
          )
        )
      )
    end
  end

  @doc false
  def request_locked(config, %{state: :bot_active} = session, now) do
    if write_enabled?(config) do
      with :ok <- fence(session, now, :explicit_handoff),
           {:ok, session} <-
             WorkStore.update(session, :request_handoff, next(session, :handoff_pending, true)),
           {:ok, _} <- prepare(config, session, nil, :handoff_status, DateTime.add(now, 300)) do
        {:ok, session}
      end
    else
      {:error, :disabled}
    end
  end

  def request_locked(_, _, _), do: {:error, :invalid_transition}

  @doc false
  def confirm_locked(%{state: :handoff_pending} = session),
    do: WorkStore.update(session, :confirm_handoff, %{state: :human_active})

  def confirm_locked(session), do: {:ok, session}

  @doc false
  def prepare(config, session, run, purpose, deadline) do
    delivery = %{
      session_id: session.id,
      purpose: purpose,
      visibility: if(purpose == :public_reply, do: :public, else: :operational),
      operation_ref: Ash.UUIDv7.generate(),
      correlation_id: session.correlation_id,
      deadline_at: deadline
    }

    with {:ok, attrs} <- template(delivery, config, run),
         {:ok, row} <-
           WorkStore.create(
             OutboundDelivery,
             :prepare,
             Map.merge(attrs, epoch_snapshot(config, session))
           ),
         {:ok, _} <- enqueue(Deliver, %{"delivery_id" => row.id}),
         {:ok, _} <- enqueue(Sweep, %{"delivery_id" => row.id}, scheduled_at: deadline) do
      {:ok, row}
    end
  end

  defp template(%{purpose: :handoff_status} = attrs, _config, _run), do: {:ok, attrs}

  defp template(attrs, config, run) do
    with {:ok, revision} <- Configuration.current_revision(config.assistant),
         true <- revision.id == run.assistant_revision_id do
      {:ok,
       Map.merge(attrs, %{
         run_id: run.id,
         template_version: revision.template_version,
         template_hash: revision.config_hash
       })}
    else
      _ -> {:error, :stale_policy}
    end
  end

  @doc false
  def enqueue(worker, args, opts \\ []), do: Oban.insert(worker.new(args, opts))

  @doc false
  def in_transaction(fun), do: Repo.transact(fun)

  defp fence(session, now, reason) do
    with {:ok, run} <- active_run(session, lock: true),
         :ok <- cancel_run(run, now, reason),
         {:ok, rows} <-
           WorkStore.read(
             OutboundDelivery,
             :for_session,
             %{},
             %{session_id: session.id, state: %{in: [:pending, :sending]}},
             lock: true,
             many: true,
             sort: [:id]
           ) do
      Enum.reduce_while(rows, :ok, fn row, :ok ->
        case VoelgoedAi.Support.Delivery.fence(row, now, reason) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp cancel_run(nil, _, _), do: :ok

  defp cancel_run(run, now, reason) do
    case WorkStore.update(run, :cancel, %{
           state: :cancelled,
           finished_at: now,
           lease_expires_at: nil,
           retry_at: nil,
           reason_code: reason
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp next(session, state, inhibit),
    do: %{state: state, ownership_epoch: session.ownership_epoch + 1, human_inhibit: inhibit}
end
