defmodule VoelgoedAi.Support.Delivery do
  @moduledoc """
  Fences a single external write with a committed dispatch marker. Recovery
  treats the marker as possible delivery, even if the worker died before POST.
  """

  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.{
    BindingCircuit,
    ChatwootAdapter,
    Configuration,
    InboundEvent,
    OutboundDelivery
  }

  alias VoelgoedAi.Support.{
    Ownership,
    Recovery,
    RunProcessing,
    SupportRun,
    SystemAudit,
    WorkStore
  }

  alias VoelgoedAi.Support.Workers.{Reconcile, Sweep}

  @request_margin_ms 750
  @lease_seconds 5
  @max_reads 3

  @doc "Process one durable intent. Duplicate jobs cannot issue another POST."
  def deliver(id), do: VoelgoedAi.Support.JobAction.invoke(OutboundDelivery, :deliver_intent, id)

  @doc false
  def perform(id) do
    with {:ok, {:read, reservation, session, generation}} <- with_delivery(id, &preflight/4),
         observation <- ChatwootAdapter.observe(session, reservation.deadline_at),
         history <- read_reply_history(session, reservation, observation),
         {:ok, {:claimed, claim}} <-
           with_delivery(
             id,
             &claim(&1, &2, &3, &4, reservation, observation, history, generation)
           ),
         :ok <- fixture_barrier(:after_claim),
         {:ok, {:authorized, authorized, text}} <-
           with_delivery(id, &authorize(&1, &2, &3, &4, claim, generation)),
         :ok <- fixture_barrier(:after_authorization) do
      result = post(session, authorized, text)

      case with_delivery(id, &settle(&1, &2, &3, &4, authorized, result, generation)) do
        {:ok, %{state: :unknown, purpose: :handoff_status}} when result == :ok ->
          Recovery.reconcile(id)

        settled ->
          RunProcessing.job_result(settled)
      end
    else
      {:ok, {:probe, session, deadline, generation}} ->
        observation = ChatwootAdapter.observe(session, deadline)

        with_delivery(id, fn config, _, _, now ->
          :ok = BindingCircuit.finish_probe(config.binding, generation, now, observation)
          {:ok, :probe_finished}
        end)
        |> RunProcessing.job_result()

      result ->
        RunProcessing.job_result(result)
    end
  end

  if Mix.env() == :test do
    # Fault tests pause only after transactions have committed.
    defp fixture_barrier(phase) do
      case ChatwootAdapter.fixture() do
        %{^phase => callback} -> callback.()
        _ -> :ok
      end
    end
  else
    defp fixture_barrier(_), do: :ok
  end

  @doc false
  def with_delivery(id, operation) do
    Repo.transact(fn ->
      with {:ok, %OutboundDelivery{} = candidate} <- Ownership.get(OutboundDelivery, id) do
        Ownership.locked_session(candidate.session_id, fn config, session, now ->
          with {:ok, run} <- lock_runs(session, candidate),
               {:ok, %OutboundDelivery{} = delivery} <- lock_deliveries(session, id) do
            operation.(Map.put(config, :run, run), session, delivery, now)
          end
        end)
      else
        {:ok, nil} -> {:ok, :missing}
        error -> error
      end
    end)
  end

  # Resolution, takeover and operator actions may fence other work in
  # this session. Lock the affected runs before intents, each in ID order.
  defp lock_runs(session, delivery) do
    filters = [%{state: %{in: [:queued, :running, :retry_wait]}}]
    filters = if delivery.run_id, do: [%{id: delivery.run_id} | filters], else: filters

    with {:ok, rows} <-
           WorkStore.read(SupportRun, :active, %{}, %{session_id: session.id, or: filters},
             many: true,
             lock: true,
             sort: [:id]
           ) do
      {:ok, Enum.find(rows, &(&1.id == delivery.run_id))}
    end
  end

  defp lock_deliveries(session, id) do
    with {:ok, rows} <-
           WorkStore.read(
             OutboundDelivery,
             :for_session,
             %{},
             %{session_id: session.id, or: [%{id: id}, %{state: %{in: [:pending, :sending]}}]},
             many: true,
             lock: true,
             sort: [:id]
           ) do
      {:ok, Enum.find(rows, &(&1.id == id))}
    end
  end

  defp preflight(config, session, %{state: :pending} = delivery, now) do
    cond do
      DateTime.compare(now, delivery.deadline_at) != :lt ->
        expire_pending(delivery, now)

      not valid?(config, session, delivery, now) ->
        fence(delivery, now, :stale_policy)

      delivery.attempt_count != 0 or delivery.read_count >= @max_reads ->
        fail_pending(delivery, :read_exhausted)

      delivery.purpose == :handoff_status and delivery.last_read_at != nil and
          DateTime.before?(now, next_read_at(delivery)) ->
        {:ok, :backoff}

      true ->
        case BindingCircuit.reserve(config.binding, now) do
          {:closed, generation} ->
            with {:ok, row} <- reserve_read(delivery, now),
                 do: {:ok, {:read, row, session, generation}}

          {:probe, generation} ->
            with {:ok, _} <- fence(delivery, now, :unavailable),
                 do: {:ok, {:probe, session, delivery.deadline_at, generation}}

          :open ->
            fence(delivery, now, :unavailable)
        end
    end
  end

  defp preflight(_, _, _, _), do: {:ok, :finished}

  defp read_reply_history(session, %{purpose: :public_reply} = delivery, {:ok, _}),
    do: ChatwootAdapter.history(session, delivery.deadline_at)

  defp read_reply_history(_, _, _), do: {:ok, []}

  defp claim(config, session, delivery, now, reservation, observation, history, generation) do
    cond do
      delivery.state != :pending or delivery.read_sequence != reservation.read_sequence ->
        {:ok, :stale_claim}

      delivery.purpose == :handoff_status and not DateTime.before?(now, delivery.deadline_at) ->
        expire_pending(delivery, now)

      not valid?(config, session, delivery, now) or
          not BindingCircuit.closed?(config.binding, generation) ->
        fence(delivery, now, :stale_policy)

      true ->
        if match?({:error, _}, observation) do
          :ok = BindingCircuit.record(config.binding, generation, now, observation)
        end

        qualify(config, session, delivery, now, observation, history)
    end
  end

  defp qualify(_config, session, delivery, now, {:ok, %{status: :resolved}}, _) do
    with {:ok, _} <- fence(delivery, now, :resolved) do
      Ownership.close_locked(
        session,
        %{observed_status: :resolved, observed_at: now},
        now,
        :resolved
      )
    end
  end

  defp qualify(
         config,
         session,
         %{purpose: :public_reply} = delivery,
         now,
         {:ok, observation},
         {:ok, history}
       ) do
    cond do
      observation.assignee == :human ->
        with {:ok, _} <- fence(delivery, now, :human_takeover) do
          Ownership.human_takeover(session, %{observed_assignee: :human, observed_at: now}, now)
        end

      Ownership.eligible_bot?(config, session, observation) ->
        with {:ok, inputs} <- RunProcessing.inputs(delivery.run_id),
             :ok <- RunProcessing.check_coverage(inputs, history),
             {:ok, false} <- queued_input?(session) do
          claim_delivery(delivery, now)
        else
          {:ok, true} -> {:ok, :input_pending}
          {:error, :history_changed} -> fence(delivery, now, :history_changed)
          error -> error
        end

      true ->
        fence(delivery, now, :scope_denied)
    end
  end

  defp qualify(
         config,
         session,
         %{purpose: :handoff_status} = delivery,
         now,
         {:ok, observation},
         _
       ) do
    cond do
      human_goal?(config, observation) ->
        with {:ok, {:claimed, claimed}} <- claim_delivery(delivery, now),
             {:ok, _} <- confirm(claimed, now, nil, :already_human),
             {:ok, _} <- Ownership.confirm_locked(session) do
          {:ok, :already_human}
        end

      observation.status == :pending and observation.assignee == :bot and
          observation.team == config.binding.handoff_team_id ->
        claim_delivery(delivery, now)

      true ->
        fence(delivery, now, :scope_denied)
    end
  end

  defp qualify(_, _, %{purpose: :handoff_status} = delivery, now, {:error, reason}, _)
       when reason in [:unavailable, :rate_limited, :timeout, :reset, :server_error] do
    due = next_read_at(delivery)

    cond do
      delivery.read_count >= @max_reads ->
        fail_pending(delivery, :read_exhausted)

      not DateTime.before?(due, delivery.deadline_at) ->
        expire_pending(delivery, now)

      true ->
        Ownership.enqueue(VoelgoedAi.Support.Workers.Deliver, %{"delivery_id" => delivery.id},
          scheduled_at: due
        )
    end
  end

  defp qualify(_, _, delivery, now, _, _), do: fence(delivery, now, :unavailable)

  defp next_read_at(delivery),
    do: DateTime.add(delivery.last_read_at, if(delivery.read_count == 1, do: 1, else: 3))

  @doc false
  def expire_pending(%{purpose: :handoff_status} = delivery, _now),
    do: fail_pending(delivery, :deadline)

  def expire_pending(delivery, now), do: fence(delivery, now, :deadline)

  defp fail_pending(delivery, reason),
    do: fail_intent(delivery, :fail, :failed, reason)

  defp fail_intent(delivery, action, state, reason) do
    with {:ok, row} <-
           WorkStore.update(delivery, action, %{
             state: state,
             lease_expires_at: nil,
             reason_code: reason
           }) do
      audit_handoff_failure(row, reason)
    end
  end

  @doc false
  def audit_handoff_failure(%{purpose: :handoff_status} = row, reason) do
    with {:ok, _} <- SystemAudit.append(row, :handoff_failed, reason), do: {:ok, row}
  end

  def audit_handoff_failure(row, _), do: {:ok, row}

  defp queued_input?(session) do
    where =
      session
      |> Map.take([:installation_ref, :external_account_id, :external_inbox_id, :conversation_id])
      |> Map.merge(%{kind: :input, state: :dispatched, disposition: :pending})

    with {:ok, rows} <- WorkStore.read(InboundEvent, :pending, %{}, where, many: true, limit: 1) do
      {:ok, rows != []}
    end
  end

  defp claim_delivery(delivery, now) do
    lease = DateTime.add(now, @lease_seconds)

    with {:ok, row} <-
           WorkStore.update(delivery, :claim, %{
             state: :sending,
             lease_expires_at: lease,
             claim_generation: delivery.claim_generation + 1
           }),
         {:ok, _} <-
           Ownership.enqueue(Sweep, %{"delivery_id" => delivery.id}, scheduled_at: lease) do
      {:ok, {:claimed, row}}
    end
  end

  defp authorize(config, session, delivery, now, claim, generation) do
    cond do
      not current_claim?(delivery, claim) or delivery.dispatch_authorized_at != nil ->
        {:ok, :stale_claim}

      delivery.purpose == :handoff_status and not DateTime.before?(now, delivery.deadline_at) ->
        fence(delivery, now, :deadline)

      not valid?(config, session, delivery, now) or
        not BindingCircuit.closed?(config.binding, generation) or
        DateTime.diff(delivery.lease_expires_at, now, :millisecond) <= @request_margin_ms or
        DateTime.diff(delivery.deadline_at, now, :millisecond) <= @request_margin_ms or
          DateTime.diff(now, delivery.last_read_at, :millisecond) >= 2_000 ->
        fence(delivery, now, :stale_policy)

      true ->
        with {:ok, false} <- newer_input?(session, delivery),
             {:ok, text} <- render(config, delivery),
             {:ok, row} <-
               WorkStore.update(delivery, :authorize_dispatch, %{
                 dispatch_authorized_at: now,
                 attempt_count: 1
               }) do
          {:ok, {:authorized, row, text}}
        else
          {:ok, true} ->
            WorkStore.update(delivery, :safe_retry, %{
              state: :pending,
              lease_expires_at: nil,
              claim_generation: delivery.claim_generation + 1
            })

          {:error, :stale_policy} ->
            fence(delivery, now, :stale_policy)

          error ->
            error
        end
    end
  end

  defp newer_input?(session, %{purpose: :public_reply}), do: queued_input?(session)
  defp newer_input?(_, _), do: {:ok, false}

  defp render(_config, %{purpose: :handoff_status}), do: {:ok, nil}

  defp render(config, delivery),
    do: Configuration.render_fixed_reply(config.assistant, config.run, delivery)

  defp post(session, delivery, text) do
    deadline = earlier(delivery.deadline_at, delivery.lease_expires_at)

    if DateTime.diff(deadline, ChatwootAdapter.now(), :millisecond) > @request_margin_ms do
      destination = ChatwootAdapter.destination(session)

      case delivery.purpose do
        :public_reply ->
          ChatwootAdapter.call(:reply, destination, [text, delivery.operation_ref], deadline)

        :handoff_status ->
          ChatwootAdapter.call(:open_for_handoff, destination, [delivery.operation_ref], deadline)
      end
    else
      {:error, {:not_issued, :deadline}}
    end
  end

  defp settle(config, session, delivery, now, claim, result, generation) do
    if current_claim?(delivery, claim) and DateTime.compare(now, delivery.lease_expires_at) == :lt do
      :ok = BindingCircuit.record(config.binding, generation, now, result)
      finish_post(session, delivery, now, result)
    else
      {:ok, :stale_claim}
    end
  end

  defp finish_post(session, %{purpose: :public_reply} = delivery, now, {:ok, destination, id})
       when is_integer(id) and id in 1..9_223_372_036_854_775_807 do
    if destination == ChatwootAdapter.destination(session),
      do: confirm(delivery, now, id, :accepted),
      else: unknown(delivery, now, :ambiguous_write)
  end

  defp finish_post(_, delivery, _now, {:error, {:not_issued, :deadline}}),
    do: fail_intent(delivery, :cancel, :cancelled, :deadline)

  defp finish_post(_, delivery, _now, {:error, {:not_issued, _}}),
    do: fail_intent(delivery, :fail, :failed, :no_effect)

  defp finish_post(_, delivery, now, _result), do: unknown(delivery, now, :ambiguous_write)

  @doc false
  def fence(%{state: :sending, dispatch_authorized_at: time} = delivery, now, reason)
      when not is_nil(time),
      do: unknown(delivery, now, reason)

  def fence(%{purpose: :handoff_status, state: state} = delivery, _now, :deadline)
      when state in [:pending, :sending],
      do: fail_intent(delivery, :cancel, :cancelled, :deadline)

  def fence(%{state: state} = delivery, _now, reason) when state in [:pending, :sending],
    do:
      WorkStore.update(delivery, :cancel, %{
        state: :cancelled,
        lease_expires_at: nil,
        reason_code: reason
      })

  def fence(row, _, _), do: {:ok, row}

  @doc false
  def unknown(delivery, now, reason) do
    deadline =
      if delivery.purpose == :public_reply, do: DateTime.add(now, 300), else: delivery.deadline_at

    with {:ok, row} <-
           WorkStore.update(delivery, :mark_unknown, %{
             state: :unknown,
             lease_expires_at: nil,
             uncertainty_reason: reason,
             recovery_deadline_at: deadline,
             last_read_at: nil,
             read_count: if(delivery.purpose == :public_reply, do: 0, else: delivery.read_count)
           }),
         {:ok, _} <- SystemAudit.append(row, :delivery_unknown, reason),
         {:ok, _} <- Ownership.enqueue(Reconcile, %{"delivery_id" => delivery.id}) do
      {:ok, row}
    end
  end

  @doc false
  def reserve_read(delivery, now) do
    WorkStore.update(delivery, :reserve_read, %{
      read_sequence: delivery.read_sequence + 1,
      read_count: delivery.read_count + 1,
      last_read_at: now
    })
  end

  @doc false
  def confirm(delivery, now, message_id, reason) do
    action = if delivery.state == :unknown, do: :reconcile, else: :confirm_sent

    WorkStore.update(delivery, action, %{
      state: :sent,
      lease_expires_at: nil,
      external_message_id: message_id,
      confirmed_at: now,
      reason_code: reason
    })
  end

  @doc false
  def human_goal?(config, observation) do
    observation.status == :open and observation.assignee in [:human, :unassigned] and
      observation.team == config.binding.handoff_team_id
  end

  defp current_claim?(row, claim) do
    row.state == :sending and row.claim_generation == claim.claim_generation and
      row.read_sequence == claim.read_sequence
  end

  defp valid?(config, session, delivery, now) do
    Ownership.write_enabled?(config) and Ownership.current?(config, session, delivery) and
      DateTime.compare(now, delivery.deadline_at) == :lt and
      case delivery.purpose do
        :public_reply ->
          config.run != nil and config.run.state == :completed and
            RunProcessing.valid_run?(config, session, config.run)

        :handoff_status ->
          session.state == :handoff_pending
      end
  end

  defp earlier(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)
end
