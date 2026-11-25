defmodule VoelgoedAi.Support.Recovery do
  @moduledoc """
  Recovers expired local claims and reads back uncertain writes. Read
  reservations keep late observations from changing a settled outcome.
  """

  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Delivery, InboundEvent, OutboundDelivery}
  alias VoelgoedAi.Support.{Ownership, RunProcessing, SupportRun, WorkStore}
  alias VoelgoedAi.Support.Workers.{Deliver, ProcessEvent, ProcessRun, Reconcile}

  @batch_size 25

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

  defp reserve(_, session, %{state: :unknown} = row, now) do
    cond do
      not remaining?(row, now) or row.read_count >= 3 ->
        exhausted(row)

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
                 now,
                 :resolved
               ) do
          exhausted(row)
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
      else: exhausted(row)
  end

  defp exhausted(%{reason_code: :read_exhausted}), do: {:ok, :finished}

  defp exhausted(row),
    do: WorkStore.update(row, :reconcile, %{reason_code: :read_exhausted})

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
            else: exhausted(row)

        _ ->
          {:ok, :finished}
      end
    end)
    |> RunProcessing.job_result()
  end

  defp recover_send(%{dispatch_authorized_at: nil, attempt_count: 0} = row, now) do
    if DateTime.compare(now, row.deadline_at) == :lt do
      with {:ok, updated} <-
             WorkStore.update(row, :safe_retry, %{
               state: :pending,
               lease_expires_at: nil,
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
        RunProcessing.finish(run, :fail, :failed, now, :deadline)

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
    do: RunProcessing.finish(run, :fail, :failed, now, :unavailable)

  defp retry_run(run, now) do
    with {:ok, row} <-
           WorkStore.update(run, :recover_expired_claim, %{
             state: :retry_wait,
             lease_expires_at: nil,
             retry_at: now,
             claim_generation: run.claim_generation + 1
           }),
         {:ok, row} <- WorkStore.update(row, :requeue, %{state: :queued, retry_at: nil}) do
      Ownership.enqueue(ProcessRun, %{"run_id" => row.id})
    end
  end

  @doc "Find a bounded set of durable work whose individual job may have been lost."
  def sweep do
    now = ChatwootAdapter.now()

    with %{} <- ChatwootAdapter.fixture(),
         {:ok, %{events: events, runs: runs, deliveries: deliveries}} <-
           Repo.transact(fn -> due(now) end) do
      for event <- events, do: Ownership.enqueue(ProcessEvent, %{"event_id" => event.id})
      for run <- runs, do: run_deadline(run.id)
      for delivery <- deliveries, do: delivery_deadline(delivery.id)
      :ok
    else
      nil -> :ok
      error -> RunProcessing.job_result(error)
    end
  end

  defp due(now) do
    opts = [many: true, sort: [:inserted_at, :id], limit: @batch_size]

    with {:ok, events} <-
           WorkStore.read(
             InboundEvent,
             :pending,
             %{},
             %{state: :dispatched, disposition: :pending},
             opts
           ),
         {:ok, runs} <-
           WorkStore.read(
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
           WorkStore.read(
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
end
