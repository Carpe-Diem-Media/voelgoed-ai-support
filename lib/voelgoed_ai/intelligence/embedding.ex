defmodule VoelgoedAi.Intelligence.Embedding do
  @moduledoc """
  Owns the article embedding claim, dispatch fence and result application.
  Each transaction takes control before collection, article, revision, all
  generation rows by ID, attempt and reservation. Accounting takes windows
  last. Only the committed dispatch winner holds permission to invoke.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Accounts.StaffAccess.Session
  alias VoelgoedAi.Governance.{AuditEvent, EmbeddingAccounting, UsageReservation}
  alias VoelgoedAi.Intelligence.{EmbeddingProfile, EmbeddingTransport, InferenceRun}

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
  alias VoelgoedAi.Support.Configuration

  @indexing_seconds 60
  @timeout_ms 5_000

  @impl Ash.Policy.Check
  def describe(_opts), do: "a staff session presented for scoped financial closure"

  @impl Ash.Policy.SimpleCheck
  def match?(%Session{}, %{subject: %Ash.ActionInput{}}, _opts), do: true
  def match?(_, _, _), do: false

  @impl Ash.Resource.Actions.Implementation
  def run(%{arguments: %{id: id, reason: :conservative_closure}}, _opts, %{actor: session}) do
    with {:ok, _} <- gate() do
      StaffAccess.with_current(session, :admin, fn staff ->
        with true <- closure_approved?(staff.id),
             {:ok, control} <- Configuration.lock_control(),
             {:ok, candidate} <- get(InferenceRun, id),
             {:ok, context} <- lock_context(candidate.article_embedding_id),
             {:ok, attempt} <- locked_attempt(context, id, nil),
             {:ok, reservation} <- reservation(attempt) do
          close_unknown(control, attempt, reservation, staff.id)
        else
          false -> {:error, :denied}
          error -> error
        end
      end)
    end
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "embedding closure denied"}
    end
  end

  defp close_unknown(control, %{state: :unknown} = attempt, reservation, staff_id) do
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

  defp close_unknown(_control, %{state: :abandoned} = attempt, _reservation, _staff_id),
    do: {:ok, %{id: attempt.id, state: :abandoned}}

  defp close_unknown(_, _, _, _), do: {:error, :invalid_settlement}

  @doc false
  def publication_deadline(content) do
    now = now()

    with {:ok, _} <- gate(),
         {:ok, expires} <- eligible_content(content, now) do
      deadline = DateTime.add(now, @indexing_seconds, :second)
      {:ok, if(expires, do: earlier(deadline, expires), else: deadline)}
    end
  end

  @doc "Process one durable article embedding row without replaying a reserved attempt."
  def index(id) do
    with false <- Repo.in_transaction?(),
         {:ok, %{id: attempt_id, dispatch_fence: fence} = attempt} <- claim(id) do
      hook(:after_claim, attempt)

      with {:ok, input, transport} <- consume(fn -> dispatch(id, attempt_id, fence) end) do
        hook(:after_dispatch, attempt)
        outcome = invoke(input, transport, attempt)
        hook(:before_settlement, attempt)
        result(finish(id, attempt_id, fence, outcome))
      else
        {:error, reason}
        when reason in [:deadline, :stale_request, :embedding_inhibited, :disabled] ->
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
           Repo.transact(fn -> read(InferenceRun, :recovery_candidates, %{now: now()}) end) do
      Enum.reduce(attempts, :ok, fn attempt, result ->
        case recover(attempt.article_embedding_id) do
          :ok -> result
          error -> error
        end
      end)
    else
      _ -> {:error, :indexing_storage}
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

      with :ok <- queued(row),
           {:ok, config} <- gate(),
           :ok <- eligible(context, now),
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

  defp dispatch(id, attempt_id, fence) do
    transaction(id, fn control, context ->
      now = now()

      with {:ok, attempt} <- locked_attempt(context, attempt_id, fence),
           :ok <- fresh_dispatch(attempt, context.row),
           {:ok, config} <- gate(),
           :ok <- eligible(context, now),
           :ok <- allowed(control),
           {:ok, %UsageReservation{state: :reserved}} <- reservation(attempt),
           {:ok, input} <- EmbeddingProfile.input(context.revision.content, context.row.locale),
           {:ok, _} <- change(attempt, %{dispatched_at: now}) do
        {:ok, {input, config.transport}}
      else
        {:ok, %UsageReservation{}} -> {:error, :stale_request}
        error -> error
      end
    end)
    |> case do
      {:ok, {input, transport}} -> {:ok, input, transport}
      error -> error
    end
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
         {:ok, starts, 0} <- DateTime.from_iso8601(content["effective_from"]),
         true <- DateTime.compare(now, starts) != :lt,
         {:ok, expires} <- expires_at(content["expires_at"]),
         true <- is_nil(expires) or DateTime.compare(now, expires) == :lt do
      {:ok, expires}
    else
      _ -> {:error, :stale_request}
    end
  end

  defp expires_at(nil), do: {:ok, nil}

  defp expires_at(value) do
    with {:ok, expires, 0} <- DateTime.from_iso8601(value), do: {:ok, expires}
  end

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

    with {:ok, attempt} <- locked_attempt(context, attempt_id, nil),
         true <- attempt.state == :running and DateTime.compare(now, attempt.deadline_at) != :lt,
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

    with {:ok, accounting} <-
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
          {:ok, :noop}

        :amount_overflow ->
          with {:ok, _} <-
                 change(attempt, %{
                   state: :unknown,
                   finished_at: now,
                   reason_code: :amount_overflow
                 }) do
            fail_publication(context, :transport_unknown)
          end

        result ->
          changes = %{provider_request_id: request_id, input_tokens: tokens}

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
                apply_result(context, now, vector)
              end
          end
      end
    end
  end

  defp settle(_, _, %{state: state}, _, _, {:usage, _, _, _})
       when state in [:succeeded, :failed, :abandoned], do: {:error, :conflicting_evidence}

  defp settle(_, _, _, _, _, _), do: {:ok, :noop}

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
      with {:ok, _} <- Publication.enqueue_finalisation(revision), do: :ok
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
  if Mix.env() == :test do
    @fixture_price %{
      version: "embedding-fixture-v1",
      rate_nano_usd: 5,
      token_unit: 2,
      max_input_tokens: 32_768
    }

    defp fixture, do: Application.get_env(:voelgoed_ai, :embedding_fixture, %{})

    defp gate do
      config = fixture()

      if config[:mode] == :fixture and Map.get(config, :enabled, true) do
        settings = %{
          price: @fixture_price,
          day_cap: 10_000_000,
          month_cap: 20_000_000,
          transport: {:fixture, Map.get(config, :wire, &EmbeddingTransport.fixture_wire/1)}
        }

        {:ok, Map.merge(settings, Map.take(config, [:price, :day_cap, :month_cap]))}
      else
        {:error, :disabled}
      end
    end

    defp closure_approved?(id), do: fixture()[:closure_approved_by] == id
    def now, do: Map.get(fixture(), :clock, &DateTime.utc_now/0).()
    defp hook(stage, attempt), do: Map.get(fixture(), stage, fn _ -> :ok end).(attempt)
    defp consume(fence), do: Map.get(fixture(), :consume_dispatch, fn fun -> fun.() end).(fence)
  else
    defp gate, do: {:error, :disabled}
    defp closure_approved?(_id), do: false
    def now, do: DateTime.utc_now()
    defp hook(_, _), do: :ok
    defp consume(fence), do: fence.()
  end
end
