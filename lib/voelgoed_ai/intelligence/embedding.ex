defmodule VoelgoedAi.Intelligence.Embedding do
  @moduledoc """
  Owns article and query embedding claims, dispatch fences and settlements.
  Article work locks control, collection, article, revision and generation
  rows before the attempt and hold. Query work qualifies the support claim
  first under control, and money-only recovery checks its immutable parent.
  Accounting takes windows last. Only a committed dispatch can invoke.
  """

  use Ash.Resource.Actions.Implementation

  alias VoelgoedAi.Governance.{AuditEvent, EmbeddingAccounting}
  alias VoelgoedAi.Intelligence.{EmbeddingProfile, EmbeddingTransport, Generation, InferenceRun}

  alias VoelgoedAi.Knowledge.{
    Article,
    ArticleEmbedding,
    ArticleRevision,
    Content,
    KnowledgeCollection,
    Publication,
    Storage
  }

  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, Ownership, SupportRun}

  @indexing_seconds 60
  @timeout_ms 5_000

  if Mix.env() == :test do
    alias VoelgoedAi.Governance.FinancialControl

    @impl Ash.Resource.Actions.Implementation
    def run(%{arguments: %{id: id, reason: :conservative_closure}} = input, _opts, %{
          actor: session
        }) do
      FinancialControl.with_authority(input, session, fn control, staff_id ->
        with {:ok, candidate} <- get(InferenceRun, id),
             {:ok, _context, attempt} <- lock_recovery(candidate, nil),
             {:ok, reservation} <- reservation(attempt) do
          close_unknown(control, attempt, reservation, staff_id)
        end
      end)
      |> case do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, "embedding closure denied"}
      end
    end

    defp close_unknown(control, attempt, reservation, staff_id) do
      closed_at = now()

      with {:ok, settlement} <-
             account(attempt, :finish, fn ref ->
               EmbeddingAccounting.finish(
                 ref,
                 control,
                 attempt,
                 reservation,
                 closed_at,
                 {:conservative_closure, staff_id}
               )
             end) do
        case settlement do
          :amount_overflow ->
            {:ok, %{id: attempt.id, state: :unknown}}

          :conservative_closure when attempt.state == :abandoned ->
            {:ok, %{id: attempt.id, state: :abandoned}}

          :conservative_closure ->
            with {:ok, _} <-
                   change(attempt, %{
                     state: :abandoned,
                     finished_at: closed_at,
                     reason_code: :conservative_closure
                   }) do
              {:ok, %{id: attempt.id, state: :abandoned}}
            end
        end
      end
    end
  else
    @impl Ash.Resource.Actions.Implementation
    def run(_, _, _), do: {:error, "embedding closure denied"}
  end

  @doc false
  def publication_deadline(content) do
    now = now()

    with_fixture_settings(fn _settings ->
      with {:ok, expires} <- eligible_content(content, now) do
        deadline = DateTime.add(now, @indexing_seconds, :second)
        {:ok, if(expires, do: earlier(deadline, expires), else: deadline)}
      end
    end)
  end

  @doc "Process one durable article embedding row without replaying a reserved attempt."
  def index(id) do
    with false <- Repo.in_transaction?(),
         {:ok, %{id: attempt_id, dispatch_fence: fence} = attempt} <- claim(id) do
      hook(:after_claim, attempt)

      with {:ok, input, transport, dispatched} <-
             consume(fn -> dispatch(id, attempt_id, fence) end) do
        hook(:after_dispatch, dispatched)
        outcome = invoke(input, transport, dispatched)
        hook(:before_settlement, attempt)
        result(finish(id, attempt_id, fence, outcome))
      else
        {:error, reason}
        when reason in [
               :deadline,
               :stale_request,
               :embedding_inhibited,
               :disabled,
               :admission_denied,
               :invalid_price
             ] ->
          result(reject_before_dispatch(id, attempt_id, fence, reason))

        other ->
          result(other)
      end
    else
      true ->
        {:error, :transaction_open}

      {:error, reason}
      when reason in [
             :deadline,
             :stale_request,
             :embedding_inhibited,
             :disabled,
             :invalid_price,
             :amount_overflow,
             :unclassified_inhibit,
             :invalid_budget,
             :budget_exhausted,
             :invalid_content
           ] ->
        result(fail_queued(id, failure_reason(reason)))

      other ->
        result(other)
    end
  end

  @doc "Recover one due row. An expired unconsumed fence can prove non-dispatch."
  def recover(id) do
    transaction(id, fn control, context ->
      case context.row.last_attempt_id do
        nil -> recover_queued(context)
        attempt_id -> recover_attempt(control, context, attempt_id)
      end
    end)
    |> result()
  end

  @doc "Process a bounded batch of expired attempts. Each item rechecks the durable fence."
  def sweep do
    with {:ok, attempts} <-
           Repo.transact(fn ->
             read(InferenceRun, :recovery_candidates, %{
               now: now(),
               generation_now: ChatwootAdapter.now()
             })
           end) do
      Enum.reduce(attempts, :ok, fn attempt, result ->
        case recover_by_purpose(attempt) do
          :ok -> result
          error -> error
        end
      end)
    else
      _ -> {:error, :indexing_storage}
    end
  end

  @doc "Reapply previously captured query usage to its original financial windows."
  def recover_query(id) do
    Repo.transact(fn -> get(InferenceRun, id) end)
    |> case do
      {:ok, %{purpose: :query_embedding} = attempt} -> recover_by_purpose(attempt)
      _ -> {:error, :indexing_storage}
    end
  end

  defp recover_by_purpose(%{purpose: :article_embedding} = attempt),
    do: recover(attempt.article_embedding_id)

  defp recover_by_purpose(%{purpose: :generate, id: id}), do: Generation.recover(id)

  defp recover_by_purpose(%{purpose: :query_embedding} = attempt) do
    query_transaction(attempt, nil, fn control, current, reservation ->
      now = now()

      cond do
        current.overflow_evidence && is_nil(current.overflow_resolved_at) ->
          replay_embedding(control, nil, current, reservation, now)

        current.state != :running or DateTime.compare(now, current.deadline_at) == :lt ->
          {:ok, :noop}

        current.dispatched_at ->
          hold(control, nil, current, reservation, now, :deadline)

        true ->
          release(control, nil, current, reservation, now, :deadline)
      end
    end)
    |> result()
  end

  @doc false
  def query(ref, input, qualify)

  if Mix.env() == :test do
    alias VoelgoedAi.Knowledge.Retrieval

    def query(ref, input, qualify) do
      with false <- Repo.in_transaction?(),
           true <- EmbeddingProfile.bounded_input?(input),
           {:ok, mode} <- Retrieval.authorize_query(ref),
           {:ok, attempt} when is_struct(attempt, InferenceRun) <-
             qualify.(fn control, run, deadline ->
               with :ok <- query_lineage(mode, run), do: claim_query(control, run, deadline)
             end) do
        hook(:after_claim, attempt)

        case consume(fn ->
               qualify.(fn control, run, _ -> dispatch_query(control, run, attempt) end)
             end) do
          {:ok, {:dispatch, transport, dispatched}} ->
            hook(:after_dispatch, dispatched)

            outcome =
              invoke(input, query_transport(mode, transport, qualify, dispatched), dispatched)

            hook(:before_settlement, attempt)

            query_transaction(attempt, attempt.dispatch_fence, fn control, current, hold ->
              settle(control, nil, current, hold, now(), outcome)
            end)

          _ ->
            query_transaction(attempt, attempt.dispatch_fence, fn control, current, hold ->
              if current.state == :running and is_nil(current.dispatched_at) do
                release(control, nil, current, hold, now(), :stale_request)
              else
                {:ok, :noop}
              end
            end)

            {:error, :unavailable}
        end
      else
        _ -> {:error, :unavailable}
      end
    end

    defp query_lineage(:shadow, %{parent_run_id: parent} = run) when not is_nil(parent) do
      with {:ok, previous} <-
             query(
               InferenceRun,
               :query_attempt,
               %{support_run_id: parent},
               false,
               &Ash.read_one/1
             ),
           {:ok, slots} <-
             query(InferenceRun, :generation_slots, %{turn_ref: run.turn_ref}, false, &Ash.read/1),
           true <- Enum.all?(Enum.reject([previous | slots], &is_nil/1), &known_query_lineage?/1) do
        :ok
      else
        _ -> {:error, :unresolved_inference}
      end
    end

    defp query_lineage(_, _), do: :ok

    defp known_query_lineage?(%{state: state}), do: state in [:succeeded, :failed, :rejected]

    defp query_transport(_mode, {:fixture, wire} = transport, qualify, dispatched) do
      latch = :atomics.new(1, [])

      {:query_fixture,
       fn request ->
         with false <- Repo.in_transaction?(),
              :ok <- :atomics.compare_exchange(latch, 1, 0, 1),
              {:ok, cutoff} <-
                qualify.(fn control, run, cutoff ->
                  with {:ok, attempt} <-
                         lock_query_attempt(run, dispatched, dispatched.dispatch_fence),
                       true <-
                         attempt.state == :running and
                           attempt.dispatched_at == dispatched.dispatched_at,
                       true <- attempt.claim_generation == run.claim_generation,
                       true <- attempt.profile_id == EmbeddingProfile.id(),
                       :ok <- allowed(control),
                       {:ok, %{transport: ^transport} = config} <- gate(),
                       {:ok, hold} <- reservation(attempt),
                       :ok <-
                         EmbeddingAccounting.validate_dispatch(
                           attempt,
                           control,
                           hold,
                           now(),
                           config
                         ) do
                    {:ok, cutoff}
                  else
                    _ -> {:error, :stale_request}
                  end
                end),
              remaining when remaining > 0 <-
                DateTime.diff(cutoff, VoelgoedAi.Support.ChatwootAdapter.now(), :millisecond) do
           timeout = min(remaining, @timeout_ms)

           wire.(
             Req.merge(request,
               receive_timeout: timeout,
               finch: [pool_timeout: timeout],
               connect_options: [timeout: timeout, protocols: [:http1]]
             )
           )
         else
           _ -> {request, %Req.TransportError{reason: :closed}}
         end
       end}
    end

    defp claim_query(control, run, deadline) do
      now = now()

      with true <- DateTime.compare(now, deadline) == :lt,
           {:ok, config} <- gate(),
           :ok <- allowed(control),
           {:ok, nil} <-
             query(
               InferenceRun,
               :query_attempt,
               %{support_run_id: run.id},
               false,
               &Ash.read_one/1
             ),
           {:ok, attempt} <-
             storage(InferenceRun, :insert_query_attempt, fn actor ->
               Ash.create(
                 InferenceRun,
                 %{
                   support_run_id: run.id,
                   assistant_revision_id: run.assistant_revision_id,
                   claim_generation: run.claim_generation,
                   provider: EmbeddingProfile.provider(),
                   model_id: EmbeddingProfile.model(),
                   profile_id: EmbeddingProfile.id(),
                   ordinal: 1,
                   deadline_at: deadline,
                   started_at: now,
                   dispatch_fence: Ash.UUIDv7.generate(),
                   correlation_id: Ash.UUIDv7.generate()
                 },
                 action: :insert_query_attempt,
                 actor: actor
               )
             end),
           :ok <- reserve_query_admission(now),
           {:ok, _} <-
             account(
               attempt,
               :reserve,
               &EmbeddingAccounting.reserve(&1, control, attempt, now, config)
             ) do
        {:ok, attempt}
      else
        {:ok, _} -> {:error, :already_claimed}
        false -> {:error, :deadline}
        error -> error
      end
    end

    defp dispatch_query(control, run, candidate) do
      with {:ok, attempt} <- lock_query_attempt(run, candidate, candidate.dispatch_fence),
           :ok <- fresh_dispatch(attempt, run),
           true <- attempt.claim_generation == run.claim_generation,
           true <- attempt.profile_id == EmbeddingProfile.id(),
           true <- DateTime.compare(now(), attempt.deadline_at) == :lt,
           :ok <- allowed(control),
           {:ok, config} <- gate(),
           {:ok, hold} <- reservation(attempt),
           :ok <- EmbeddingAccounting.validate_dispatch(attempt, control, hold, now(), config),
           true <- DateTime.before?(now(), attempt.deadline_at),
           {:ok, dispatched} <- change(attempt, %{dispatched_at: now()}) do
        {:ok, {:dispatch, config.transport, dispatched}}
      else
        _ -> {:error, :unavailable}
      end
    end

    defp reserve_query_admission(now) do
      if fixture()[:query_admission] do
        alias VoelgoedAi.Governance.Admission
        Admission.reserve([Admission.window(:turn, "synthetic:query_embedding", now, 60, 2)])
      else
        :ok
      end
    end
  else
    def query(_, _, _), do: {:error, :disabled}
  end

  # Recovery authorizes money against the original parent even after answer
  # permission or the support claim is gone.
  defp query_transaction(candidate, fence, work) do
    Repo.transact(fn ->
      with {:ok, control} <- Configuration.lock_control(),
           {:ok, nil, attempt} <- lock_recovery(candidate, fence),
           {:ok, hold} <- reservation(attempt) do
        work.(control, attempt, hold)
      end
    end)
  rescue
    _ -> {:error, :indexing_storage}
  catch
    :exit, _ -> {:error, :indexing_storage}
  end

  defp lock_recovery(%{purpose: :article_embedding} = candidate, fence) do
    with {:ok, context} <- lock_context(candidate.article_embedding_id),
         {:ok, attempt} <- locked_attempt(context, candidate.id, fence) do
      {:ok, context, attempt}
    end
  end

  defp lock_recovery(%{purpose: :query_embedding} = candidate, fence) do
    with {:ok, run} when is_struct(run, SupportRun) <-
           Ownership.get(SupportRun, candidate.support_run_id),
         {:ok, attempt} <- lock_query_attempt(run, candidate, fence) do
      {:ok, nil, attempt}
    else
      {:ok, nil} -> {:error, :missing_row}
      error -> error
    end
  end

  defp lock_recovery(_, _), do: {:error, :invalid_purpose}

  defp lock_query_attempt(run, candidate, fence) do
    with {:ok, attempt} <- get(InferenceRun, candidate.id, true),
         true <- attempt.purpose == :query_embedding and attempt.support_run_id == run.id,
         true <- attempt.assistant_revision_id == run.assistant_revision_id,
         true <- attempt.profile_id == candidate.profile_id,
         true <- attempt.claim_generation == candidate.claim_generation,
         true <- is_nil(fence) or attempt.dispatch_fence == fence do
      {:ok, attempt}
    else
      false -> {:error, :stale_request}
      error -> error
    end
  end

  @doc false
  def authorize_accounting(ref, id, action) do
    if is_reference(ref) and Repo.in_transaction?() and
         Process.get({__MODULE__, :accounting}) == {ref, id, action},
       do: :ok,
       else: {:error, :denied}
  end

  @doc false
  def authorize_transport(ref) do
    is_reference(ref) and not Repo.in_transaction?() and
      Process.delete({__MODULE__, :transport}) == ref
  end

  defp claim(id) do
    transaction(id, fn control, context ->
      row = context.row
      now = now()

      with :ok <- queued(row) do
        with_fixture_settings(fn config ->
          with :ok <- eligible(context, now),
               {:ok, _input} <- EmbeddingProfile.input(context.revision.content, row.locale),
               {:ok, attempt} <-
                 insert(InferenceRun, %{
                   article_embedding_id: row.id,
                   provider: EmbeddingProfile.provider(),
                   model_id: EmbeddingProfile.model(),
                   profile_id: row.profile_id,
                   ordinal: row.attempt_count + 1,
                   deadline_at: row.deadline_at,
                   dispatch_fence: Ash.UUIDv7.generate(),
                   correlation_id: Ash.UUIDv7.generate()
                 }),
               {:ok, attempt} <- change(attempt, %{state: :running, started_at: now}),
               {:ok, _} <-
                 change(row, %{
                   state: :running,
                   attempt_count: attempt.ordinal,
                   last_attempt_id: attempt.id
                 }),
               {:ok, _} <-
                 account(
                   attempt,
                   :reserve,
                   &EmbeddingAccounting.reserve(&1, control, attempt, now, config)
                 ) do
            {:ok, attempt}
          end
        end)
      end
    end)
  end

  defp dispatch(id, attempt_id, fence) do
    transaction(id, fn control, context ->
      now = now()

      with {:ok, attempt} <- locked_attempt(context, attempt_id, fence),
           :ok <- fresh_dispatch(attempt, context.row) do
        with_fixture_settings(fn config ->
          with :ok <- eligible(context, now),
               :ok <- allowed(control),
               {:ok, hold} <- reservation(attempt),
               :ok <- EmbeddingAccounting.validate_dispatch(attempt, control, hold, now, config),
               {:ok, input} <-
                 EmbeddingProfile.input(context.revision.content, context.row.locale),
               {:ok, dispatched} <- change(attempt, %{dispatched_at: now}) do
            {:ok, {input, article_transport(id, dispatched, config.transport), dispatched}}
          end
        end)
      end
    end)
    |> case do
      {:ok, {input, transport, attempt}} -> {:ok, input, transport, attempt}
      error -> error
    end
  end

  defp article_transport(id, dispatched, {:fixture, wire} = transport) do
    {:fixture,
     fn request ->
       authorized =
         transaction(id, fn control, context ->
           with {:ok, attempt} <-
                  locked_attempt(context, dispatched.id, dispatched.dispatch_fence),
                true <-
                  attempt.state == :running and attempt.dispatched_at == dispatched.dispatched_at,
                :ok <- eligible(context, now()),
                {:ok, hold} <- reservation(attempt) do
             with_fixture_settings(fn config ->
               with true <- config.transport == transport,
                    :ok <-
                      EmbeddingAccounting.validate_dispatch(attempt, control, hold, now(), config),
                    do: {:ok, :authorized},
                    else: (_ -> {:error, :admission_denied})
             end)
           else
             _ -> {:error, :admission_denied}
           end
         end)

       case authorized do
         {:ok, :authorized} -> wire.(request)
         _ -> {request, %Req.TransportError{reason: :closed}}
       end
     end}
  end

  defp finish(id, attempt_id, fence, outcome) do
    transaction(id, fn control, context ->
      with {:ok, attempt} <- locked_attempt(context, attempt_id, fence),
           {:ok, reservation} <- reservation(attempt) do
        settle(control, context, attempt, reservation, now(), outcome)
      end
    end)
  end

  defp invoke(input, transport, attempt) do
    remaining = DateTime.diff(attempt.deadline_at, now(), :millisecond)

    if remaining > 0 do
      ref = make_ref()
      Process.put({__MODULE__, :transport}, ref)

      try do
        EmbeddingTransport.invoke(ref, input, min(remaining, @timeout_ms), transport)
      after
        Process.delete({__MODULE__, :transport})
      end
    else
      # The committed fence is consumed. Preserve the hold conservatively.
      :unknown
    end
  end

  defp eligible(%{row: row, revision: revision, article: article, collection: collection}, now) do
    cond do
      not Publication.pending?(revision) or
          not Publication.request_matches?(collection, article, revision) ->
        {:error, :stale_request}

      row.generation != revision.publication_generation or
        row.content_hash != revision.content_hash or row.profile_id != EmbeddingProfile.id() or
        row.profile_id != revision.publication_profile_id or
        row.deadline_at != revision.publication_deadline_at or
        revision.content_hash != revision.review_hash or
          revision.content_hash != Content.hash(revision.content) ->
        {:error, :stale_request}

      DateTime.compare(now, row.deadline_at) != :lt ->
        {:error, :deadline}

      true ->
        with {:ok, _} <- eligible_content(revision.content, now), do: :ok
    end
  end

  @doc false
  def eligible_content(content, now) do
    with false <- content["sensitive"] == true or content["response_mode"] == "escalate_only",
         {:ok, starts} <- utc_date(content["effective_from"]),
         true <- DateTime.compare(now, starts) != :lt,
         {:ok, expires} <- expires_at(content["expires_at"]),
         true <- is_nil(expires) or DateTime.compare(now, expires) == :lt do
      {:ok, expires}
    else
      _ -> {:error, :stale_request}
    end
  end

  defp expires_at(nil), do: {:ok, nil}
  defp expires_at(value), do: utc_date(value)

  defp utc_date(value) when is_binary(value) do
    with {:ok, date, 0} <- DateTime.from_iso8601(value), do: {:ok, date}
  end

  defp utc_date(_), do: {:error, :stale_request}

  defp earlier(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end

  defp queued(%{state: :queued, attempt_count: 0}), do: :ok
  defp queued(_), do: {:error, :already_claimed}

  defp allowed(%{embedding_inhibited: false}), do: :ok
  defp allowed(_), do: {:error, :embedding_inhibited}

  defp fresh_dispatch(%{state: :running, dispatched_at: nil}, %{state: :running}), do: :ok
  defp fresh_dispatch(%{state: :running, dispatched_at: nil}, _), do: {:error, :stale_request}
  defp fresh_dispatch(_, _), do: {:error, :already_claimed}

  defp locked_attempt(context, attempt_id, fence) do
    with {:ok, %{article_embedding_id: row_id} = attempt} <- get(InferenceRun, attempt_id, true),
         true <-
           row_id == context.row.id and attempt_id == context.row.last_attempt_id and
             attempt.profile_id == context.row.profile_id and
             attempt.ordinal == context.row.attempt_count,
         true <- is_nil(fence) or fence == attempt.dispatch_fence do
      {:ok, attempt}
    else
      false -> {:error, :stale_request}
      error -> error
    end
  end

  # An early run (clock skew) waits for the deadline instead of completing,
  # because the sweep only covers attempts and would never revisit this row.
  defp recover_queued(%{row: %{state: :queued} = row} = context) do
    case DateTime.diff(row.deadline_at, now(), :second) do
      wait when wait > 0 -> {:ok, {:snooze, wait}}
      _ -> fail_publication(context, :deadline)
    end
  end

  defp recover_queued(_), do: {:ok, :noop}

  defp recover_attempt(control, context, attempt_id) do
    now = now()

    with {:ok, attempt} <- locked_attempt(context, attempt_id, nil) do
      recover_embedding(control, context, attempt, now)
    end
  end

  defp recover_embedding(
         control,
         context,
         %{overflow_evidence: evidence, overflow_resolved_at: nil} = attempt,
         now
       )
       when not is_nil(evidence) do
    with {:ok, hold} <- reservation(attempt) do
      replay_embedding(control, context, attempt, hold, now)
    end
  end

  defp recover_embedding(control, context, %{state: :running} = attempt, now) do
    with true <- DateTime.compare(now, attempt.deadline_at) != :lt,
         {:ok, reservation} <- reservation(attempt) do
      if attempt.dispatched_at do
        hold(control, context, attempt, reservation, now, :deadline)
      else
        release(control, context, attempt, reservation, now, :deadline)
      end
    else
      false -> {:ok, :noop}
      error -> error
    end
  end

  defp recover_embedding(_, _, _, _), do: {:ok, :noop}

  defp replay_embedding(control, context, attempt, hold, now) do
    %{provider_request_id: request, input_tokens: tokens} =
      EmbeddingAccounting.recorded_usage(attempt)

    settle(
      control,
      context,
      attempt,
      hold,
      now,
      {:usage, request, tokens, {:error, :invalid_vector}}
    )
  end

  defp reject_before_dispatch(id, attempt_id, fence, reason) do
    transaction(id, fn control, context ->
      with {:ok, attempt} <- locked_attempt(context, attempt_id, fence),
           true <- attempt.state == :running and is_nil(attempt.dispatched_at),
           {:ok, reservation} <- reservation(attempt) do
        release(control, context, attempt, reservation, now(), failure_reason(reason))
      else
        false -> {:ok, :noop}
        error -> error
      end
    end)
  end

  defp fail_queued(id, reason) do
    transaction(id, fn _control, context ->
      if context.row.state == :queued, do: fail_publication(context, reason), else: {:ok, :noop}
    end)
  end

  defp failure_reason(reason) when reason in [:deadline, :stale_request], do: reason
  defp failure_reason(_), do: :admission_denied

  defp settle(
         control,
         context,
         %{state: :running, dispatched_at: time} = attempt,
         reservation,
         now,
         :unknown
       )
       when not is_nil(time),
       do: hold(control, context, attempt, reservation, now, :transport_unknown)

  defp settle(
         _,
         _,
         %{state: state, provider_request_id: id, input_tokens: tokens},
         _,
         _,
         {:usage, id, tokens, _}
       )
       when state in [:succeeded, :failed, :abandoned], do: {:ok, :noop}

  defp settle(
         control,
         context,
         %{state: state, dispatched_at: time} = attempt,
         reservation,
         now,
         {:usage, request_id, tokens, vector}
       )
       when (state in [:running, :unknown] or
               (state == :abandoned and is_nil(attempt.provider_request_id))) and not is_nil(time) do
    vector_status = if match?({:ok, _}, vector), do: :valid, else: :invalid_vector

    usage = %{provider_request_id: request_id, input_tokens: tokens}

    with true <- EmbeddingAccounting.overflow_matches?(attempt, usage),
         {:ok, accounting} <-
           account(
             attempt,
             :finish,
             &EmbeddingAccounting.finish(
               &1,
               control,
               attempt,
               reservation,
               now,
               {:usage, tokens, vector_status}
             )
           ) do
      case accounting do
        :amount_overflow when state == :abandoned ->
          change(attempt, %{overflow_evidence: attempt.overflow_evidence || usage})

        :amount_overflow ->
          with {:ok, _} <-
                 change(attempt, %{
                   state: :unknown,
                   finished_at: now,
                   reason_code: :amount_overflow,
                   overflow_evidence: attempt.overflow_evidence || usage
                 }) do
            fail_publication(context, :transport_unknown)
          end

        result ->
          changes =
            if attempt.overflow_evidence,
              do: Map.put(usage, :overflow_resolved_at, now),
              else: usage

          case state do
            :abandoned ->
              change(attempt, changes)

            _ ->
              reason = if result == :trusted_usage, do: nil, else: result

              with {:ok, _} <-
                     change(
                       attempt,
                       Map.merge(changes, %{
                         state: if(vector_status == :valid, do: :succeeded, else: :failed),
                         finished_at: now,
                         reason_code: reason
                       })
                     ) do
                apply_settlement(context, now, vector, state, result)
              end
          end
      end
    else
      false -> {:error, :conflicting_evidence}
      error -> error
    end
  end

  defp settle(
         _,
         _,
         %{provider_request_id: request, input_tokens: tokens},
         _,
         _,
         {:usage, request, tokens, _}
       )
       when not is_nil(request), do: {:ok, :noop}

  defp settle(_, _, %{state: state}, _, _, {:usage, _, _, _})
       when state in [:succeeded, :failed, :abandoned], do: {:error, :conflicting_evidence}

  defp settle(_, _, _, _, _, _), do: {:ok, :noop}

  defp apply_settlement(nil, _now, {:ok, vector}, :running, :trusted_usage),
    do: {:ok, {:query_vector, vector}}

  defp apply_settlement(nil, _now, _vector, _state, _accounting), do: {:ok, :noop}

  defp apply_settlement(context, now, vector, _state, _accounting),
    do: apply_result(context, now, vector)

  defp apply_result(%{row: %{state: :running} = row} = context, now, {:ok, vector}) do
    case eligible(context, now) do
      :ok ->
        with {:ok, _} <- change(row, %{state: :ready, vector: vector}),
             :ok <- finalise_ready_generation(context) do
          {:ok, :ready}
        end

      {:error, reason} ->
        fail_publication(context, failure_reason(reason))
    end
  end

  defp apply_result(context, _now, {:error, :invalid_vector}),
    do: fail_publication(context, :invalid_vector)

  defp apply_result(_, _, _), do: {:ok, :noop}

  defp finalise_ready_generation(%{generation: rows, revision: revision, row: row}) do
    if Enum.all?(rows, &(&1.id == row.id or &1.state == :ready)) do
      # A failed insert aborts the READY write and financial settlement.
      with {:ok, _} <- enqueue_finalisation(revision), do: :ok
    else
      :ok
    end
  end

  defp hold(control, context, attempt, reservation, now, reason) do
    with {:ok, _} <- change(attempt, %{state: :unknown, finished_at: now, reason_code: reason}),
         {:ok, _} <-
           account(
             attempt,
             :finish,
             &EmbeddingAccounting.finish(&1, control, attempt, reservation, now, {:hold, reason})
           ) do
      fail_publication(context, reason)
    end
  end

  defp release(control, context, attempt, reservation, now, reason) do
    with {:ok, _} <- change(attempt, %{state: :rejected, finished_at: now, reason_code: reason}),
         {:ok, _} <-
           account(
             attempt,
             :finish,
             &EmbeddingAccounting.finish(
               &1,
               control,
               attempt,
               reservation,
               now,
               {:release, reason}
             )
           ) do
      fail_publication(context, reason)
    end
  end

  defp fail_publication(nil, _reason), do: {:ok, :noop}

  defp fail_publication(%{revision: revision, row: row, generation: rows}, reason) do
    if Publication.pending?(revision) and revision.publication_generation == row.generation do
      attrs =
        if revision.status == :publishing,
          do: %{status: :publish_failed, publication_reason: reason},
          else: %{reindex_base_generation: nil, publication_reason: reason}

      with {:ok, failed} <- change(revision, attrs),
           {:ok, _} <- append_failure(revision, failed, reason),
           :ok <- fail_variants(rows, row.id, reason) do
        {:ok, :failed}
      end
    else
      {:ok, :noop}
    end
  end

  defp fail_variants(rows, failed_id, reason) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      state =
        if row.id == failed_id and row.state != :invalidated, do: :failed, else: :invalidated

      case change(row, %{state: state, vector: nil, error_code: reason}) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp append_failure(revision, failed, reason) do
    attrs = %{
      actor_kind: :embedding_worker,
      target_kind: :knowledge_revision,
      event: if(revision.status == :publishing, do: :fail_publication, else: :fail_reindex),
      article_revision_target_id: revision.id,
      correlation_id: Ash.UUIDv7.generate(),
      reason_code: reason,
      operational_before: %{status: revision.status, content_hash: revision.content_hash},
      operational_after: %{status: failed.status, content_hash: revision.content_hash}
    }

    storage(
      AuditEvent,
      :append_publication_failure,
      &Ash.create(AuditEvent, attrs, action: :append_publication_failure, actor: &1)
    )
  end

  defp transaction(id, work) do
    Repo.transact(fn ->
      with {:ok, control} <- Configuration.lock_control(),
           {:ok, context} <- lock_context(id) do
        work.(control, context)
      end
    end)
  rescue
    _ -> {:error, :indexing_storage}
  catch
    :exit, _ -> {:error, :indexing_storage}
  end

  defp lock_context(id) do
    with {:ok, candidate} <- get(ArticleEmbedding, id),
         {:ok, parent} <- get(ArticleRevision, candidate.revision_id),
         {:ok, article} <- get(Article, parent.article_id),
         {:ok, collection} <- get(KnowledgeCollection, article.collection_id, true),
         {:ok, article} <- get(Article, article.id, true),
         {:ok, revision} <- get(ArticleRevision, parent.id, true),
         true <- article.collection_id == collection.id and revision.article_id == article.id,
         {:ok, rows} <-
           read(
             ArticleEmbedding,
             :generation_rows,
             %{generation: candidate.generation, revision_id: revision.id},
             true
           ),
         %ArticleEmbedding{} = row <- Enum.find(rows, &(&1.id == id)) do
      {:ok,
       %{collection: collection, article: article, revision: revision, generation: rows, row: row}}
    else
      false -> {:error, :stale_request}
      nil -> {:error, :missing_row}
      error -> error
    end
  end

  defp reservation(attempt) do
    account(attempt, :lock_reservation, &EmbeddingAccounting.lock_reservation(&1, attempt))
  end

  defp account(attempt, action, fun) do
    ref = make_ref()
    key = {__MODULE__, :accounting}
    Process.put(key, {ref, attempt.id, action})

    try do
      fun.(ref)
    after
      Process.delete(key)
    end
  end

  defp get(resource, id, lock \\ false) do
    case query(resource, :storage_row, %{id: id}, lock, &Ash.read_one/1) do
      {:ok, nil} -> {:error, :missing_row}
      result -> result
    end
  end

  defp read(resource, action, args, lock \\ false),
    do: query(resource, action, args, lock, &Ash.read/1)

  defp query(resource, action, args, lock, fun) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      fun.(if lock, do: Ash.Query.lock(query, :for_update), else: query)
    end)
  end

  defp insert(resource, attrs),
    do:
      storage(resource, :insert_row, &Ash.create(resource, attrs, action: :insert_row, actor: &1))

  defp change(%resource{} = row, attrs),
    do: storage(resource, :change_row, &Ash.update(row, attrs, action: :change_row, actor: &1))

  defp storage(resource, action, fun) do
    ref = make_ref()
    key = {__MODULE__, :storage}
    Process.put(key, {ref, resource, action})

    try do
      fun.(%Storage{ref: ref, owner: __MODULE__})
    after
      Process.delete(key)
    end
  end

  defp result({:ok, {:snooze, _} = snooze}), do: snooze
  defp result({:ok, _}), do: :ok
  defp result({:error, reason}) when reason in [:already_claimed, :missing_row], do: :ok
  defp result({:error, _}), do: {:error, :indexing_storage}

  # Only TEST compiles the fixture gate. B1 has no configuration source that
  # can select the real adapter or accept a provider key, so every other build
  # refuses before any reservation or transport work.
  defp with_fixture_settings(work) do
    Enum.find_value(fixture_settings(), {:error, :disabled}, work)
  end

  if Mix.env() == :test do
    @fixture_price %{
      version: "embedding-fixture-v1",
      rate_nano_usd: 5,
      token_unit: 2,
      max_input_tokens: 32_768
    }

    defp fixture, do: Application.get_env(:voelgoed_ai, :embedding_fixture, %{})

    defp fixture_settings do
      case gate() do
        {:ok, settings} -> [settings]
        {:error, _} -> []
      end
    end

    defp gate do
      config = fixture()

      if config[:mode] == :fixture and Map.get(config, :enabled, true) do
        settings = %{
          price: @fixture_price,
          day_cap: 10_000_000,
          month_cap: 20_000_000,
          transport: {:fixture, Map.get(config, :wire, &EmbeddingTransport.fixture_wire/1)}
        }

        if Map.get(config, :price, @fixture_price) == @fixture_price and
             is_function(elem(settings.transport, 1), 1) do
          {:ok, Map.merge(settings, Map.take(config, [:day_cap, :month_cap]))}
        else
          {:error, :invalid_price}
        end
      else
        {:error, :disabled}
      end
    end

    defp enqueue_finalisation(revision),
      do:
        Map.get(fixture(), :enqueue_finalisation, &Publication.enqueue_finalisation/1).(revision)

    @doc false
    def fixture_budget, do: gate()
    def now, do: Map.get(fixture(), :clock, &DateTime.utc_now/0).()
    defp hook(stage, attempt), do: Map.get(fixture(), stage, fn _ -> :ok end).(attempt)
    defp consume(fence), do: Map.get(fixture(), :consume_dispatch, fn fun -> fun.() end).(fence)
  else
    defp fixture_settings, do: []
    defp enqueue_finalisation(revision), do: Publication.enqueue_finalisation(revision)
    def now, do: DateTime.utc_now()
    defp hook(_, _), do: :ok
    defp consume(fence), do: fence.()
  end
end
