defmodule VoelgoedAi.Knowledge.Publication do
  @moduledoc """
  Finalises durable publication and index requests. The control lock precedes
  collection, article, revision and embedding locks. Pointer, vectors, audit
  and expiry scheduling commit together.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Governance.AuditEvent
  alias VoelgoedAi.Intelligence.{Embedding, EmbeddingProfile}

  alias VoelgoedAi.Knowledge.{
    Article,
    ArticleEmbedding,
    ArticleRevision,
    Content,
    KnowledgeCollection,
    Storage
  }

  alias VoelgoedAi.Knowledge.Workers.{ExpirePublication, FinalizePublication}
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.Configuration

  @enforce_keys [:ref]
  defstruct [:ref]

  @terminal_index %{
    active_index_generation: nil,
    active_index_profile_id: nil,
    retained_index_generation: nil,
    reindex_base_generation: nil,
    publication_expires_at: nil,
    index_evaluation: nil
  }

  @impl Ash.Policy.Check
  def describe(_), do: "the publication worker holds the capability for this exact request"

  @impl Ash.Policy.SimpleCheck
  def match?(%__MODULE__{ref: ref}, %{subject: %Ash.ActionInput{} = input}, _)
      when is_reference(ref) do
    input.resource == ArticleRevision and
      Process.get({__MODULE__, :request}) == {ref, input.action.name, input.arguments}
  end

  def match?(_, _, _), do: false

  @doc false
  def terminal_index, do: @terminal_index

  @doc false
  def pending?(%{status: :publishing}), do: true
  def pending?(%{status: :published, reindex_base_generation: base}), do: not is_nil(base)
  def pending?(_), do: false

  @doc false
  def approved_content(revision, now) do
    with true <- revision.approved_by_id != nil and revision.approved_at != nil,
         true <- revision.content_hash == revision.review_hash,
         {:ok, content} <- Content.parse(revision.content),
         true <- content == revision.content and revision.content_hash == Content.hash(content) do
      Embedding.eligible_content(content, now)
    else
      _ -> {:error, :stale_request}
    end
  end

  @doc false
  def request_matches?(collection, article, revision) do
    collection.status == :active and collection.audience == :public and
      collection.security_epoch == revision.publication_collection_epoch and
      article.status == :active and
      article.current_revision_id == revision.expected_current_revision_id and
      revision.publication_profile_id == EmbeddingProfile.id() and
      (is_nil(revision.reindex_base_generation) or
         (article.current_revision_id == revision.id and
            revision.reindex_base_generation == revision.active_index_generation and
            revision.active_index_profile_id == revision.publication_profile_id))
  end

  @doc false
  def enqueue_finalisation(revision) do
    Oban.insert(
      FinalizePublication.new(%{
        revision_id: revision.id,
        generation: revision.publication_generation
      })
    )
  end

  @doc false
  def perform_job(FinalizePublication, %{"revision_id" => id, "generation" => generation} = args)
      when map_size(args) == 2 and is_integer(generation) and generation > 0 do
    cast_job(id, :publish_ready, :id, %{generation: generation})
  end

  def perform_job(FinalizePublication, %{"rollback_request_id" => id} = args)
      when map_size(args) == 1 do
    cast_job(id, :rollback_index, :request_id, %{})
  end

  def perform_job(ExpirePublication, %{"revision_id" => id} = args) when map_size(args) == 1 do
    cast_job(id, :expire, :id, %{})
  end

  def perform_job(_, _), do: {:discard, :invalid_job}

  defp cast_job(id, action, key, args) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> dispatch(action, Map.put(args, key, id))
      :error -> {:discard, :invalid_job}
    end
  end

  defp dispatch(action, args) do
    ref = make_ref()
    key = {__MODULE__, :request}
    Process.put(key, {ref, action, args})

    try do
      actor = %__MODULE__{ref: ref}

      case Ash.run_action(Ash.ActionInput.for_action(ArticleRevision, action, args, actor: actor)) do
        {:ok, :early} -> {:snooze, 60}
        {:ok, _} -> :ok
        {:error, _} -> {:error, :publication_storage}
      end
    after
      Process.delete(key)
    end
  end

  @impl Ash.Resource.Actions.Implementation
  def run(input, _, %{actor: actor}) do
    # Each action owns its commit. Internal callers cannot fold activation
    # into another transaction with a different lock order.
    cond do
      not match?(actor, %{subject: input}, []) ->
        {:error, "publication capability required"}

      Repo.in_transaction?() ->
        {:error, "publication requires its own transaction"}

      true ->
        transaction(fn -> execute(input.action.name, input.arguments) end)
    end
  end

  @doc "Recover pending requests and due expiries in independently bounded batches."
  def sweep do
    now = Embedding.now()

    with {:ok, {publications, reindexes, expiries}} <-
           transaction(fn ->
             with {:ok, publications} <-
                    read(ArticleRevision, :pending_finalisation, %{now: now, status: :publishing}),
                  {:ok, reindexes} <-
                    read(ArticleRevision, :pending_finalisation, %{now: now, status: :published}),
                  {:ok, expiries} <- read(ArticleRevision, :due_expiries, %{now: now}) do
               {:ok, {publications, reindexes, expiries}}
             end
           end) do
      finalise =
        for row <- publications ++ reindexes,
            do: dispatch(:publish_ready, %{id: row.id, generation: row.publication_generation})

      expiry = for row <- expiries, do: dispatch(:expire, %{id: row.id})
      Enum.find(finalise ++ expiry, :ok, &match?({:error, _}, &1))
    end
  end

  defp execute(:publish_ready, %{id: id, generation: generation}) do
    with_context(id, fn collection, article, revision, previous ->
      if pending?(revision) and revision.publication_generation == generation do
        finalise(collection, article, revision, previous)
      else
        {:ok, :noop}
      end
    end)
  end

  defp execute(:expire, %{id: id}) do
    with_context(id, fn _collection, article, revision, _previous ->
      case revision do
        %{status: :published, publication_expires_at: %DateTime{} = expires}
        when article.current_revision_id == revision.id ->
          if DateTime.compare(Embedding.now(), expires) == :lt do
            {:ok, :early}
          else
            with {:ok, rows} <- lock_embeddings([revision.id]),
                 :ok <- invalidate(rows),
                 {:ok, _} <-
                   transition(
                     revision,
                     Map.put(@terminal_index, :status, :expired),
                     :expire,
                     :deadline
                   ),
                 {:ok, _} <- change(article, %{current_revision_id: nil}) do
              {:ok, :expired}
            end
          end

        _ ->
          {:ok, :noop}
      end
    end)
  end

  defp execute(:rollback_index, %{request_id: id}), do: rollback(id)

  defp finalise(collection, article, revision, previous) do
    with {:ok, rows} <-
           lock_embeddings(Enum.reject([revision.id, previous && previous.id], &is_nil/1)) do
      current =
        Enum.filter(
          rows,
          &(&1.revision_id == revision.id and &1.generation == revision.publication_generation)
        )

      now = Embedding.now()

      case readiness(collection, article, revision, current, now) do
        {:ready, expires} when revision.status == :publishing ->
          activate(article, revision, previous, rows, now, expires)

        {:ready, _} ->
          switch_index(
            revision,
            revision.publication_generation,
            rows,
            :switch_index,
            :index_ready
          )

        :pending ->
          {:ok, :pending}

        {:stale, reason} ->
          fail(revision, current, reason)
      end
    end
  end

  defp readiness(collection, article, revision, rows, now) do
    cond do
      DateTime.compare(now, revision.publication_deadline_at) != :lt ->
        {:stale, :deadline}

      not request_matches?(collection, article, revision) ->
        {:stale, :stale_request}

      not exact_index?(revision, rows, revision.publication_profile_id) or
          Enum.any?(rows, &(&1.deadline_at != revision.publication_deadline_at)) ->
        {:stale, :stale_request}

      true ->
        case approved_content(revision, now) do
          {:ok, expires} ->
            if ready_vectors?(rows),
              do: {:ready, expires},
              else: :pending

          {:error, _} ->
            {:stale, :stale_request}
        end
    end
  end

  defp exact_index?(revision, rows, profile_id) do
    locales = Enum.map(revision.content["localized_content"] || [], & &1["locale"])

    locales != [] and Enum.sort(locales) == Enum.sort(Enum.map(rows, & &1.locale)) and
      Enum.all?(
        rows,
        &(&1.content_hash == revision.content_hash and &1.profile_id == profile_id and
            &1.state in [:queued, :running, :ready])
      )
  end

  defp complete_generation?(revision, rows, generation) do
    variants = Enum.filter(rows, &(&1.generation == generation))

    exact_index?(revision, variants, revision.active_index_profile_id) and
      ready_vectors?(variants)
  end

  defp ready_vectors?(rows), do: Enum.all?(rows, &(&1.state == :ready and not is_nil(&1.vector)))

  defp fail(revision, rows, reason) do
    attrs =
      if revision.status == :publishing,
        do: %{status: :publish_failed, publication_reason: reason},
        else: %{reindex_base_generation: nil, publication_reason: reason}

    with :ok <- invalidate(rows),
         {:ok, _} <- change(revision, attrs) do
      # Return a conflict as data so the generation fence commits.
      {:ok, :stale}
    end
  end

  defp activate(article, revision, previous, rows, now, expires) do
    attrs = %{
      status: :published,
      published_at: now,
      publication_expires_at: expires,
      active_index_generation: revision.publication_generation,
      active_index_profile_id: revision.publication_profile_id,
      index_epoch: revision.index_epoch + 1
    }

    with :ok <- supersede(previous, rows),
         {:ok, _} <- transition(revision, attrs, :activate, :index_ready),
         {:ok, _} <- change(article, %{current_revision_id: revision.id}),
         :ok <- enqueue_expiry(revision.id, expires) do
      {:ok, :activated}
    end
  end

  defp supersede(nil, _), do: :ok

  defp supersede(%{status: :published} = previous, rows) do
    with :ok <- invalidate(Enum.filter(rows, &(&1.revision_id == previous.id))),
         {:ok, _} <-
           transition(
             previous,
             Map.put(@terminal_index, :status, :superseded),
             :supersede,
             :replaced
           ),
         do: :ok
  end

  defp supersede(_, _), do: {:error, :inconsistent_pointer}

  defp enqueue_expiry(_, nil), do: :ok

  defp enqueue_expiry(id, expires) do
    with {:ok, _} <- Oban.insert(ExpirePublication.new(%{revision_id: id}, scheduled_at: expires)),
         do: :ok
  end

  defp switch_index(revision, generation, rows, event, reason) do
    active = revision.active_index_generation

    retained =
      if complete_generation?(revision, rows, active), do: active, else: nil

    obsolete = Enum.reject(rows, &(&1.generation in [generation, retained]))

    attrs = %{
      active_index_generation: generation,
      retained_index_generation: retained,
      reindex_base_generation: nil,
      index_epoch: revision.index_epoch + 1,
      publication_reason: nil,
      index_evaluation: nil
    }

    with :ok <- invalidate(obsolete),
         {:ok, _} <- transition(revision, attrs, event, reason) do
      {:ok, :switched}
    end
  end

  @doc false
  def rollback_available

  if Mix.env() == :test do
    def rollback_available, do: :ok

    @doc false
    def record_fixture_evaluation(id, generation) do
      transaction(fn ->
        with_context(id, fn _collection, _article, revision, _previous ->
          with true <-
                 revision.status == :published and
                   revision.retained_index_generation == generation,
               {:ok, rows} <- lock_embeddings([id]),
               true <- complete_generation?(revision, rows, generation) do
            change(revision, %{
              index_evaluation: %{
                generation: generation,
                content_hash: revision.content_hash,
                profile_id: revision.active_index_profile_id,
                evaluator: "synthetic",
                evaluated_at: Embedding.now()
              }
            })
          else
            false -> {:error, :ineligible_evaluation}
            error -> error
          end
        end)
      end)
    end

    defp rollback(id) do
      with {:ok, %AuditEvent{} = request} <- one(AuditEvent, :rollback_request, %{id: id}) do
        with_context(request.article_revision_target_id, fn collection,
                                                            article,
                                                            revision,
                                                            _previous ->
          now = Embedding.now()
          before = request.operational_before
          after_request = request.operational_after
          generation = field(after_request, :index_generation)

          with true <-
                 revision.status == :published and article.status == :active and
                   article.current_revision_id == revision.id and collection.status == :active and
                   collection.audience == :public and not pending?(revision),
               deadline = field(after_request, :deadline_us),
               true <- is_integer(deadline) and DateTime.to_unix(now, :microsecond) < deadline,
               true <-
                 collection.security_epoch == field(after_request, :collection_epoch) and
                   revision.content_hash == field(after_request, :content_hash) and
                   revision.active_index_profile_id == EmbeddingProfile.id() and
                   revision.active_index_profile_id == field(after_request, :content_profile_id) and
                   revision.index_epoch == field(before, :index_epoch) and
                   revision.active_index_generation == field(before, :index_generation) and
                   revision.retained_index_generation == generation,
               {:ok, _} <- approved_content(revision, now),
               true <- evaluated?(revision, generation, now),
               {:ok, rows} <- lock_embeddings([revision.id]),
               true <- complete_generation?(revision, rows, generation) do
            switch_index(revision, generation, rows, :rollback_index, :evaluated)
          else
            false -> {:ok, :stale}
            {:error, :stale_request} -> {:ok, :stale}
            error -> error
          end
        end)
      else
        {:ok, nil} -> {:ok, :noop}
        error -> error
      end
    end

    defp evaluated?(%{index_evaluation: %{} = receipt} = revision, generation, now) do
      field(receipt, :generation) == generation and
        field(receipt, :content_hash) == revision.content_hash and
        field(receipt, :profile_id) == revision.active_index_profile_id and
        field(receipt, :evaluator) == "synthetic" and
        evaluation_due?(field(receipt, :evaluated_at), now)
    end

    defp evaluated?(_, _, _), do: false

    defp evaluation_due?(%DateTime{} = at, now), do: DateTime.compare(at, now) != :gt

    defp evaluation_due?(at, now) when is_binary(at) do
      with {:ok, at, 0} <- DateTime.from_iso8601(at), do: evaluation_due?(at, now) == true
    end

    defp evaluation_due?(_, _), do: false

    defp field(map, name), do: Map.get(map, name, Map.get(map, Atom.to_string(name)))
  else
    def rollback_available, do: {:error, :rollback_disabled}
    defp rollback(_), do: {:ok, :stale}
  end

  defp transaction(fun) do
    Repo.transact(fun)
  rescue
    _ -> {:error, "publication storage failed"}
  catch
    :exit, _ -> {:error, "publication storage failed"}
  end

  defp with_context(id, fun) do
    with {:ok, _} <- Configuration.lock_control(),
         {:ok, %ArticleRevision{} = candidate} <- get(ArticleRevision, id),
         {:ok, %Article{} = route} <- get(Article, candidate.article_id),
         {:ok, %KnowledgeCollection{} = collection} <-
           get(KnowledgeCollection, route.collection_id, :for_update),
         {:ok, %Article{} = article} <- get(Article, route.id, :for_update),
         true <- article.collection_id == collection.id,
         {:ok, revisions} <- lock_revisions([id, article.current_revision_id]),
         %ArticleRevision{article_id: article_id} = revision <- revisions[id],
         true <- article_id == article.id do
      previous = if id != article.current_revision_id, do: revisions[article.current_revision_id]
      fun.(collection, article, revision, previous)
    else
      {:ok, nil} -> {:ok, :noop}
      false -> {:ok, :stale}
      nil -> {:ok, :stale}
      error -> error
    end
  end

  defp lock_revisions(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn id, {:ok, rows} ->
      case get(ArticleRevision, id, :for_update) do
        {:ok, %ArticleRevision{} = row} -> {:cont, {:ok, Map.put(rows, id, row)}}
        {:ok, nil} -> {:halt, {:error, :inconsistent_pointer}}
        error -> {:halt, error}
      end
    end)
  end

  defp lock_embeddings(ids),
    do: read(ArticleEmbedding, :revision_rows, %{revision_ids: ids}, :for_update)

  defp invalidate(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case row.state do
        :invalidated ->
          {:cont, :ok}

        _ ->
          case change(row, %{state: :invalidated, vector: nil, error_code: :stale_request}) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp transition(before, attrs, event, reason) do
    with {:ok, row} <- change(before, attrs),
         {:ok, _} <- append_transition(before, row, event, reason),
         do: {:ok, row}
  end

  defp append_transition(before, row, event, reason) do
    attrs = %{
      article_revision_target_id: row.id,
      actor_kind: :publisher,
      target_kind: :knowledge_revision,
      event: event,
      reason_code: reason,
      correlation_id: Ash.UUIDv7.generate(),
      operational_before: audit_state(before),
      operational_after: audit_state(row)
    }

    storage(
      AuditEvent,
      :append_publication_transition,
      &Ash.create(AuditEvent, attrs, action: :append_publication_transition, actor: &1)
    )
  end

  defp audit_state(row) do
    %{status: row.status, content_hash: row.content_hash}
    |> Map.merge(
      if row.active_index_generation,
        do: %{
          index_generation: row.active_index_generation,
          index_epoch: row.index_epoch,
          content_profile_id: row.active_index_profile_id
        },
        else: %{}
    )
  end

  defp get(resource, id, lock \\ nil), do: one(resource, :storage_row, %{id: id}, lock)

  defp one(resource, action, args, lock \\ nil),
    do: query(resource, action, args, lock, &Ash.read_one/1)

  defp read(resource, action, args, lock \\ nil),
    do: query(resource, action, args, lock, &Ash.read/1)

  defp query(resource, action, args, lock, reader) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      reader.(if lock, do: Ash.Query.lock(query, lock), else: query)
    end)
  end

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
end
