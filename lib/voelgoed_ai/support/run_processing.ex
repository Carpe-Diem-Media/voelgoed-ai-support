defmodule VoelgoedAi.Support.RunProcessing do
  @moduledoc """
  Admits qualified input and completes one bounded batch under a fenced run
  claim. Only verified history supplies message order.
  """

  alias VoelgoedAi.Governance.Admission
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, Delivery, InboundEvent}
  alias VoelgoedAi.Support.{Ownership, RunInput, SupportRun, WorkStore}
  alias VoelgoedAi.Support.Workers.{ProcessRun, Sweep}

  @max_pending 100
  @active [:queued, :running, :retry_wait]

  @doc "Process one internal receipt ID; completed receipts can be replayed safely."
  def process_event(id) do
    with {:ok, %InboundEvent{disposition: :pending, state: :dispatched} = event} <-
           Repo.transact(fn -> Ownership.get(InboundEvent, id) end) do
      verify_event(event)
    else
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp verify_event(event) do
    deadline = DateTime.add(event.received_at, 45)
    observation = ChatwootAdapter.observe(event, deadline)

    history =
      if event.kind == :input and match?({:ok, _}, observation),
        do: ChatwootAdapter.history(event, deadline),
        else: {:ok, []}

    Repo.transact(fn ->
      with {:ok, config, session, event, now} <- Ownership.lock_event(event) do
        decide_event(config, session, event, now, deadline, observation, history)
      end
    end)
    |> job_result()
  end

  defp decide_event(_, _, %{disposition: disposition}, _, _, _, _) when disposition != :pending,
    do: {:ok, :finished}

  defp decide_event(config, session, event, now, deadline, observation, history) do
    cond do
      DateTime.compare(now, deadline) != :lt ->
        disposition(event, session, :triage, :deadline, now)

      session.contact_id != event.contact_id ->
        disposition(event, session, :triage, :scope_denied, now)

      true ->
        case {observation, history} do
          {{:ok, observation}, {:ok, history}} ->
            with {:ok, session} <- Ownership.observe(config, session, observation, now) do
              qualify_input(config, session, event, now, deadline, observation, history)
            end

          _ ->
            disposition(event, session, :triage, :unavailable, now)
        end
    end
  end

  defp qualify_input(_, session, %{kind: kind} = event, now, _, _, _) when kind != :input,
    do: disposition(event, session, :observed, :accepted, now)

  defp qualify_input(config, session, event, now, deadline, observation, history) do
    with true <-
           session.state == :bot_active and Ownership.eligible_bot?(config, session, observation),
         position when is_integer(position) <-
           Enum.find_index(history, &(&1.id == event.message_id and &1.sender == :contact)),
         {:ok, candidate} <- Ownership.blocking_delivery(session),
         {:ok, active} <- Ownership.active_run(session, lock: true),
         {:ok, batch} <- batch_candidate(active, candidate),
         {:ok, delivery} <- Ownership.blocking_delivery(session, lock: true) do
      admit(config, session, event, batch, delivery, now, deadline, position)
    else
      false -> disposition(event, session, :triage, :scope_denied, now)
      nil -> disposition(event, session, :triage, :history_changed, now)
      error -> error
    end
  end

  defp admit(config, session, event, batch, delivery, now, deadline, position) do
    with :ok <- admit_slot(delivery),
         {:ok, revision} <- Configuration.current_revision(config.assistant),
         :ok <- authorize_capacity(batch),
         :ok <- ensure_current_batch(batch, config, session, now),
         :ok <- charge(event, now, batch == nil),
         {:ok, run} <- schedule(config, session, revision, batch, delivery, now, deadline) do
      with {:ok, _} <-
             WorkStore.create(RunInput, :cover, %{
               run_id: run.id,
               event_id: event.id,
               position: position
             }) do
        disposition(event, session, :covered, :accepted, now)
      end
    else
      {:error, :late_input} ->
        with :ok <- discard_incomplete(batch, delivery, now) do
          disposition(event, session, :triage, :late_input, now)
        end

      {:error, reason} when reason in [:admission_limited, :awaiting_operator, :stale_policy] ->
        disposition(event, session, :triage, reason, now)

      error ->
        error
    end
  end

  defp discard_incomplete(run, delivery, now) do
    cond do
      delivery != nil ->
        with {:ok, _} <- Delivery.fence(delivery, now, :late_input), do: :ok

      run != nil ->
        with {:ok, _} <- finish(run, :fail, :failed, now, :late_input), do: :ok

      true ->
        :ok
    end
  end

  defp admit_slot(%{state: :unknown}), do: {:error, :awaiting_operator}

  defp admit_slot(%{state: :sending, dispatch_authorized_at: time}) when not is_nil(time),
    do: {:error, :awaiting_operator}

  defp admit_slot(%{purpose: :handoff_status}), do: {:error, :awaiting_operator}
  defp admit_slot(_), do: :ok

  defp authorize_capacity(nil) do
    with {:ok, rows} <-
           WorkStore.read(SupportRun, :active, %{}, %{state: %{in: @active}},
             many: true,
             limit: @max_pending
           ) do
      if length(rows) < @max_pending, do: :ok, else: {:error, :admission_limited}
    end
  end

  defp authorize_capacity(_), do: :ok

  defp batch_candidate(nil, %{run_id: id}) when is_binary(id),
    do: Ownership.get(SupportRun, id, lock: true)

  defp batch_candidate(run, _), do: {:ok, run}

  defp ensure_current_batch(nil, _, _, _), do: :ok

  defp ensure_current_batch(batch, config, session, now) do
    with true <- Ownership.current?(config, session, batch),
         :lt <- DateTime.compare(now, batch.deadline_at),
         true <- batch.state == :queued or batch.regroup_count == 0,
         {:ok, rows} <- inputs(batch.id),
         true <- length(rows) < ChatwootAdapter.fixture().batch_size do
      :ok
    else
      error when is_tuple(error) -> error
      _ -> {:error, :late_input}
    end
  end

  defp charge(event, now, new_turn?) do
    fixture = ChatwootAdapter.fixture()
    account = "#{event.installation_ref}:#{event.external_account_id}"
    inbox = "#{account}:inbox:#{event.external_inbox_id}:input"
    contact = "#{account}:contact:#{event.contact_id}:input"
    conversation = "#{account}:conversation:#{event.conversation_id}:turn"

    messages = [
      Admission.window(:contact_minute, contact, now, 60, 10),
      Admission.window(:contact_hour, contact, now, 3_600, 60),
      Admission.window(:inbox_minute, inbox, now, 60, fixture.inbox_limit),
      Admission.window(:global_minute, "global", now, 60, fixture.global_limit)
    ]

    turns = [
      Admission.window(:contact_day, contact, now, 86_400, 40),
      Admission.window(:conversation_day, conversation, now, 86_400, 40)
    ]

    Admission.reserve(if new_turn?, do: messages ++ turns, else: messages)
  end

  defp schedule(config, session, revision, nil, _, now, deadline) do
    attrs = %{
      session_id: session.id,
      assistant_revision_id: revision.id,
      turn_ref: Ash.UUIDv7.generate(),
      correlation_id: session.correlation_id,
      deadline_at: deadline,
      batch_cutoff_at: cutoff(now, deadline),
      watermark: 1
    }

    queue(Map.merge(attrs, Ownership.epoch_snapshot(config, session)))
  end

  defp schedule(_, _, _, %{state: :queued} = run, _, now, _) do
    with {:ok, run} <-
           WorkStore.update(run, :extend_batch, %{
             batch_cutoff_at: cutoff(now, run.deadline_at),
             watermark: run.watermark + 1
           }),
         {:ok, _} <- enqueue_run(run) do
      {:ok, run}
    end
  end

  defp schedule(_, _, _, previous, delivery, now, _) do
    attrs =
      previous
      |> Map.take([
        :session_id,
        :assistant_revision_id,
        :turn_ref,
        :correlation_id,
        :deadline_at,
        :ownership_epoch,
        :assistant_epoch,
        :binding_epoch,
        :control_epoch
      ])
      |> Map.merge(%{
        parent_run_id: previous.id,
        regroup_count: 1,
        watermark: previous.watermark + 1,
        batch_cutoff_at: cutoff(now, previous.deadline_at)
      })

    with :ok <- suppress(previous, delivery, now),
         {:ok, run} <- queue(attrs),
         {:ok, inputs} <- inputs(previous.id),
         :ok <- move_inputs(inputs, run.id) do
      {:ok, run}
    end
  end

  defp suppress(%{state: :completed}, delivery, now) do
    with {:ok, _} <- Delivery.fence(delivery, now, :late_input), do: :ok
  end

  defp suppress(previous, _, now) do
    with {:ok, _} <- finish(previous, :supersede, :superseded, now, :late_input), do: :ok
  end

  defp move_inputs(inputs, run_id) do
    Enum.reduce_while(inputs, :ok, fn input, :ok ->
      with {:ok, _} <- WorkStore.update(input, :release, %{current: false}),
           {:ok, _} <-
             WorkStore.create(RunInput, :cover, %{
               run_id: run_id,
               event_id: input.event_id,
               position: input.position
             }) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp queue(attrs) do
    with {:ok, run} <- WorkStore.create(SupportRun, :queue, attrs),
         {:ok, _} <- enqueue_run(run),
         {:ok, _} <-
           Ownership.enqueue(Sweep, %{"run_id" => run.id}, scheduled_at: run.deadline_at) do
      {:ok, run}
    end
  end

  defp enqueue_run(run),
    do: Ownership.enqueue(ProcessRun, %{"run_id" => run.id}, scheduled_at: run.batch_cutoff_at)

  defp cutoff(now, deadline) do
    hard_cutoff = DateTime.add(deadline, -40)
    proposed = DateTime.add(now, 1)
    if DateTime.compare(proposed, hard_cutoff) == :lt, do: proposed, else: hard_cutoff
  end

  defp disposition(event, session, disposition, reason, now) do
    WorkStore.update(event, :record_disposition, %{
      session_id: session.id,
      disposition: disposition,
      reason_code: reason,
      processed_at: now
    })
  end

  @doc "Claim the current batch and render or suppress its fixed response."
  def process_run(id) do
    with {:ok, {:claimed, run, session}} <- with_run(id, &claim/4) do
      observation = ChatwootAdapter.observe(session, run.deadline_at)
      history = ChatwootAdapter.history(session, run.deadline_at)

      with_run(id, fn config, session, current, now ->
        complete(config, session, current, run, now, observation, history)
      end)
      |> job_result()
    else
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  def with_run(id, operation) do
    Repo.transact(fn ->
      with {:ok, %SupportRun{} = candidate} <- Ownership.get(SupportRun, id) do
        Ownership.locked_session(candidate.session_id, fn config, session, now ->
          with {:ok, %SupportRun{} = run} <- Ownership.get(SupportRun, id, lock: true) do
            operation.(config, session, run, now)
          end
        end)
      else
        {:ok, nil} -> {:ok, :missing}
        error -> error
      end
    end)
  end

  defp claim(config, session, %{state: :queued} = run, now) do
    cond do
      DateTime.compare(now, run.deadline_at) != :lt ->
        finish(run, :fail, :failed, now, :deadline)

      not valid_run?(config, session, run) ->
        finish(run, :cancel, :cancelled, now, :stale_policy)

      DateTime.compare(now, run.batch_cutoff_at) == :lt ->
        {:ok, :debouncing}

      true ->
        with {:ok, running} <-
               WorkStore.read(SupportRun, :active, %{}, %{state: :running}, many: true, limit: 5),
             {:ok, nil} <- Ownership.blocking_delivery(session, lock: true) do
          if length(running) < 5, do: claim_run(run, session, now), else: {:ok, :capacity}
        else
          {:ok, _} -> finish(run, :cancel, :cancelled, now, :awaiting_operator)
          error -> error
        end
    end
  end

  defp claim(_, _, _, _), do: {:ok, :finished}

  defp claim_run(run, session, now) do
    lease = DateTime.add(now, 5)

    attrs = %{
      state: :running,
      lease_expires_at: lease,
      claim_generation: run.claim_generation + 1,
      attempt_count: run.attempt_count + 1,
      started_at: now
    }

    with {:ok, run} <- WorkStore.update(run, :claim, attrs),
         {:ok, _} <- Ownership.enqueue(Sweep, %{"run_id" => run.id}, scheduled_at: lease) do
      {:ok, {:claimed, run, session}}
    end
  end

  defp complete(config, session, run, claim, now, observation, history) do
    cond do
      run.state != :running or run.claim_generation != claim.claim_generation ->
        {:ok, :stale_claim}

      DateTime.compare(now, run.deadline_at) != :lt or
          DateTime.compare(now, run.lease_expires_at) != :lt ->
        finish(run, :fail, :failed, now, :deadline)

      not valid_run?(config, session, run) or run.watermark != claim.watermark ->
        finish(run, :cancel, :cancelled, now, :stale_policy)

      true ->
        decide(config, session, run, now, observation, history)
    end
  end

  defp decide(config, session, run, now, {:ok, observation}, {:ok, history}) do
    if Ownership.eligible_bot?(config, session, observation) do
      with {:ok, revision} <- Configuration.current_revision(config.assistant),
           {:ok, inputs} <- inputs(run.id),
           :ok <- check_coverage(inputs, history) do
        complete_decision(config, session, run, now, revision.response_policy)
      else
        {:error, :history_changed} -> finish(run, :fail, :failed, now, :history_changed)
        error -> error
      end
    else
      with {:ok, _} <- finish(run, :cancel, :cancelled, now, :scope_denied) do
        Ownership.observe(config, session, observation, now)
      end
    end
  end

  defp decide(_, _, run, now, _, _), do: finish(run, :fail, :failed, now, :unavailable)

  defp complete_decision(config, session, run, now, policy) do
    decision = if Ownership.write_enabled?(config), do: policy, else: :no_send

    with {:ok, completed} <-
           WorkStore.update(run, :complete, %{
             state: :completed,
             decision: decision,
             finished_at: now,
             lease_expires_at: nil
           }) do
      case decision do
        :fixed_reply ->
          Ownership.prepare(config, session, completed, :public_reply, run.deadline_at)

        :handoff ->
          Ownership.request_locked(config, session, now)

        :no_send ->
          {:ok, completed}
      end
    end
  end

  @doc false
  def check_coverage(inputs, history) do
    indexed = Enum.with_index(history)
    positions = Map.new(indexed, fn {message, index} -> {message.id, {message.sender, index}} end)

    last_contact =
      Enum.reduce(indexed, -1, fn
        {%{sender: :contact}, index}, _ -> index
        _, latest -> latest
      end)

    result =
      Enum.reduce_while(inputs, {:ok, -1}, fn input, {:ok, latest} ->
        with {:ok, %InboundEvent{} = event} <- Ownership.get(InboundEvent, input.event_id),
             {:contact, position} <- Map.get(positions, event.message_id),
             {:ok, _} <- WorkStore.update(input, :set_position, %{position: position}) do
          {:cont, {:ok, max(latest, position)}}
        else
          _ -> {:halt, {:error, :history_changed}}
        end
      end)

    # A newer contact message in verified history can invalidate a fixed
    # reply even if its webhook was missed and it has no local receipt.
    case result do
      {:ok, ^last_contact} when last_contact >= 0 -> :ok
      _ -> {:error, :history_changed}
    end
  end

  @doc false
  def inputs(run_id),
    do:
      WorkStore.read(RunInput, :for_run, %{}, %{run_id: run_id, current: true},
        many: true,
        sort: [:id],
        lock: true
      )

  @doc false
  def valid_run?(config, session, run) do
    session.state == :bot_active and not session.human_inhibit and
      Ownership.permitted?(config) and Ownership.current?(config, session, run) and
      config.assistant.active_revision_id == run.assistant_revision_id
  end

  @doc false
  def finish(run, action, state, now, reason),
    do:
      WorkStore.update(run, action, %{
        state: state,
        reason_code: reason,
        finished_at: now,
        lease_expires_at: nil,
        retry_at: nil
      })

  @doc false
  def job_result({:ok, _}), do: :ok
  def job_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  def job_result({:error, _}), do: {:error, :storage_failure}
end
