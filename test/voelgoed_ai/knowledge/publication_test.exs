defmodule VoelgoedAi.Knowledge.PublicationTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.SupportFixtures, only: [invoke: 4, blocked_task: 1]
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Intelligence.{Embedding, EmbeddingTransport}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, KnowledgeCollection, Publication}
  alias VoelgoedAi.Knowledge.Workers.{ExpirePublication, FinalizePublication, RecoverIndexing}

  @moduletag :requires_pgvector
  @moduletag :embedding_index
  setup :setup_knowledge

  test "the last READY locale queues one atomic publication and replay has no effect", ctx do
    {_, revision} = approved(ctx)
    [af, en] = request_index(ctx, revision)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :publish_ready,
               %{id: revision.id, generation: 1},
               ctx.reviewer
             )

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :publish_ready,
               %{id: revision.id, generation: 1},
               %Publication{ref: make_ref()}
             )

    assert {:discard, :invalid_job} =
             Publication.perform_job(
               RecoverIndexing,
               %{"revision_id" => revision.id, "generation" => 1}
             )

    assert :ok = Embedding.index(af)
    assert publication_jobs(revision.id) == []
    assert :ok = Embedding.index(en)
    assert [[_, args]] = publication_jobs(revision.id)

    assert :ok = FinalizePublication.perform(%Oban.Job{args: args})
    assert :ok = FinalizePublication.perform(%Oban.Job{args: args})

    assert [["published", 1, revision_id]] = publication_state(revision.id)
    assert revision_id == revision.id
  end

  test "future starts remain approved and an old expiry cannot clear a replacement", ctx do
    {_, original} = approved(ctx)
    now = DateTime.utc_now()
    future = DateTime.add(now, 30, :second)
    expires = DateTime.add(now, 90, :second)

    planned =
      payload()
      |> Map.put("effective_from", DateTime.to_iso8601(future))
      |> Map.put("expires_at", DateTime.to_iso8601(expires))

    revision = approve_draft(ctx, original.article_id, planned)
    fixture(%{clock: fn -> now end})
    args = Map.put(snapshot(revision), :expected_current_revision_id, nil)
    assert {:error, _} = invoke(ArticleRevision, :request_publish, args, ctx.reviewer)
    assert [["approved", nil, nil]] = publication_state(revision.id)
    assert generation_ids(revision.id, 1) == []

    fixture(%{clock: fn -> future end})
    ready(request_index(ctx, revision))
    assert :ok = finalise(revision.id, 1)

    assert {:ok, _} =
             invoke(
               ArticleRevision,
               :request_publish,
               Map.put(snapshot(original), :expected_current_revision_id, revision.id),
               ctx.reviewer
             )

    ready(generation_ids(original.id, 1))
    assert :ok = finalise(original.id, 1)

    fixture(%{clock: fn -> expires end})
    assert :ok = ExpirePublication.perform(%Oban.Job{args: %{"revision_id" => revision.id}})
    assert [["published", 1, pointer]] = publication_state(original.id)
    assert pointer == original.id
  end

  test "same-pointer requests race under the control lock and retry with a fresh generation",
       ctx do
    {_, first} = approved(ctx)
    second = approve_draft(ctx, first.article_id)
    ready(request_index(ctx, first))
    ready(request_index(ctx, second))
    assert [["publishing", nil, nil]] = publication_state(first.id)
    assert [["publishing", nil, nil]] = publication_state(second.id)

    # Hold the same row the finaliser must acquire. Both requests are already
    # committed and each finaliser runs on its own database connection.
    assert {:ok, {one, two}} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SELECT id FROM automation_controls FOR UPDATE")
               one = blocked_task(fn -> finalise(first.id, 1) end)
               two = queued_finaliser(second.id)
               {:ok, {one, two}}
             end)

    assert [:ok, :ok] = Task.await_many([one, two])

    [winner, loser] =
      Enum.sort_by([first, second], fn row -> hd(hd(publication_state(row.id))) end, :desc)

    assert [["published", 1, winner_id]] = publication_state(winner.id)
    assert winner_id == winner.id
    assert [["publish_failed", nil, ^winner_id]] = publication_state(loser.id)

    args = Map.put(snapshot(loser), :expected_current_revision_id, winner.id)

    assert {:ok, %{publication_generation: 2}} =
             invoke(ArticleRevision, :retry_publication, args, ctx.reviewer)

    assert :ok = finalise(loser.id, 1)
    assert [["publishing", nil, ^winner_id]] = publication_state(loser.id)
    ready(generation_ids(loser.id, 2))
    assert :ok = finalise(loser.id, 2)
    assert [["superseded", nil, loser_id]] = publication_state(winner.id)
    assert loser_id == loser.id
    for id <- generation_ids(winner.id, 1), do: assert(vector_rows(id) == [["invalidated", nil]])
  end

  test "audit and expiry enqueue failures roll back activation and supersession", ctx do
    {_, first} = approved(ctx)
    ready(request_index(ctx, first))
    assert :ok = finalise(first.id, 1)

    expires = DateTime.add(DateTime.utc_now(), 120, :second)

    second =
      approve_draft(
        ctx,
        first.article_id,
        Map.put(payload(), "expires_at", DateTime.to_iso8601(expires))
      )

    args = Map.put(snapshot(second), :expected_current_revision_id, first.id)
    assert {:ok, _} = invoke(ArticleRevision, :request_publish, args, ctx.reviewer)
    ready(generation_ids(second.id, 1))

    reject_insert(
      "audit_events",
      "NEW.event = 'activate' AND NEW.article_revision_target_id = '#{second.id}'",
      fn ->
        assert {:error, :publication_storage} = finalise(second.id, 1)
      end
    )

    reject_insert(
      "oban_jobs",
      "NEW.worker LIKE '%ExpirePublication' AND NEW.args->>'revision_id' = '#{second.id}'",
      fn ->
        assert {:error, :publication_storage} = finalise(second.id, 1)
      end
    )

    assert [["published", 1, id]] = publication_state(first.id)
    assert [["publishing", nil, ^id]] = publication_state(second.id)

    assert %{rows: [[0]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM audit_events WHERE article_revision_target_id = $1 AND event = 'supersede'",
               [db_id(first.id)]
             )

    assert :ok = finalise(second.id, 1)
    assert [["superseded", nil, _]] = publication_state(first.id)
    assert [["published", 1, _]] = publication_state(second.id)
  end

  test "a failed T08 enqueue leaves the final locale running and the dispatch hold intact", ctx do
    {_, revision} = approved(ctx)
    [af, en] = request_index(ctx, revision)
    ready([af])

    reject_insert(
      "oban_jobs",
      "NEW.worker LIKE '%FinalizePublication' AND NEW.args->>'revision_id' = '#{revision.id}'",
      fn ->
        assert {:error, :indexing_storage} = Embedding.index(en)
      end
    )

    assert vector_rows(af) == [["ready", 1536]]
    assert vector_rows(en) == [["running", nil]]
    assert [["running", true, "reserved", _, nil]] = reservation_rows(en)
    assert publication_jobs(revision.id) == []
    assert :ok = Embedding.index(en)
    assert vector_rows(en) == [["running", nil]]
  end

  test "recovery activates stranded B1 work and fences a disabled and re-enabled epoch", ctx do
    {collection, revision} = approved(ctx)
    ready(request_index(ctx, revision))
    delete_finalisation(revision.id)
    assert :ok = RecoverIndexing.perform(%Oban.Job{args: %{}})
    assert [["published", 1, _]] = publication_state(revision.id)

    next = approve_draft(ctx, revision.article_id)
    args = Map.put(snapshot(next), :expected_current_revision_id, revision.id)
    assert {:ok, _} = invoke(ArticleRevision, :request_publish, args, ctx.reviewer)
    ready(generation_ids(next.id, 1))

    assert {:ok, {task, _}} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        invoke(KnowledgeCollection, :disable, %{id: collection.id}, ctx.admin)

               task = blocked_task(fn -> finalise(next.id, 1) end)
               assert {:ok, _} = enable_collection(ctx, collection)
               {:ok, {task, nil}}
             end)

    assert :ok = Task.await(task)
    assert [["publish_failed", nil, current]] = publication_state(next.id)
    assert current == revision.id
  end

  test "missing and extra locales and stale READY metadata cannot activate", ctx do
    {_, revision} = approved(ctx)
    [af, en] = request_index(ctx, revision)
    SQL.query!(Repo, "DELETE FROM article_embeddings WHERE id = $1", [db_id(en)])
    assert :ok = finalise(revision.id, 1)
    assert [["publish_failed", nil, nil]] = publication_state(revision.id)
    assert vector_rows(af) == [["invalidated", nil]]

    [af, en] = request_index(ctx, revision, :retry_publication)
    ready([af, en])

    SQL.query!(Repo, "UPDATE article_embeddings SET profile_id = 'stale-profile' WHERE id = $1", [
      db_id(af)
    ])

    assert :ok = finalise(revision.id, 2)
    assert [["publish_failed", nil, nil]] = publication_state(revision.id)

    [af, en] = request_index(ctx, revision, :retry_publication)
    ready([af, en])

    SQL.query!(
      Repo,
      "UPDATE article_embeddings SET content_hash = repeat('0',64) WHERE id = $1",
      [db_id(en)]
    )

    assert :ok = finalise(revision.id, 3)
    assert [["publish_failed", nil, nil]] = publication_state(revision.id)

    single =
      Map.update!(
        payload(),
        "localized_content",
        &Enum.filter(&1, fn row -> row["locale"] == "en-ZA" end)
      )

    next = approve_draft(ctx, revision.article_id, single)

    assert {:ok, _} =
             invoke(
               ArticleRevision,
               :request_publish,
               Map.put(snapshot(next), :expected_current_revision_id, nil),
               ctx.reviewer
             )

    [en] = generation_ids(next.id, 1)
    ready([en])

    SQL.query!(
      Repo,
      """
      INSERT INTO article_embeddings (id, revision_id, locale, profile_id, content_hash, generation,
        state, attempt_count, deadline_at, inserted_at, updated_at)
      SELECT $1, revision_id, 'af-ZA', profile_id, content_hash, generation, 'queued', 0, deadline_at, now(), now()
      FROM article_embeddings WHERE id = $2
      """,
      [db_id(Ash.UUIDv7.generate()), db_id(en)]
    )

    assert :ok = finalise(next.id, 1)
    assert [["publish_failed", nil, nil]] = publication_state(next.id)
  end

  test "an expired READY request fails and expiry fences a pending reindex while due", ctx do
    {_, stranded} = approved(ctx)
    now = DateTime.utc_now()
    fixture(%{clock: fn -> now end})
    ready(request_index(ctx, stranded))
    fixture(%{clock: fn -> DateTime.add(now, 60, :second) end})
    assert :ok = RecoverIndexing.perform(%Oban.Job{args: %{}})
    assert [["publish_failed", nil, nil]] = publication_state(stranded.id)

    expires = DateTime.add(now, 90, :second)

    current =
      approve_draft(
        ctx,
        stranded.article_id,
        Map.put(payload(), "expires_at", DateTime.to_iso8601(expires))
      )

    fixture(%{clock: fn -> now end})
    ready(request_index(ctx, current))
    assert :ok = finalise(current.id, 1)

    expiry = %Oban.Job{args: %{"revision_id" => current.id}}
    assert {:snooze, _} = ExpirePublication.perform(expiry)
    assert {:ok, _} = reindex(ctx, current, 1, 1)
    ready(generation_ids(current.id, 2))

    fixture(%{clock: fn -> expires end})

    assert {:ok, rival} =
             Repo.transact(fn ->
               assert {:ok, _} = VoelgoedAi.Support.Configuration.lock_control()
               rival = blocked_task(fn -> finalise(current.id, 2) end)
               {:ok, rival}
             end)

    assert :ok = Task.await(rival)
    assert :ok = RecoverIndexing.perform(%Oban.Job{args: %{}})
    assert [["expired", nil, nil]] = publication_state(current.id)
    assert :ok = ExpirePublication.perform(expiry)

    for generation <- [1, 2],
        id <- generation_ids(current.id, generation),
        do: assert(vector_rows(id) == [["invalidated", nil]])
  end

  test "reindex failure preserves the active index and evaluated rollback increments its epoch",
       ctx do
    {_, revision} = approved(ctx)
    ready(request_index(ctx, revision))
    assert :ok = finalise(revision.id, 1)

    assert {:ok, %{publication_generation: 2}} = reindex(ctx, revision, 1, 1)
    assert [["published", 1, _]] = publication_state(revision.id)
    fixture(%{wire: fn request -> invalid_response(request) end})
    ready(Enum.take(generation_ids(revision.id, 2), 1))
    assert [["published", 1, _]] = publication_state(revision.id)
    assert {:ok, %{publication_generation: 3}} = reindex(ctx, revision, 1, 1)

    fixture(%{})
    ready(generation_ids(revision.id, 3))
    delete_finalisation(revision.id)
    assert :ok = RecoverIndexing.perform(%Oban.Job{args: %{}})
    assert [["published", 3, _]] = publication_state(revision.id)

    request = rollback_request(ctx, revision, 3, 2, 1)
    assert :ok = perform_rollback(request)
    assert [["published", 3, _]] = publication_state(revision.id)
    assert {:ok, _} = Publication.record_fixture_evaluation(revision.id, 1)
    assert :ok = perform_rollback(request)
    assert [["published", 1, _]] = publication_state(revision.id)
    assert {:error, _} = reindex(ctx, revision, 1, 1)

    assert {:ok, _} = Publication.record_fixture_evaluation(revision.id, 3)
    assert :ok = perform_rollback(rollback_request(ctx, revision, 1, 3, 3))
    assert [["published", 3, _]] = publication_state(revision.id)
    assert {:ok, _} = Publication.record_fixture_evaluation(revision.id, 1)
    assert :ok = perform_rollback(request)
    assert [["published", 3, _]] = publication_state(revision.id)

    assert {:ok, %{publication_generation: 4}} = reindex(ctx, revision, 3, 4)
    ready(generation_ids(revision.id, 4))
    assert :ok = finalise(revision.id, 4)

    for id <- generation_ids(revision.id, 1),
        do: assert(vector_rows(id) == [["invalidated", nil]])
  end

  for action <- [:revoke, :archive] do
    @action action
    test "#{action} beats pending finalisation and rollback cannot restore terminal content",
         ctx do
      {_, revision} = approved(ctx)
      ready(request_index(ctx, revision))
      assert :ok = finalise(revision.id, 1)
      assert {:ok, _} = reindex(ctx, revision, 1, 1)
      ready(generation_ids(revision.id, 2))
      assert :ok = finalise(revision.id, 2)
      rollback = rollback_request(ctx, revision, 2, 2, 1)
      assert {:ok, _} = Publication.record_fixture_evaluation(revision.id, 1)
      assert {:ok, _} = reindex(ctx, revision, 2, 2)
      ready(generation_ids(revision.id, 3))

      assert {:ok, task} =
               Repo.transact(fn ->
                 case @action do
                   :revoke ->
                     args = Map.put(snapshot(revision), :reason, :obsolete)
                     assert {:ok, _} = invoke(ArticleRevision, :revoke, args, ctx.reviewer)

                   :archive ->
                     assert {:ok, _} =
                              invoke(
                                Article,
                                :archive,
                                %{id: revision.article_id, reason: :obsolete},
                                ctx.reviewer
                              )
                 end

                 {:ok, blocked_task(fn -> finalise(revision.id, 3) end)}
               end)

      assert :ok = Task.await(task)
      assert :ok = perform_rollback(rollback)
      assert [["revoked", nil, nil]] = publication_state(revision.id)

      for generation <- [1, 2, 3],
          id <- generation_ids(revision.id, generation),
          do: assert(vector_rows(id) == [["invalidated", nil]])
    end
  end

  defp queued_finaliser(id) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(parent, {:finaliser_backend, backend})
          finalise(id, 1)
        end)
      end)

    assert_receive {:finaliser_backend, backend}, 5_000
    assert_queued(backend, System.monotonic_time(:millisecond) + 4_000)
    task
  end

  defp assert_queued(backend, deadline) do
    # The second finaliser may wait behind the first finaliser's row-lock
    # request, so either one can be its direct blocker.
    case SQL.query!(Repo, "SELECT cardinality(pg_blocking_pids($1)) > 0", [backend]) do
      %{rows: [[true]]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "finaliser did not wait for the lock"

        Process.sleep(10)
        assert_queued(backend, deadline)
    end
  end

  defp invalid_response(request) do
    {request, response} = EmbeddingTransport.fixture_wire(request)
    body = put_in(response.body, ["data", Access.at(0), "embedding"], List.duplicate(0.0, 1536))
    {request, %{response | body: body}}
  end

  defp approve_draft(ctx, article_id, content \\ payload()) do
    assert {:ok, draft} =
             invoke(
               ArticleRevision,
               :create_draft,
               %{article_id: article_id, content: content},
               ctx.editor
             )

    reviewed = review(ctx, draft)

    assert {:ok, approved} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    approved
  end

  defp enable_collection(ctx, collection),
    do: invoke(KnowledgeCollection, :enable, %{id: collection.id}, ctx.admin)

  defp index_args(revision, current, epoch),
    do: %{
      id: revision.id,
      expected_hash: revision.content_hash,
      expected_generation: current,
      expected_index_epoch: epoch
    }

  defp reindex(ctx, revision, current, epoch),
    do:
      invoke(
        ArticleRevision,
        :request_reindex,
        index_args(revision, current, epoch),
        ctx.reviewer
      )

  defp rollback_request(ctx, revision, current, epoch, target) do
    args = Map.put(index_args(revision, current, epoch), :target_generation, target)

    assert {:ok, %{request_id: id}} =
             invoke(ArticleRevision, :request_index_rollback, args, ctx.reviewer)

    id
  end

  defp perform_rollback(id),
    do: FinalizePublication.perform(%Oban.Job{args: %{"rollback_request_id" => id}})

  defp ready(ids), do: Enum.each(ids, fn id -> assert :ok = Embedding.index(id) end)

  defp generation_ids(id, generation) do
    SQL.query!(
      Repo,
      "SELECT id::text FROM article_embeddings WHERE revision_id = $1 AND generation = $2 ORDER BY locale",
      [db_id(id), generation]
    ).rows
    |> List.flatten()
  end

  defp finalise(id, generation),
    do:
      FinalizePublication.perform(%Oban.Job{
        args: %{"revision_id" => id, "generation" => generation}
      })

  defp delete_finalisation(id),
    do:
      SQL.query!(
        Repo,
        "DELETE FROM oban_jobs WHERE worker LIKE '%FinalizePublication' AND args->>'revision_id' = $1",
        [id]
      )

  defp reject_insert(table, predicate, body) do
    SQL.query!(Repo, """
    CREATE FUNCTION reject_publication_test_insert() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{predicate} THEN RAISE EXCEPTION 'synthetic insert fault'; END IF;
      RETURN NEW;
    END
    $$
    """)

    SQL.query!(Repo, "CREATE TRIGGER reject_publication_test_insert BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION reject_publication_test_insert()")

    try do
      body.()
    after
      SQL.query!(Repo, "DROP TRIGGER reject_publication_test_insert ON #{table}")
      SQL.query!(Repo, "DROP FUNCTION reject_publication_test_insert()")
    end
  end

  defp db_id(id), do: Ecto.UUID.dump!(id)

  defp publication_jobs(id) do
    SQL.query!(
      Repo,
      "SELECT id, args FROM oban_jobs WHERE worker LIKE '%FinalizePublication' AND args->>'revision_id' = $1",
      [id]
    ).rows
  end

  defp publication_state(id) do
    SQL.query!(
      Repo,
      """
      SELECT r.status, r.active_index_generation, a.current_revision_id::text
      FROM article_revisions r JOIN articles a ON a.id = r.article_id WHERE r.id = $1
      """,
      [Ecto.UUID.dump!(id)]
    ).rows
  end
end
