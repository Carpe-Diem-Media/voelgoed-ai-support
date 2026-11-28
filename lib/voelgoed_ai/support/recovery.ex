defmodule VoelgoedAi.Support.Recovery do
  @moduledoc """
  Recovers expired local claims and reads back uncertain writes. Read
  reservations keep late observations from changing a settled outcome.
  """

  use VoelgoedAi.Support.WorkStore, [:read, :update]

  alias VoelgoedAi.Support.{ChatwootAdapter, Delivery, OutboundDelivery}
  alias VoelgoedAi.Support.{Ownership, RunProcessing, SupportRun}
  alias VoelgoedAi.Support.Workers.{Deliver, ProcessRun, Reconcile}

  @doc "Reconcile one UNKNOWN intent with qualified, bounded read-only evidence."
  def reconcile(id),
    do: VoelgoedAi.Support.JobAction.invoke(OutboundDelivery, :reconcile_intent, id)

  @doc false
  def perform_reconciliation(id) do
    with {:ok, {:read, delivery, session}} <- Delivery.with_delivery(id, &reserve/4) do
      observed = read_back(session, delivery)

      Delivery.with_delivery(id, fn config, session, current, now ->
        settle(config, session, current, delivery, now, observed)
      end)
      |> RunProcessing.job_result()
    else
      result -> RunProcessing.job_result(result)
    end
  end

  @doc false
  def operator_readback(staff, id, audit) do
    with {:ok, {:read, delivery, session}} <-
           VoelgoedAi.Accounts.StaffAccess.with_current(staff, :support_operator, fn operator ->
             Delivery.with_delivery(id, fn config, session, row, now ->
               with {:ok, {:read, reserved, _}} <- reserve(config, session, row, now),
                    {:ok, _} <- audit.(operator, row, reserved, :request_readback) do
                 {:ok, {:read, reserved, session}}
               end
             end)
           end) do
      observed = read_back(session, delivery)

      Delivery.with_delivery(id, fn config, session, current, now ->
        settle(config, session, current, delivery, now, observed)
      end)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp reserve(_, session, %{state: :unknown} = row, now) do
    cond do
      not remaining?(row, now) or row.read_count >= 3 ->
        exhausted(row, now)

      row.last_read_at &&
          DateTime.diff(now, row.last_read_at, :millisecond) <
            if(row.read_count == 1, do: 1_000, else: 3_000) ->
        {:ok, :backoff}

      true ->
        with {:ok, reserved} <- Delivery.reserve_read(row, now),
             do: {:ok, {:read, reserved, session}}
    end
  end

  defp reserve(_, _, _, _), do: {:ok, :finished}

  defp read_back(session, %{purpose: :handoff_status} = row),
    do: ChatwootAdapter.observe(session, row.recovery_deadline_at)

  defp read_back(session, row), do: ChatwootAdapter.history(session, row.recovery_deadline_at)

  defp settle(config, session, row, reservation, now, observed) do
    if row.state == :unknown and row.read_sequence == reservation.read_sequence and
         remaining?(row, now) do
      evidence(config, session, row, now, observed)
    else
      {:ok, :stale_claim}
    end
  end

  defp evidence(_config, _session, %{purpose: :public_reply} = row, now, {:ok, messages}) do
    matches =
      Enum.filter(
        messages,
        &(&1.sender == :bot and &1.operation == row.operation_ref and is_integer(&1.id) and
            &1.id in 1..9_223_372_036_854_775_807)
      )

    case matches do
      [message] -> Delivery.confirm(row, now, message.id, :accepted)
      _ -> read_again(row, now)
    end
  end

  defp evidence(config, session, %{purpose: :handoff_status} = row, now, {:ok, observation}) do
    cond do
      observation.status == :resolved and session.state != :closed ->
        with {:ok, _} <-
               Ownership.close_locked(
                 session,
                 %{observed_status: :resolved, observed_at: now},
                 now
               ) do
          exhausted(row, now)
        end

      Delivery.human_goal?(config, observation) ->
        with {:ok, _} <- Delivery.confirm(row, now, nil, :accepted),
             {:ok, _} <- Ownership.confirm_locked(session) do
          {:ok, :confirmed}
        end

      true ->
        read_again(row, now)
    end
  end

  defp evidence(_, _, row, now, _), do: read_again(row, now)

  defp read_again(row, now) do
    when_due = DateTime.add(now, if(row.read_count == 1, do: 1, else: 3))

    if row.read_count < 3 and remaining?(row, when_due),
      do: Ownership.enqueue(Reconcile, %{"delivery_id" => row.id}, scheduled_at: when_due),
      else: exhausted(row, now)
  end

  defp exhausted(%{reason_code: :read_exhausted}, _now), do: {:ok, :finished}

  defp exhausted(row, now) do
    reason = if remaining?(row, now), do: :read_exhausted, else: :deadline

    with {:ok, updated} <- store_update(row, :record_read_exhausted, %{}) do
      Delivery.audit_handoff_failure(updated, reason)
    end
  end

  defp remaining?(row, now), do: DateTime.compare(now, row.recovery_deadline_at) == :lt

  @doc "Recover a delivery lease or expire an outstanding intent."
  def delivery_deadline(id),
    do: VoelgoedAi.Support.JobAction.invoke(OutboundDelivery, :recover_intent, id)

  @doc false
  def perform_delivery_recovery(id) do
    Delivery.with_delivery(id, fn _, _, row, now ->
      case row do
        %{state: :sending, lease_expires_at: time} ->
          if DateTime.compare(now, time) != :lt, do: recover_send(row, now), else: {:ok, :active}

        %{state: :pending, deadline_at: time} ->
          if DateTime.compare(now, time) != :lt,
            do: Delivery.expire_pending(row, now),
            else: Ownership.enqueue(Deliver, %{"delivery_id" => row.id})

        %{state: :unknown} ->
          if remaining?(row, now) and row.reason_code != :read_exhausted,
            do: Ownership.enqueue(Reconcile, %{"delivery_id" => row.id}),
            else: exhausted(row, now)

        _ ->
          {:ok, :finished}
      end
    end)
    |> RunProcessing.job_result()
  end

  defp recover_send(%{dispatch_authorized_at: nil, attempt_count: 0} = row, now) do
    if DateTime.compare(now, row.deadline_at) == :lt do
      with {:ok, updated} <-
             store_update(row, :safe_retry, %{
               claim_generation: row.claim_generation + 1
             }),
           {:ok, _} <- Ownership.enqueue(Deliver, %{"delivery_id" => updated.id}) do
        {:ok, updated}
      end
    else
      Delivery.fence(row, now, :deadline)
    end
  end

  defp recover_send(row, now), do: Delivery.unknown(row, now, :ambiguous_write)

  @doc "Expire a run or recover a bounded local-only claim under a new token."
  def run_deadline(id), do: VoelgoedAi.Support.JobAction.invoke(SupportRun, :recover_run, id)

  @doc false
  def perform_run_recovery(id) do
    RunProcessing.with_run(id, fn _, _, run, now -> recover_run(run, now) end)
    |> RunProcessing.job_result()
  end

  defp recover_run(%{state: state} = run, now) when state in [:queued, :running, :retry_wait] do
    cond do
      DateTime.compare(now, run.deadline_at) != :lt ->
        RunProcessing.finish(run, :fail, now, :deadline)

      state == :running and DateTime.compare(now, run.lease_expires_at) != :lt ->
        retry_run(run, now)

      state == :queued and DateTime.compare(now, run.batch_cutoff_at) != :lt ->
        Ownership.enqueue(ProcessRun, %{"run_id" => run.id})

      true ->
        {:ok, :active}
    end
  end

  defp recover_run(_, _), do: {:ok, :finished}

  defp retry_run(%{attempt_count: count} = run, now) when count >= 2,
    do: RunProcessing.finish(run, :fail, now, :unavailable)

  defp retry_run(run, now) do
    with {:ok, row} <-
           store_update(run, :recover_expired_claim, %{
             retry_at: now,
             claim_generation: run.claim_generation + 1
           }),
         {:ok, row} <- store_update(row, :requeue, %{}) do
      Ownership.enqueue(ProcessRun, %{"run_id" => row.id})
    end
  end

  if Mix.env() == :test do
    alias VoelgoedAi.Repo
    alias VoelgoedAi.Support.{Configuration, InboundEvent, SupportSession}
    alias VoelgoedAi.Support.Workers.{ProcessEvent, Sweep}

    @batch_size 25

    @doc "Find a bounded set of durable work whose individual job may have been lost."
    def sweep do
      now = ChatwootAdapter.now()

      with %{} = fixture <- ChatwootAdapter.fixture(),
           {:ok, {binding, %{events: events, runs: runs, deliveries: deliveries}}} <-
             Repo.transact(fn ->
               inbox =
                 Map.take(fixture, [:installation_ref, :external_account_id, :external_inbox_id])

               with {:ok, config} <- Configuration.lock_inbox(inbox),
                    {:ok, work} <- due(now) do
                 {:ok, {config.binding, work}}
               end
             end) do
        for event <- events, do: Ownership.enqueue(ProcessEvent, %{"event_id" => event.id})
        for run <- runs, do: run_deadline(run.id)
        for delivery <- deliveries, do: delivery_deadline(delivery.id)
        idle_result = sweep_idle(nil)
        alert_result = VoelgoedAi.Support.OperationalAlert.project(binding, now)
        if idle_result == :ok, do: alert_result, else: idle_result
      else
        nil -> :ok
        {:error, :scope_denied} -> :ok
        error -> RunProcessing.job_result(error)
      end
    end

    @doc false
    def sweep_idle(cursor) do
      with %{shadow_evaluation: true} = fixture <- ChatwootAdapter.fixture(),
           scope =
             Map.take(fixture, [:installation_ref, :external_account_id, :external_inbox_id]),
           {:ok, candidates} <- idle_candidates(scope, cursor),
           :ok <- continue_idle(candidates) do
        candidates
        |> Enum.reduce({:ok, :idle_checked}, fn candidate, outcome ->
          case check_idle(candidate) do
            {:ok, _} -> outcome
            {:error, :scope_denied} -> outcome
            error -> error
          end
        end)
        |> RunProcessing.job_result()
      else
        {:error, _} = error -> RunProcessing.job_result(error)
        _ -> :ok
      end
    end

    defp idle_candidates(scope, cursor) do
      where =
        Map.put(scope, :verified_input_at, %{
          less_than_or_equal: idle_cutoff(ChatwootAdapter.now())
        })

      where = if cursor, do: Map.put(where, :id, %{greater_than: cursor}), else: where

      Repo.transact(fn ->
        store_read(SupportSession, :idle_candidates, %{}, where,
          many: true,
          sort: [:id],
          limit: @batch_size
        )
      end)
    end

    # A later batch can progress even if the first page has persistent outages.
    defp continue_idle(candidates) when length(candidates) == @batch_size do
      with {:ok, _} <-
             Ownership.enqueue(Sweep, %{"idle_after" => List.last(candidates).id},
               unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]
             ),
           do: :ok
    end

    defp continue_idle(_), do: :ok

    defp check_idle(candidate) do
      with {:ok, {:eligible, snapshot, deadline}} <-
             with_idle(candidate, fn config, session, now ->
               {:ok, {:eligible, Ownership.epoch_snapshot(config, session), DateTime.add(now, 5)}}
             end),
           {:ok, observation} <- ChatwootAdapter.observe(candidate, deadline),
           {:ok, action} <- idle_action(candidate, observation, deadline) do
        with_idle(candidate, fn config, session, now ->
          if DateTime.before?(now, deadline) and Ownership.current?(config, session, snapshot) do
            case action do
              :observe ->
                Ownership.observe(config, session, observation, now)

              :route ->
                Ownership.route_shadow_locked(config, session, observation, now, :idle_triage)
            end
          else
            {:ok, :ineligible}
          end
        end)
      else
        {:error, reason}
        when reason in [:deadline, :unavailable, :rate_limited, :history_changed] ->
          {:ok, :ineligible}

        false ->
          {:ok, :ineligible}

        result ->
          result
      end
    end

    # A qualified assignment or resolution is independent of idle text proof.
    defp idle_action(_, %{assignee: :human}, _), do: {:ok, :observe}
    defp idle_action(_, %{status: :resolved}, _), do: {:ok, :observe}

    defp idle_action(candidate, _, deadline) do
      with {:ok, %{latest_id: last_id, texts: texts}} <-
             ChatwootAdapter.receipt_text(candidate, deadline),
           true <- last_id == candidate.verified_input_id and Map.has_key?(texts, last_id) do
        {:ok, :route}
      end
    end

    defp with_idle(candidate, operation) do
      Repo.transact(fn ->
        Ownership.locked_session(candidate.id, fn config, session, now ->
          with true <- Ownership.shadow_evaluation_enabled?(config),
               {:ok, %{response_policy: :shadow_decision}} <-
                 Configuration.current_revision(config.assistant),
               true <-
                 session.binding_id == config.binding.id and session.state == :bot_active and
                   not session.human_inhibit and session.observed_status == :pending and
                   session.observed_assignee == :bot,
               true <-
                 session.ownership_epoch == candidate.ownership_epoch and
                   session.verified_input_at == candidate.verified_input_at and
                   session.verified_input_id == candidate.verified_input_id,
               true <- not DateTime.after?(session.verified_input_at, idle_cutoff(now)),
               {:ok, false} <- Ownership.pending_input?(session),
               {:ok, nil} <- Ownership.active_run(session, lock: true),
               {:ok, nil} <- Ownership.blocking_delivery(session, lock: true) do
            operation.(config, session, now)
          else
            false -> {:ok, :ineligible}
            {:error, :stale_policy} -> {:ok, :ineligible}
            {:ok, _} -> {:ok, :ineligible}
            error -> error
          end
        end)
      end)
    end

    defp idle_cutoff(now), do: DateTime.add(now, -1800)

    defp due(now) do
      opts = [many: true, sort: [:inserted_at, :id], limit: @batch_size]

      with {:ok, events} <-
             store_read(
               InboundEvent,
               :pending,
               %{},
               %{state: :dispatched, disposition: :pending},
               opts
             ),
           {:ok, runs} <-
             store_read(
               SupportRun,
               :recoverable,
               %{},
               %{
                 or: [
                   %{state: :queued, batch_cutoff_at: %{less_than_or_equal: now}},
                   %{state: :running, lease_expires_at: %{less_than_or_equal: now}}
                 ]
               },
               opts
             ),
           {:ok, deliveries} <-
             store_read(
               OutboundDelivery,
               :recoverable,
               %{},
               %{
                 or: [
                   %{state: :pending},
                   %{state: :sending, lease_expires_at: %{less_than_or_equal: now}},
                   %{
                     state: :unknown,
                     or: [
                       %{reason_code: %{is_nil: true}},
                       %{reason_code: %{not_eq: :read_exhausted}}
                     ]
                   }
                 ]
               },
               opts
             ) do
        {:ok, %{events: events, runs: runs, deliveries: deliveries}}
      end
    end
  else
    @doc "Find a bounded set of durable work whose individual job may have been lost."
    def sweep, do: :ok
    @doc false
    def sweep_idle(_), do: :ok
  end
end
