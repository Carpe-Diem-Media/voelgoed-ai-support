defmodule VoelgoedAi.Support.Delivery do
  @moduledoc """
  Fences a single external write with a committed dispatch marker. Recovery
  treats the marker as possible delivery, even if the worker died before POST.
  """

  use VoelgoedAi.Support.WorkStore, [:read, :update]

  alias VoelgoedAi.Knowledge.Retrieval
  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.{
    BindingCircuit,
    ChatwootAdapter,
    Configuration,
    EvidenceReply,
    OutboundDelivery
  }

  alias VoelgoedAi.Support.{
    Ownership,
    Recovery,
    RunProcessing,
    SupportRun,
    SystemAudit
  }

  alias VoelgoedAi.Support.Workers.{Reconcile, Sweep}

  @request_margin_ms 750
  @lease_seconds 5
  @max_reads 3

  @doc "Process one durable intent. Duplicate jobs cannot issue another POST."
  def deliver(id), do: VoelgoedAi.Support.JobAction.invoke(OutboundDelivery, :deliver_intent, id)

  @doc false
  def perform(id) do
    with {:ok, {:read, reservation, session, generation, ids}} <- with_delivery(id, &preflight/4),
         observation <- ChatwootAdapter.observe(session, reservation.deadline_at),
         history <- read_reply_history(session, reservation, observation, ids),
         {:ok, {:claimed, claim}} <-
           with_delivery(
             id,
             &claim(&1, &2, &3, &4, reservation, observation, history, generation)
           ),
         :ok <- fixture_barrier(:after_claim),
         {:ok, {:authorized, authorized, text}} <-
           with_delivery(id, &authorize(&1, &2, &3, &4, claim, generation)),
         :ok <- fixture_barrier(:after_authorization),
         fresh <- fresh_evidenced_read(session, authorized, ids),
         {:ok, {:dispatch_current, text}} <-
           with_delivery(id, fn config, session, delivery, _ ->
             dispatch_current(config, session, delivery, authorized, generation, fresh, text)
           end),
         :ok <- fixture_barrier(:before_wire) do
      result = post(session, authorized, text)

      case with_delivery(id, &settle(&1, &2, &3, &4, authorized, result, generation)) do
        {:ok, %{state: :unknown, purpose: :handoff_status}} when result == :ok ->
          Recovery.reconcile(id)

        settled ->
          RunProcessing.job_result(settled)
      end
    else
      {:ok, {:probe, session, deadline, generation, epochs}} ->
        observation = ChatwootAdapter.observe(session, deadline)

        with_delivery(id, fn config, current, _, now ->
          if Ownership.current?(config, current, epochs) do
            :ok = BindingCircuit.finish_probe(config.binding, generation, now, observation)
          end

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
    with_delivery_sessions(id, &{:ok, &1}, fn config, session, _, delivery, now ->
      operation.(config, session, delivery, now)
    end)
  end

  @doc false
  def with_delivery_and_latest(id, operation),
    do: with_delivery_sessions(id, &Ownership.lock_latest/1, operation)

  defp with_delivery_sessions(id, lock_latest, operation) do
    Repo.transact(fn ->
      with {:ok, %OutboundDelivery{} = candidate} <- Ownership.get(OutboundDelivery, id) do
        Ownership.locked_session(candidate.session_id, fn config, session, now ->
          # With the binding locked, acquire the source generation and then any
          # newer generation before locking runs or deliveries.
          with {:ok, latest} <- lock_latest.(session),
               {:ok, run} <- lock_runs(session, candidate),
               {:ok, %OutboundDelivery{} = delivery} <- lock_deliveries(session, id) do
            operation.(Map.put(config, :run, run), session, latest, delivery, now)
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
           store_read(SupportRun, :active, %{}, %{session_id: session.id, or: filters},
             many: true,
             lock: true,
             sort: [:id]
           ) do
      {:ok, Enum.find(rows, &(&1.id == delivery.run_id))}
    end
  end

  defp lock_deliveries(session, id) do
    with {:ok, rows} <-
           store_read(
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
            with {:ok, ids} <- reply_ids(config, session, delivery),
                 {:ok, row} <- reserve_read(delivery, now) do
              {:ok, {:read, row, session, generation, ids}}
            else
              {:error, :history_changed} -> fence(delivery, now, :history_changed)
              error -> error
            end

          {:probe, generation} ->
            with {:ok, _} <- fence(delivery, now, :unavailable),
                 do:
                   {:ok,
                    {:probe, session, delivery.deadline_at, generation,
                     Ownership.epoch_snapshot(config, session)}}

          :open ->
            fence(delivery, now, :unavailable)
        end
    end
  end

  defp preflight(_, _, _, _), do: {:ok, :finished}

  defp reply_ids(config, session, %{payload_digest: digest}) when is_binary(digest) do
    with {:ok, receipts} <- RunProcessing.covered_receipts(session, config.run),
         do: {:ok, Enum.map(receipts, &elem(&1, 1))}
  end

  defp reply_ids(_, _, _), do: {:ok, nil}

  defp read_reply_history(session, %{purpose: :public_reply} = delivery, {:ok, _}, ids) do
    history = ChatwootAdapter.history(session, delivery.deadline_at)
    context = if ids, do: ChatwootAdapter.decision_context(session, ids, delivery.deadline_at)
    {history, {ids, context}}
  end

  defp read_reply_history(_, _, _, _), do: nil

  defp fresh_evidenced_read(session, %{payload_digest: digest} = delivery, ids)
       when is_binary(digest) do
    deadline = earlier(delivery.deadline_at, delivery.lease_expires_at)

    {ChatwootAdapter.observe(session, deadline),
     {ids, ChatwootAdapter.decision_context(session, ids, deadline)}}
  end

  defp fresh_evidenced_read(_, _, _), do: nil

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

  defp qualify(_config, session, _delivery, now, {:ok, %{status: :resolved}}, _) do
    Ownership.close_locked(
      session,
      %{observed_status: :resolved, observed_at: now},
      now
    )
  end

  defp qualify(
         config,
         session,
         %{purpose: :public_reply} = delivery,
         now,
         {:ok, observation},
         {{:ok, history}, context}
       ) do
    cond do
      observation.assignee == :human ->
        with {:ok, _} <- fence(delivery, now, :human_takeover) do
          Ownership.human_takeover(session, %{observed_assignee: :human, observed_at: now}, now)
        end

      Ownership.eligible_bot?(config, session, observation) ->
        with {:ok, inputs} <- RunProcessing.inputs(delivery.run_id),
             :ok <- RunProcessing.check_coverage(inputs, history),
             {:ok, false} <- Ownership.pending_input?(session),
             :ok <- check_evidenced_claim(config, session, delivery, context) do
          claim_reply(delivery, now)
        else
          {:ok, true} -> {:ok, :input_pending}
          {:error, :history_changed} -> fence(delivery, now, :history_changed)
          {:error, :stale_evidence} -> fence(delivery, now, :stale_policy)
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
    do: fail_intent(delivery, :fail, reason)

  defp fail_intent(delivery, action, reason) do
    with {:ok, row} <-
           store_update(delivery, action, %{
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

  defp claim_reply(%{payload_digest: digest} = delivery, _) when is_binary(digest) do
    now = ChatwootAdapter.now()

    if DateTime.before?(now, delivery.deadline_at),
      do: claim_delivery(delivery, now),
      else: expire_pending(delivery, now)
  end

  defp claim_reply(delivery, now), do: claim_delivery(delivery, now)

  defp claim_delivery(delivery, now) do
    lease = DateTime.add(now, @lease_seconds)

    with {:ok, row} <-
           store_update(delivery, :claim, %{
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
               store_update(delivery, :authorize_dispatch, %{
                 dispatch_authorized_at: now
               }) do
          {:ok, {:authorized, row, text}}
        else
          {:ok, true} ->
            store_update(delivery, :safe_retry, %{
              claim_generation: delivery.claim_generation + 1
            })

          {:error, :stale_policy} ->
            fence(delivery, now, :stale_policy)

          error ->
            error
        end
    end
  end

  defp newer_input?(session, %{purpose: :public_reply}), do: Ownership.pending_input?(session)
  defp newer_input?(_, _), do: {:ok, false}

  defp render(_config, %{purpose: :handoff_status}), do: {:ok, nil}
  defp render(_config, %{payload_digest: digest}) when is_binary(digest), do: {:ok, nil}

  defp render(config, delivery),
    do: Configuration.render_fixed_reply(config.assistant, config.run, delivery)

  defp evidence_owner, do: __MODULE__

  defp check_evidenced_claim(
         config,
         session,
         %{payload_digest: digest} = delivery,
         {ids, context}
       )
       when is_binary(digest) do
    with {:ok, ^ids} <- reply_ids(config, session, delivery),
         {:ok, _} <- render_evidenced(config, delivery, context) do
      :ok
    else
      {:ok, _} -> {:error, :history_changed}
      error -> error
    end
  end

  defp check_evidenced_claim(_, _, _, _), do: :ok

  defp render_evidenced(config, delivery, {:ok, context}) do
    run = config.run

    with true <- run.retention_state != :purged,
         true <- run.decision == :typed_reply and is_nil(run.shadow_disposition),
         true <- DateTime.compare(run.deadline_at, delivery.deadline_at) == :eq,
         true <- Base.encode16(context.commitment, case: :lower) == run.context_digest,
         {:ok, evidence} <- Retrieval.at_dispatch(&evidence_owner/0, config, run),
         {:ok, text} <- EvidenceReply.render(run.typed_decision, evidence),
         true <- EvidenceReply.digest(run, text) == delivery.payload_digest do
      {:ok, text}
    else
      false -> {:error, :stale_evidence}
      error -> error
    end
  end

  defp render_evidenced(_, _, _), do: {:error, :history_changed}

  defp dispatch_current(config, session, delivery, authorized, generation, fresh, text) do
    now = ChatwootAdapter.now()

    cond do
      not current_claim?(delivery, authorized) or
          delivery.dispatch_authorized_at != authorized.dispatch_authorized_at ->
        {:ok, :stale_claim}

      not DateTime.before?(now, delivery.lease_expires_at) or
          not DateTime.before?(now, delivery.deadline_at) ->
        unknown(delivery, now, :ambiguous_write)

      not valid?(config, session, delivery, now) or
          not BindingCircuit.closed?(config.binding, generation) ->
        # Only this worker reached the gate directly from its own authorization.
        # A denial here never enters post/3. Other callers must treat the marker
        # as a possible write and leave the attempt for reconciliation.
        store_update(delivery, :cancel, %{reason_code: :dispatch_denied})

      true ->
        dispatch_payload(config, session, delivery, fresh, text)
    end
  end

  defp dispatch_payload(
         config,
         session,
         %{payload_digest: digest} = delivery,
         {{:ok, %{status: status, assignee: assignee} = observation}, _},
         _
       )
       when is_binary(digest) and (status == :resolved or assignee == :human) do
    with {:ok, _} <- store_update(delivery, :cancel, %{reason_code: :dispatch_denied}) do
      Ownership.observe(config, session, observation, ChatwootAdapter.now())
    end
  end

  defp dispatch_payload(config, session, %{payload_digest: digest} = delivery, fresh, _)
       when is_binary(digest) do
    with {{:ok, observation}, {ids, context}} <- fresh,
         true <- Ownership.eligible_bot?(config, session, observation),
         {:ok, ^ids} <- reply_ids(config, session, delivery),
         {:ok, false} <- newer_input?(session, delivery),
         {:ok, text} <- render_evidenced(config, delivery, context) do
      now = ChatwootAdapter.now()

      if DateTime.diff(now, delivery.last_read_at, :millisecond) < 2_000 and
           DateTime.diff(delivery.lease_expires_at, now, :millisecond) > @request_margin_ms and
           DateTime.diff(delivery.deadline_at, now, :millisecond) > @request_margin_ms do
        {:ok, {:dispatch_current, text}}
      else
        unknown(delivery, now, :ambiguous_write)
      end
    else
      {:error, error} when is_exception(error) -> {:error, error}
      _ -> store_update(delivery, :cancel, %{reason_code: :dispatch_denied})
    end
  end

  defp dispatch_payload(_, _, _, _, text), do: {:ok, {:dispatch_current, text}}

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
      if config.binding.security_epoch == claim.binding_epoch do
        :ok = BindingCircuit.record(config.binding, generation, now, result)
      end

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

  defp finish_post(_, delivery, _now, {:error, {:not_issued, :disabled}}),
    do: fail_intent(delivery, :cancel, :dispatch_denied)

  defp finish_post(_, delivery, _now, {:error, {:not_issued, :deadline}}),
    do: fail_intent(delivery, :cancel, :deadline)

  defp finish_post(_, delivery, _now, {:error, {:not_issued, _}}),
    do: fail_intent(delivery, :fail, :no_effect)

  defp finish_post(_, delivery, now, _result), do: unknown(delivery, now, :ambiguous_write)

  @doc false
  def fence(%{state: :sending, dispatch_authorized_at: time} = delivery, now, reason)
      when not is_nil(time),
      do: unknown(delivery, now, reason)

  def fence(%{purpose: :handoff_status, state: state} = delivery, _now, :deadline)
      when state in [:pending, :sending],
      do: fail_intent(delivery, :cancel, :deadline)

  def fence(%{state: state} = delivery, _now, reason) when state in [:pending, :sending],
    do:
      store_update(delivery, :cancel, %{
        reason_code: reason
      })

  def fence(row, _, _), do: {:ok, row}

  @doc false
  def unknown(delivery, now, reason) do
    deadline =
      if delivery.purpose == :public_reply, do: DateTime.add(now, 300), else: delivery.deadline_at

    with {:ok, row} <-
           store_update(delivery, :mark_unknown, %{
             uncertainty_reason: reason,
             recovery_deadline_at: deadline,
             read_count: if(delivery.purpose == :public_reply, do: 0, else: delivery.read_count)
           }),
         {:ok, _} <- SystemAudit.append(row, :delivery_unknown, reason),
         {:ok, _} <- Ownership.enqueue(Reconcile, %{"delivery_id" => delivery.id}) do
      {:ok, row}
    end
  end

  @doc false
  def reserve_read(delivery, now) do
    store_update(delivery, :reserve_read, %{
      read_sequence: delivery.read_sequence + 1,
      read_count: delivery.read_count + 1,
      last_read_at: now
    })
  end

  @doc false
  def confirm(delivery, now, message_id, reason) do
    action = if delivery.state == :unknown, do: :reconcile, else: :confirm_sent

    store_update(delivery, action, %{
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
            (is_nil(delivery.payload_digest) or config.run.claim_generation > 0) and
            RunProcessing.valid_run?(config, session, config.run)

        :handoff_status ->
          session.state == :handoff_pending
      end
  end

  defp earlier(left, right), do: if(DateTime.compare(left, right) == :lt, do: left, else: right)
end
