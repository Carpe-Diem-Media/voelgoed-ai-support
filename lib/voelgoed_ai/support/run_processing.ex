defmodule VoelgoedAi.Support.RunProcessing do
  @moduledoc """
  Admits qualified input and completes one bounded batch under a fenced run
  claim. Only verified history supplies message order.
  """

  use VoelgoedAi.Support.WorkStore, [:read, :create, :update]

  alias VoelgoedAi.Governance.Admission
  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.{
    ChatwootAdapter,
    Configuration,
    Delivery,
    InboundEvent
  }

  alias VoelgoedAi.Support.{Ownership, RunInput, SupportRun, SystemAudit}
  alias VoelgoedAi.Support.Workers.{ProcessRun, Sweep}

  @max_pending 100
  @active [:queued, :running, :retry_wait]

  @doc "Process one internal receipt ID; completed receipts can be replayed safely."
  def process_event(id),
    do: VoelgoedAi.Support.JobAction.invoke(InboundEvent, :process_receipt, id)

  @doc false
  def perform_event(id) do
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
        with {:ok, session} <- route_overdue(config, session, event, now, observation) do
          disposition(event, session, :triage, :deadline, now)
        end

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

  # The receipt's GET may have exhausted its budget. Use the last qualified
  # local state to stage the route. Delivery gets a separate budget and GET.
  defp route_overdue(config, session, %{kind: :input, contact_id: contact}, now, observation)
       when contact == session.contact_id do
    case observation do
      {:ok, %{status: :pending, assignee: :bot, team: team}}
      when team == config.binding.handoff_team_id ->
        Ownership.route_overdue_locked(config, session, now)

      {:error, reason} when reason != :scope_denied ->
        Ownership.route_overdue_locked(config, session, now)

      _ ->
        {:ok, session}
    end
  end

  defp route_overdue(_, session, _, _, _), do: {:ok, session}

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
             store_create(RunInput, :cover, %{
               run_id: run.id,
               event_id: event.id,
               position: position
             }) do
        disposition(event, session, :covered, :accepted, now)
      end
    else
      {:error, :late_input} ->
        with :ok <- discard_incomplete(batch, delivery, now),
             {:ok, session} <- route_expired_batch(batch, config, session, now) do
          disposition(event, session, :triage, :late_input, now)
        end

      {:error, :admission_limited} ->
        # An exhausted AI allowance cannot stop staff routing in shadow.
        with {:ok, session} <- route_limited_shadow(config, session, now) do
          disposition(event, session, :triage, :admission_limited, now)
        end

      {:error, reason} when reason in [:awaiting_operator, :stale_policy] ->
        disposition(event, session, :triage, reason, now)

      error ->
        error
    end
  end

  if Mix.env() == :test do
    defp route_limited_shadow(config, session, now) do
      if Ownership.shadow_evaluation_enabled?(config),
        do: Ownership.route_overdue_locked(config, session, now),
        else: {:ok, session}
    end
  else
    defp route_limited_shadow(_config, session, _now), do: {:ok, session}
  end

  defp route_expired_batch(batch, config, session, now) do
    if batch && not DateTime.before?(now, batch.deadline_at),
      do: Ownership.route_overdue_locked(config, session, now),
      else: {:ok, session}
  end

  defp discard_incomplete(run, delivery, now) do
    cond do
      delivery != nil ->
        with {:ok, _} <- Delivery.fence(delivery, now, :late_input), do: :ok

      run != nil ->
        with {:ok, _} <- finish(run, :fail, now, :late_input), do: :ok

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
           store_read(SupportRun, :active, %{}, %{state: %{in: @active}},
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
      Admission.window(
        :global_minute,
        Map.get(fixture, :global_scope, "global"),
        now,
        60,
        fixture.global_limit
      )
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
           store_update(run, :extend_batch, %{
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
    with {:ok, _} <- finish(previous, :supersede, now, :late_input), do: :ok
  end

  defp move_inputs(inputs, run_id) do
    Enum.reduce_while(inputs, :ok, fn input, :ok ->
      with {:ok, _} <- store_update(input, :release, %{current: false}),
           {:ok, _} <-
             store_create(RunInput, :cover, %{
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
    with {:ok, run} <- store_create(SupportRun, :queue, attrs),
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
    with {:ok, row} <-
           store_update(event, :record_disposition, %{
             session_id: session.id,
             disposition: disposition,
             reason_code: reason,
             processed_at: now
           }) do
      audit_deadline(row)
    end
  end

  @doc "Claim the current batch and complete its fixed or shadow workflow."
  def process_run(id), do: VoelgoedAi.Support.JobAction.invoke(SupportRun, :process_run, id)

  @doc false
  def perform_run(id) do
    with {:ok, {:claimed, run, session, work}} <- with_run(id, &claim/4) do
      process_claim(work, run, session)
    else
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp complete_claim(run, decision) do
    with_run(run.id, fn config, session, current, now ->
      complete(config, session, current, run, now, decision)
    end)
    |> job_result()
  end

  defp process_claim(:fixed, run, session) do
    complete_claim(
      run,
      {:fixed, ChatwootAdapter.observe(session, run.deadline_at),
       ChatwootAdapter.history(session, run.deadline_at)}
    )
  end

  if Mix.env() == :test do
    alias VoelgoedAi.Intelligence.Generation
    alias VoelgoedAi.Knowledge.{ArticleRevision, Retrieval}
    alias VoelgoedAi.Support.DecisionTemplates

    defp process_claim({:shadow, receipts, locale}, run, session) do
      cutoff = run.lease_expires_at
      original = read_evidence_context(session, receipts, cutoff)
      observation = ChatwootAdapter.observe(session, cutoff)
      context = compare_context(session, receipts, cutoff, original, observation)

      with {:ok, context} <- context,
           {:ok, observation} <- observation,
           {:ok, %{decision: "handoff", reason_code: "missing_evidence"}} <-
             DecisionTemplates.decide(context, locale, true),
           %{shadow_inference: %{} = _settings} <- ChatwootAdapter.fixture(),
           {:ok, query} <- shadow_query(context) do
        result =
          Retrieval.with_shadow(
            &evidence_owner/0,
            run,
            session,
            observation,
            receipts,
            Atom.to_string(locale) <> "-ZA",
            query,
            fn search ->
              evaluate_shadow(search, run, session, receipts, context, query, locale, observation)
            end
          )

        case result do
          {:error, :denied} ->
            complete_claim(run, {:shadow, receipts, {:ok, observation}, {:ok, context}})

          other ->
            other
        end
      else
        _ -> complete_claim(run, {:shadow, receipts, observation, context})
      end
    end

    defp shadow_query(%{current: [%{text: first} | rest], prior: prior}) do
      query = String.trim(first)
      # A regroup may repeat the same question. Different current messages
      # need staff to resolve the combined intent before using one FAQ.
      if Enum.all?(rest, &(String.trim(&1.text) == query)) and
           not String.contains?(query, <<0>>) do
        {:ok, {query, follow_up_topic(query, List.last(prior))}}
      else
        :error
      end
    end

    defp follow_up_topic(query, %{role: :contact, text: text}) do
      if Regex.match?(~r/\A(?:and|en)\s/iu, query) and not String.contains?(text, <<0>>),
        do: text,
        else: ""
    end

    defp follow_up_topic(_, _), do: ""

    defp compare_context(session, receipts, cutoff, original, observation) do
      with {:ok, original} <- original,
           {:ok, _} <- observation,
           {:ok, current} <- read_evidence_context(session, receipts, cutoff),
           true <- original.commitment == current.commitment do
        {:ok, current}
      else
        {:error, :scope_denied} = denial -> denial
        _ -> {:error, :history_changed}
      end
    end

    defp evaluate_shadow(search, run, session, receipts, original, {query, _}, locale, verified) do
      found =
        ArticleRevision
        |> Ash.ActionInput.for_action(:search_published, %{query: query}, actor: search)
        |> Ash.run_action()

      observation = ChatwootAdapter.observe(session, run.lease_expires_at)

      if observation == {:ok, verified} do
        propose_shadow(found, run, session, receipts, original, locale, observation)
      else
        # An outage on a later read must never hide a definite scope loss.
        complete_claim(run, {:shadow, receipts, observation, {:error, :history_changed}})
      end
    end

    defp propose_shadow(found, run, session, receipts, original, locale, observation) do
      cutoff = run.lease_expires_at
      context = compare_context(session, receipts, cutoff, {:ok, original}, observation)

      proposal =
        case {found, context, observation} do
          {{:ok, %{status: :evidence, evidence: [%{mode: :exact} = item]}}, {:ok, _}, {:ok, _}} ->
            {DecisionTemplates.build(locale, "answer_exact", "supported", [item.revision_id]),
             [item]}

          {{:ok, %{status: :evidence, evidence: items}}, {:ok, current}, {:ok, observed}} ->
            generated = Generation.propose(&evidence_owner/0, run, current, items, observed)
            {generated, items}

          {{:ok, %{status: :no_evidence}}, _, _} ->
            {DecisionTemplates.build(locale, "handoff", "missing_evidence"), []}

          {{:ok, %{status: :denied}}, _, _} ->
            {DecisionTemplates.build(locale, "handoff", "conflicting_evidence"), []}

          _ ->
            {{:error, :unavailable}, []}
        end

      # Reread even when the transport is unusable: an edit, a missed
      # receipt, or human takeover can invalidate any suggested answer.
      observation = ChatwootAdapter.observe(session, cutoff)
      context = compare_context(session, receipts, cutoff, context, observation)

      complete_claim(
        run,
        shadow_result(proposal, receipts, observation, context, original.commitment, locale)
      )
    end

    defp shadow_result(
           {{:ok, %{decision: kind} = decision}, items},
           receipts,
           {:ok, _} = observation,
           {:ok, _} = context,
           commitment,
           _locale
         )
         when kind in ["answer_exact", "answer_grounded"] do
      by_revision = Map.new(items, &{&1.revision_id, &1.citation_id})
      citations = Enum.map(decision.evidence_revision_ids, &Map.get(by_revision, &1))
      {:evidenced, :shadow, receipts, observation, context, commitment, decision, citations}
    end

    defp shadow_result({proposal, _}, receipts, observation, context, _commitment, locale) do
      decision =
        case proposal do
          {:ok, %{decision: "clarify"}} ->
            DecisionTemplates.build(locale, "clarify", "ambiguous")

          {:ok, %{decision: "handoff", reason_code: reason}} ->
            DecisionTemplates.build(locale, "handoff", reason)

          _ ->
            DecisionTemplates.build(locale, "handoff", "unavailable")
        end

      {:shadow, receipts, observation, context, decision}
    end
  end

  @doc false
  def with_run(id, operation) do
    Repo.transact(fn ->
      with {:ok, %SupportRun{} = candidate} <- Ownership.get(SupportRun, id) do
        Ownership.locked_session(candidate.session_id, fn config, session, _now ->
          with {:ok, %SupportRun{} = run} <- Ownership.get(SupportRun, id, lock: true) do
            operation.(config, session, run, ChatwootAdapter.now())
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
        finish(run, :fail, now, :deadline)

      not valid_run?(config, session, run) ->
        finish(run, :cancel, now, :stale_policy)

      DateTime.compare(now, run.batch_cutoff_at) == :lt ->
        {:ok, :debouncing}

      true ->
        # with_run holds the singleton control row through the count and claim.
        # All claims take that same lock, including claims for other inboxes.
        with {:ok, running} <-
               store_read(SupportRun, :active, %{}, %{state: :running}, many: true, limit: 5),
             {:ok, nil} <- Ownership.blocking_delivery(session, lock: true) do
          if length(running) < 5, do: claim_run(config, run, session, now), else: {:ok, :capacity}
        else
          {:ok, _} -> finish(run, :cancel, now, :awaiting_operator)
          error -> error
        end
    end
  end

  defp claim(_, _, _, _), do: {:ok, :finished}

  defp claim_run(config, run, session, now) do
    with {:ok, work} <- claim_work(config, session, run),
         lease = if(work == :fixed, do: DateTime.add(now, 5), else: run.deadline_at),
         {:ok, run} <-
           store_update(run, :claim, %{
             lease_expires_at: lease,
             claim_generation: run.claim_generation + 1,
             attempt_count: run.attempt_count + 1,
             started_at: now
           }),
         {:ok, _} <- Ownership.enqueue(Sweep, %{"run_id" => run.id}, scheduled_at: lease) do
      {:ok, {:claimed, run, session, work}}
    else
      {:error, reason} when reason in [:history_changed, :stale_policy] ->
        finish(run, :cancel, now, reason)

      error ->
        error
    end
  end

  if Mix.env() == :test do
    defp claim_work(config, session, run) do
      if Ownership.shadow_evaluation_enabled?(config) do
        with {:ok, %{response_policy: :shadow_decision, locale: locale}} <-
               Configuration.current_revision(config.assistant),
             {:ok, receipts} <- covered_receipts(session, run) do
          {:ok, {:shadow, receipts, locale}}
        else
          {:ok, _} -> {:error, :stale_policy}
          error -> error
        end
      else
        {:ok, :fixed}
      end
    end
  else
    defp claim_work(_config, _session, _run), do: {:ok, :fixed}
  end

  defp complete(config, session, run, claim, now, decision) do
    cond do
      run.state != :running or run.claim_generation != claim.claim_generation ->
        {:ok, :stale_claim}

      DateTime.compare(now, run.deadline_at) != :lt or
          DateTime.compare(now, run.lease_expires_at) != :lt ->
        finish(run, :fail, now, :deadline)

      not valid_run?(config, session, run) or run.watermark != claim.watermark ->
        finish(run, :cancel, now, :stale_policy)

      true ->
        finalize(config, session, run, now, decision)
    end
  end

  if Mix.env() == :test do
    alias VoelgoedAi.Knowledge.Retrieval
    alias VoelgoedAi.Knowledge.Retrieval.Reference
    alias VoelgoedAi.Support.{DecisionTemplates, EvidenceReply, SupportDecision}

    @doc false
    def claim_evidence_fixture(id) do
      with {:ok, {:claimed, run, session, _}} <- with_run(id, &claim/4),
           {:ok, receipts} <-
             with_run(id, fn _, current, row, _ -> covered_receipts(current, row) end),
           {:ok, context} <- read_evidence_context(session, receipts, run.lease_expires_at) do
        {:ok, {run, session, receipts, context}}
      end
    end

    @doc false
    def complete_evidence_fixture({claim, session, receipts, original}, proposal, citations) do
      with {:ok, decision} <- SupportDecision.cast(proposal) do
        observation = ChatwootAdapter.observe(session, claim.lease_expires_at)
        context = read_evidence_context(session, receipts, claim.lease_expires_at)

        with_run(claim.id, fn config, session, run, now ->
          complete(
            config,
            session,
            run,
            claim,
            now,
            {:evidenced, :dispatch_fixture, receipts, observation, context, original.commitment,
             decision, citations}
          )
        end)
      end
    end

    defp read_evidence_context(session, receipts, deadline) do
      ChatwootAdapter.decision_context(session, Enum.map(receipts, &elem(&1, 1)), deadline)
    end

    defp evidence_owner, do: __MODULE__

    defp finalize(config, session, run, now, {:fixed, observation, history}),
      do: decide(config, session, run, now, observation, history)

    defp finalize(
           config,
           session,
           run,
           now,
           {:evidenced, source, receipts, {:ok, observation}, {:ok, context}, commitment,
            decision, citations}
         ) do
      shadow? = Ownership.shadow_evaluation_enabled?(config)

      cond do
        not shadow? and (source == :shadow or not Ownership.write_enabled?(config)) ->
          finish(run, :cancel, now, :stale_policy)

        not Ownership.eligible_bot?(config, session, observation) ->
          with {:ok, _} <- finish(run, :cancel, now, :scope_denied) do
            Ownership.observe(config, session, observation, now)
          end

        true ->
          with true <- context.commitment == commitment,
               {:ok, ^receipts} <- covered_receipts(session, run),
               {:ok, false} <- Ownership.pending_input?(session),
               {:ok, items} <- Retrieval.at_decision(&evidence_owner/0, config, run, citations),
               {:ok, text} <- EvidenceReply.render(decision, items),
               finished_at = ChatwootAdapter.now(),
               :lt <-
                 DateTime.compare(
                   finished_at,
                   Enum.min([run.deadline_at, run.lease_expires_at], DateTime)
                 ),
               {:ok, completed} <-
                 store_update(run, :complete_evidenced, %{
                   decision: if(shadow?, do: :no_send, else: :typed_reply),
                   typed_decision: decision,
                   evidence_refs: Enum.map(items, &Reference.from_evidence/1),
                   context_digest: Base.encode16(commitment, case: :lower),
                   shadow_disposition: if(shadow?, do: :no_send),
                   finished_at: finished_at
                 }) do
            if shadow? do
              {:ok, completed}
            else
              Ownership.prepare(
                config,
                session,
                completed,
                {:typed_reply, EvidenceReply.digest(completed, text)},
                run.deadline_at
              )
            end
          else
            cutoff when cutoff in [:eq, :gt] ->
              finish(run, :fail, ChatwootAdapter.now(), :deadline)

            {:error, reason} when reason in [:stale_evidence, :history_changed] ->
              reject_evidence(config, session, run, observation, shadow?)

            {:ok, _} ->
              reject_evidence(config, session, run, observation, shadow?)

            false ->
              reject_evidence(config, session, run, observation, shadow?)

            error ->
              error
          end
      end
    end

    defp finalize(
           config,
           session,
           run,
           now,
           {:evidenced, source, receipts, observation, _, _, _, _}
         ) do
      if source == :shadow or Ownership.shadow_evaluation_enabled?(config) do
        finalize(
          config,
          session,
          run,
          now,
          {:shadow, receipts, observation, {:error, :history_changed}}
        )
      else
        finish(run, :fail, now, :history_changed)
      end
    end

    defp finalize(config, session, run, now, {:shadow, receipts, observation, context}),
      do: finalize(config, session, run, now, {:shadow, receipts, observation, context, nil})

    defp finalize(
           config,
           session,
           run,
           now,
           {:shadow, receipts, {:ok, observation}, context, decision}
         ) do
      cond do
        not Ownership.shadow_evaluation_enabled?(config) ->
          finish(run, :cancel, now, :stale_policy)

        not Ownership.eligible_bot?(config, session, observation) ->
          with {:ok, _} <- finish(run, :cancel, now, :scope_denied) do
            Ownership.observe(config, session, observation, now)
          end

        true ->
          with {:ok, ^receipts} <- covered_receipts(session, run),
               {:ok, false} <- Ownership.pending_input?(session),
               {:ok, revision} <- Configuration.current_revision(config.assistant) do
            decide_shadow(config, session, run, revision, now, observation, context, decision)
          else
            {:ok, _} ->
              finish(run, :fail, now, :history_changed)

            {:error, reason} when reason in [:history_changed, :stale_policy] ->
              finish(run, :fail, now, reason)

            error ->
              error
          end
      end
    end

    # A failed observation cannot restore scope that the history check denied.
    defp finalize(_, _, run, now, {:shadow, _, {:error, _}, {:error, :scope_denied}, _}),
      do: finish(run, :fail, now, :scope_denied)

    defp finalize(config, session, run, now, {:shadow, receipts, {:error, reason}, _, _})
         when reason in [:unavailable, :deadline, :rate_limited] do
      # The completion transaction already checked the claim, cutoff and
      # epochs. Preserve the failed run alongside the fenced staff intent.
      with {:ok, ^receipts} <- covered_receipts(session, run),
           {:ok, false} <- Ownership.pending_input?(session),
           {:ok, failed} <- finish(run, :fail, now, :unavailable) do
        case Ownership.route_shadow_locked(config, session, :observation_unavailable, now) do
          {:ok, _} -> {:ok, failed}
          {:error, :scope_denied} -> {:ok, failed}
          error -> error
        end
      else
        {:ok, _} -> finish(run, :fail, now, :history_changed)
        {:error, :history_changed} -> finish(run, :fail, now, :history_changed)
        error -> error
      end
    end

    defp finalize(_, _, run, now, {:shadow, _, {:error, reason}, _, _}) do
      finish(run, :fail, now, if(reason == :scope_denied, do: reason, else: :unavailable))
    end

    defp decide_shadow(
           config,
           session,
           run,
           revision,
           _now,
           observation,
           {:ok, context},
           proposed
         ) do
      # Treat the same session as unresolved until a verified close creates a
      # new generation. A new phrase alone cannot reset the clarification cap.
      with {:ok, prior} <-
             store_read(SupportRun, :shadow_clarifications, %{}, %{session_id: session.id},
               many: true,
               limit: 2
             ),
           now = ChatwootAdapter.now(),
           true <- DateTime.before?(now, run.lease_expires_at),
           {:ok, decision} <-
             shadow_decision(proposed, context, revision.locale, length(prior) < 2),
           handoff? = decision.decision == "handoff",
           {:ok, completed} <-
             store_update(run, :complete_shadow, %{
               typed_decision: decision,
               shadow_disposition: if(handoff?, do: :local_handoff, else: :no_send),
               finished_at: now
             }) do
        if handoff?,
          do: Ownership.route_shadow_locked(config, session, observation, now),
          else: {:ok, completed}
      else
        false -> finish(run, :fail, ChatwootAdapter.now(), :deadline)
        error -> error
      end
    end

    defp decide_shadow(config, session, run, _, now, observation, {:error, reason}, _)
         when reason in [:history_changed, :scope_denied] do
      with {:ok, _} <- finish(run, :fail, now, reason) do
        Ownership.route_shadow_locked(config, session, observation, now)
      end
    end

    defp shadow_decision(nil, context, locale, available?),
      do: DecisionTemplates.decide(context, locale, available?)

    defp shadow_decision({:ok, %{decision: "clarify"}}, _, locale, false),
      do: DecisionTemplates.build(locale, "handoff", "missing_evidence")

    defp shadow_decision(proposal, _, _, _), do: proposal

    defp reject_evidence(config, session, run, observation, shadow?) do
      now = ChatwootAdapter.now()

      with {:ok, failed} <- finish(run, :fail, now, :history_changed) do
        if shadow?,
          do: Ownership.route_shadow_locked(config, session, observation, now),
          else: {:ok, failed}
      end
    end
  else
    defp finalize(config, session, run, now, {:fixed, observation, history}),
      do: decide(config, session, run, now, observation, history)
  end

  # Inbound event locks are taken only with the session lock held. Ingress
  # acquires control before receipt work and takes the session before
  # registering a signed human event, so it cannot invert this order.
  @doc false
  def covered_receipts(session, run) do
    with {:ok, inputs} when inputs != [] <- inputs(run.id) do
      Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, ids} ->
        case Ownership.get(InboundEvent, input.event_id, lock: true) do
          {:ok, %InboundEvent{state: :dispatched, disposition: :covered, kind: :input} = event}
          when event.session_id == session.id and event.contact_id == session.contact_id ->
            if ChatwootAdapter.destination(event) == ChatwootAdapter.destination(session) do
              {:cont, {:ok, [{event.id, event.message_id} | ids]}}
            else
              {:halt, {:error, :history_changed}}
            end

          {:ok, _} ->
            {:halt, {:error, :history_changed}}

          error ->
            {:halt, error}
        end
      end)
    else
      {:ok, []} -> {:error, :history_changed}
      error -> error
    end
  end

  defp decide(config, session, run, now, {:ok, observation}, {:ok, history}) do
    if Ownership.eligible_bot?(config, session, observation) do
      with {:ok, revision} <- Configuration.current_revision(config.assistant),
           {:ok, inputs} <- inputs(run.id),
           :ok <- check_coverage(inputs, history) do
        complete_decision(config, session, run, now, revision.response_policy)
      else
        {:error, :history_changed} -> finish(run, :fail, now, :history_changed)
        error -> error
      end
    else
      with {:ok, _} <- finish(run, :cancel, now, :scope_denied) do
        Ownership.observe(config, session, observation, now)
      end
    end
  end

  defp decide(_, _, run, now, _, _), do: finish(run, :fail, now, :unavailable)

  defp complete_decision(config, session, run, now, policy) do
    decision =
      if policy in [:fixed_reply, :handoff] and Ownership.write_enabled?(config),
        do: policy,
        else: :no_send

    with {:ok, completed} <-
           store_update(run, :complete, %{
             decision: decision,
             finished_at: now
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
             {:ok, _} <- store_update(input, :set_position, %{position: position}) do
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
      store_read(RunInput, :for_run, %{}, %{run_id: run_id, current: true},
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
  def finish(%SupportRun{} = run, action, now, reason)
      when action in [:cancel, :fail, :supersede] do
    with {:ok, row} <-
           store_update(run, action, %{
             reason_code: reason,
             finished_at: now
           }) do
      audit_deadline(row)
    end
  end

  defp audit_deadline(%{reason_code: :deadline} = row) do
    with {:ok, _} <- SystemAudit.append(row, :missed_deadline, :deadline), do: {:ok, row}
  end

  defp audit_deadline(row), do: {:ok, row}

  @doc false
  def job_result({:ok, result}) do
    unless Repo.in_transaction?(), do: VoelgoedAi.Support.OperationalAlert.report(result)
    :ok
  end

  def job_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  def job_result({:error, _}), do: {:error, :storage_failure}
end
