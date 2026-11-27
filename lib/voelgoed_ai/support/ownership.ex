defmodule VoelgoedAi.Support.Ownership do
  @moduledoc """
  Serializes local ownership under the configuration and qualified session locks.
  A human inhibit survives delivery failure and a closed session generation.
  """

  use VoelgoedAi.Support.WorkStore, [:read, :create, :update]

  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, InboundEvent, OutboundDelivery}
  alias VoelgoedAi.Support.{SupportRun, SupportSession}
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

    with {:ok, latest} <- lock_latest(where) do
      case latest do
        %{state: state} = session when state != :closed -> {:ok, session}
        prior -> register(config, event, where, prior)
      end
    end
  end

  @doc false
  def lock_latest(session_or_identity) do
    where = Map.take(session_or_identity, @conversation)

    with {:ok, sessions} <-
           store_read(SupportSession, :by_conversation, %{}, where,
             many: true,
             sort: [generation: :desc],
             limit: 1,
             lock: true
           ) do
      {:ok, List.first(sessions)}
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

    store_create(SupportSession, :register, Map.merge(where, attrs))
  end

  @doc false
  def get(resource, id, opts \\ []),
    do: store_read(resource, :by_id, %{}, %{id: id}, opts)

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
      match?(%{adapter: {_, _}}, ChatwootAdapter.fixture()) and
      not match?(%{response_policy: :shadow_decision}, ChatwootAdapter.fixture())
  end

  if Mix.env() == :test do
    @doc false
    def shadow_fixture?(binding) do
      ChatwootAdapter.in_scope?(binding) and
        match?(
          %{
            shadow_evaluation: true,
            response_policy: :shadow_decision,
            assistant_id: id,
            adapter: {_, _}
          }
          when id == binding.assistant_id,
          ChatwootAdapter.fixture()
        )
    end
  else
    @doc false
    def shadow_fixture?(_binding), do: false
  end

  @doc false
  def shadow_evaluation_enabled?(config) do
    permitted?(config) and config.binding.operating_mode == :shadow and
      config.control.status == :enabled and config.control.mode == :shadow_test and
      shadow_fixture?(config.binding)
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
  def pending_input?(session) do
    where =
      session
      |> Map.take([:installation_ref, :external_account_id, :external_inbox_id, :conversation_id])
      |> Map.merge(%{kind: :input, state: :dispatched, disposition: :pending})

    with {:ok, rows} <- store_read(InboundEvent, :pending, %{}, where, many: true, limit: 1) do
      {:ok, rows != []}
    end
  end

  @doc false
  def active_run(session, opts \\ []),
    do:
      store_read(
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
           store_read(SupportSession, :by_conversation, %{}, Map.take(session, @conversation),
             many: true,
             sort: [:id]
           ) do
      opts = Keyword.merge([many: true, sort: [:id], limit: 1], opts)

      case store_read(
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
        close_locked(session, attrs, now)

      observation.assignee == :human ->
        human_takeover(session, attrs, now)

      eligible_bot?(config, session, observation) and session.state == :unverified ->
        store_update(
          session,
          :activate_bot,
          Map.merge(attrs, next_epoch(session))
        )

      true ->
        store_update(session, :verify_owner, attrs)
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
           store_update(
             session,
             :observe_human_takeover,
             Map.merge(attrs, next_epoch(session))
           ) do
      {:ok, updated}
    end
  end

  def human_takeover(%{state: :closed, human_inhibit: false} = session, _attrs, _now),
    do: store_update(session, :inhibit_closed, %{})

  def human_takeover(%{state: :closed} = session, _attrs, _now), do: {:ok, session}

  def human_takeover(session, attrs, _now), do: store_update(session, :verify_owner, attrs)

  @doc false
  def signed_handoff_takeover_attributes(%{state: :handoff_pending} = session, now) do
    # Signed ingress fences the intent in the same transaction as takeover.
    # A consumed dispatch stays uncertain until independently reconciled.
    with :ok <- fence(session, now, :human_takeover) do
      {:ok, next_epoch(session)}
    end
  end

  @doc false
  def close_locked(session, observation, now) do
    with {:ok, attrs} <- close_attributes(session, now, :resolved) do
      store_update(session, :close, Map.merge(observation, attrs))
    end
  end

  @doc false
  def close_attributes(session, now, reason) do
    with {:ok, outstanding} <- blocking_delivery(session),
         :ok <- fence(session, now, reason) do
      inhibit = reason == :manual_closure or session.human_inhibit or outstanding != nil

      {:ok,
       Map.merge(next_epoch(session), %{
         closed_at: now,
         reason_code: reason,
         human_inhibit: inhibit
       })}
    end
  end

  @doc false
  def request_locked(config, %{state: :bot_active} = session, now) do
    if write_enabled?(config) do
      stage_handoff(config, session, now, :explicit_handoff)
    else
      {:error, :disabled}
    end
  end

  def request_locked(_, _, _), do: {:error, :invalid_transition}

  @doc false
  def route_overdue_locked(
        config,
        %{
          state: :bot_active,
          human_inhibit: false,
          observed_status: :pending,
          observed_assignee: :bot
        } = session,
        now
      ) do
    if write_enabled?(config) or
         (config.binding.operating_mode == :shadow and permitted?(config)) do
      # Shadow records the intent and inhibit. Delivery still checks mode and
      # fresh remote ownership before permitting a status write.
      stage_handoff(config, session, now, :late_input)
    else
      {:ok, session}
    end
  end

  def route_overdue_locked(_, session, _), do: {:ok, session}

  @doc false
  def route_shadow_locked(config, session, observation, now) do
    if session.state == :bot_active and shadow_evaluation_enabled?(config) and
         eligible_bot?(config, session, observation) do
      stage_handoff(config, session, now, :explicit_handoff)
    else
      {:error, :scope_denied}
    end
  end

  defp stage_handoff(config, session, now, reason) do
    with :ok <- fence(session, now, reason),
         {:ok, session} <- store_update(session, :request_handoff, next_epoch(session)),
         {:ok, _} <- prepare(config, session, nil, :handoff_status, DateTime.add(now, 300)) do
      {:ok, session}
    end
  end

  @doc false
  def confirm_locked(%{state: :handoff_pending} = session),
    do: store_update(session, :confirm_handoff, %{})

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
           store_create(
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
           store_read(
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
    case store_update(run, :cancel, %{
           finished_at: now,
           reason_code: reason
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp next_epoch(session), do: %{ownership_epoch: session.ownership_epoch + 1}
end
