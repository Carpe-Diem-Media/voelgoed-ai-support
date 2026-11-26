defmodule VoelgoedAi.Knowledge.RetrievalTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.KnowledgeFixtures
  import ExUnit.CaptureLog, only: [capture_log: 1]
  import VoelgoedAi.SupportFixtures, only: [invoke: 4, blocked_task: 1]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Knowledge, Repo, SupportDBCase}
  alias VoelgoedAi.Intelligence.{AssistantRevision, Embedding, EmbeddingTransport, InferenceRun}
  alias VoelgoedAi.Knowledge.{ArticleRevision, KnowledgeCollection, Publication, Retrieval}
  alias VoelgoedAi.Knowledge.Workers.FinalizePublication
  alias VoelgoedAi.Support.{Ingress, Ownership, RunProcessing}

  @moduletag :requires_pgvector
  @moduletag :embedding_index
  @link "https://faq.example.test/synthetic"

  test "search and validation require a process-bound support capability" do
    for {action, args} <- [
          {:search_published, %{query: "Synthetic FAQ"}},
          {:validate_evidence, %{citations: [Ash.UUIDv7.generate()], used_links: []}}
        ],
        actor <- [nil, %Retrieval{ref: make_ref()}] do
      input = Ash.ActionInput.for_action(ArticleRevision, action, args, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)
    end
  end

  test "retrieval statements and synthetic query text stay out of Repo telemetry and logs" do
    ctx = setup_search()
    sibling = SupportDBCase.next_conversation(ctx.support, 1)
    {failed_claim, _} = create_run(sibling)
    sentinel = "syntheticretrievalprivacy"
    handler = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:voelgoed_ai, :repo, :query],
               &__MODULE__.classify_query_event/4,
               {self(), sentinel}
             )

    try do
      logs =
        capture_log(fn ->
          SQL.query!(Repo, "SELECT 9123 AS harmless_query_control")
          assert_received {:repo_query, :control}

          Retrieval.with_fixture(ctx.claim, fn search, validate ->
            assert {:ok, %{status: :evidence, evidence: [item]}} =
                     Knowledge.search_published("FAQ " <> sentinel, actor: search)

            assert {:ok, %{status: :evidence, evidence: [^item]}} =
                     Knowledge.validate_evidence([item.citation_id], [@link], actor: validate)
          end)

          fixture(%{wire: &wire_result(&1, 503)})

          Retrieval.with_fixture(failed_claim, fn search, _ ->
            assert {:ok, %{status: :unavailable, evidence: []}} =
                     Knowledge.search_published("FAQ " <> sentinel, actor: search)
          end)
        end)

      refute_received {:repo_query, :retrieval}
      refute_received {:repo_query, :sentinel}
      refute String.contains?(logs, sentinel)
      refute String.contains?(logs, ["WITH eligible AS MATERIALIZED", "tsvector_to_array"])
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def classify_query_event(_, _, %{query: query} = metadata, {test, sentinel})
      when test == self() do
    cond do
      query == "SELECT 9123 AS harmless_query_control" ->
        send(test, {:repo_query, :control})

      String.contains?(query, [
        "WITH eligible AS MATERIALIZED",
        "tsvector_to_array",
        "SET LOCAL statement_timeout = '750ms'"
      ]) ->
        send(test, {:repo_query, :retrieval})

      :binary.match(:erlang.term_to_binary(metadata), sentinel) != :nomatch ->
        send(test, {:repo_query, :sentinel})

      true ->
        :ok
    end
  end

  def classify_query_event(_, _, _, _), do: :ok

  test "bilingual synthetic FAQ projects exact evidence and validates only issued references" do
    ctx = setup_search()
    parent = self()

    fixture(%{
      wire: fn req ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(req)
      end
    })

    assert {:error, :denied} =
             Retrieval.with_fixture(%{ctx.claim | claim_generation: 2}, fn _, _ -> flunk() end)

    assert {:error, :denied} =
             Retrieval.with_fixture(%{ctx.claim | inbox: %{}}, fn _, _ -> flunk() end)

    assert {:error, :denied} =
             Retrieval.with_fixture(%{ctx.claim | run_id: Ash.UUIDv7.generate()}, fn _, _ ->
               flunk()
             end)

    assert {:error, %Ash.Error.Forbidden{}} =
             Knowledge.search_published("FAQ", actor: ctx.knowledge.admin)

    Retrieval.with_fixture(%{ctx.claim | locale: "af-ZA"}, fn search, validate ->
      assert {:ok, :ok} =
               Repo.transact(fn ->
                 assert {:error, _} = Knowledge.search_published("FAQ", actor: search)
                 {:ok, :ok}
               end)

      assert {:error, %Ash.Error.Forbidden{}} = Knowledge.search_published("FAQ", actor: validate)
      assert {:error, %Ash.Error.Forbidden{}} = Knowledge.validate_evidence([], [], actor: search)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(
                 Ash.Query.for_read(
                   InferenceRun,
                   :query_attempt,
                   %{support_run_id: ctx.claim.run_id},
                   actor: search
                 )
               )

      assert {:ok, %{status: :no_evidence, evidence: []}} =
               Knowledge.search_published("!? …", actor: search)

      assert {:ok, %{status: :no_evidence, evidence: []}} =
               Knowledge.search_published(Enum.map_join(1..65, " ", &"word#{&1}"), actor: search)

      refute_received :wire

      assert {:ok, %{status: :evidence, evidence: [item]}} =
               Knowledge.search_published("Sintetiese FAQ", actor: search)

      assert_received :wire
      assert item.revision_id == ctx.revision.id
      assert item.answer == "Sintetiese antwoord."
      assert item.locale == "af-ZA"
      assert item.links == [@link]
      refute Map.has_key?(item, :content)
      refute Map.has_key?(item, :vector)
      refute inspect(item) =~ "synthetic-faq-v1"

      assert {:ok, %{status: :evidence, evidence: [^item]}} =
               Knowledge.validate_evidence([item.citation_id], [@link], actor: validate)

      for {ids, links} <- [
            {[], []},
            {[Ash.UUIDv7.generate()], []},
            {[item.citation_id, item.citation_id], []},
            {[item.citation_id], ["https://faq.example.test/foreign"]}
          ] do
        assert {:ok, %{status: :denied, evidence: []}} =
                 Knowledge.validate_evidence(ids, links, actor: validate)
      end

      SQL.query!(
        Repo,
        "UPDATE article_revisions SET index_epoch = index_epoch + 1 WHERE id = $1",
        [
          uuid(item.revision_id)
        ]
      )

      assert {:ok, %{status: :denied, evidence: []}} =
               Knowledge.validate_evidence([item.citation_id], [], actor: validate)
    end)

    assert query_rows(ctx) == [["succeeded", true, "settled", 8]]
    refute_received :wire
  end

  test "verified applicability is needed before reserving and ranking filters both branches" do
    ctx = setup_search(%{"brand" => ["synthetic-brand"]})
    parent = self()

    fixture(%{
      wire: fn req ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(req)
      end
    })

    assert {:ok, %{status: :no_evidence}} = search(ctx.claim)
    assert {:ok, %{status: :no_evidence}} = search(%{ctx.claim | scope: %{brand: "other"}})
    assert query_rows(ctx) == []
    refute_received :wire

    # More hidden exact-vector and lexical matches than either branch can admit.
    bulk_hidden(ctx, 12)
    semantic_hit = clone_published(ctx, 13, %{}, "Different terms")

    assert {:ok, %{status: :evidence, evidence: [item, semantic]}} =
             search(%{ctx.claim | scope: %{brand: "synthetic-brand"}})

    assert item.revision_id == ctx.revision.id
    assert semantic.revision_id == semantic_hit
    assert item.locale == "en-ZA"
    assert_received :wire
    refute_received :wire
  end

  test "a switch and rollback to the original generation invalidates issued citations" do
    ctx = setup_search()
    revision = ctx.revision
    reviewer = ctx.knowledge.reviewer
    fixture(%{clock: fn -> ctx.now end})

    Retrieval.with_fixture(ctx.claim, fn search, validate ->
      assert {:ok, %{status: :evidence, evidence: [item]}} =
               Knowledge.search_published("FAQ", actor: search)

      assert item.generation == 1
      assert item.index_epoch == 1

      args = %{
        id: revision.id,
        expected_hash: revision.content_hash,
        expected_generation: 1,
        expected_index_epoch: 1
      }

      assert {:ok, _} = invoke(ArticleRevision, :request_reindex, args, reviewer)

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT id::text FROM article_embeddings WHERE revision_id = $1 AND generation = 2",
          [uuid(revision.id)]
        )

      for [id] <- rows, do: assert(:ok = Embedding.index(id))

      assert :ok =
               FinalizePublication.perform(%Oban.Job{
                 args: %{"revision_id" => revision.id, "generation" => 2}
               })

      assert {:ok, _} = Publication.record_fixture_evaluation(revision.id, 1)

      rollback = %{args | expected_generation: 2, expected_index_epoch: 2}

      assert {:ok, %{request_id: request}} =
               invoke(
                 ArticleRevision,
                 :request_index_rollback,
                 Map.put(rollback, :target_generation, 1),
                 reviewer
               )

      assert :ok =
               FinalizePublication.perform(%Oban.Job{args: %{"rollback_request_id" => request}})

      assert %{rows: [[1, 3]]} =
               SQL.query!(
                 Repo,
                 "SELECT active_index_generation, index_epoch FROM article_revisions WHERE id = $1",
                 [uuid(revision.id)]
               )

      assert {:ok, %{status: :denied, evidence: []}} =
               Knowledge.validate_evidence([item.citation_id], [], actor: validate)
    end)
  end

  test "a valid pin without a grant finds nothing and replacement invalidates the old claim" do
    ctx = setup_search(%{}, grant?: false)
    admin = ctx.knowledge.admin
    fixture(%{wire: fn _ -> flunk("query transport reached without a grant") end})
    assert {:ok, %{status: :no_evidence, evidence: []}} = search(ctx.claim)

    draft = VoelgoedAi.SupportFixtures.draft(admin, ctx.support.assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{id: draft.id, collection_id: ctx.collection.id},
               admin
             )

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: draft.id, expected_active_revision_id: ctx.support.revision.id},
               admin
             )

    assert {:error, :denied} = search(ctx.claim)
    assert query_rows(ctx) == []
  end

  test "publication, active vector, audience and temporal gates deny before transport" do
    ctx = setup_search()
    parent = self()

    fixture(%{
      wire: fn req ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(req)
      end
    })

    id = uuid(ctx.revision.id)
    article = uuid(ctx.revision.article_id)
    collection = uuid(ctx.collection.id)

    %{rows: [[content]]} =
      SQL.query!(Repo, "SELECT content FROM article_revisions WHERE id = $1", [id])

    %{rows: [[profile]]} =
      SQL.query!(Repo, "SELECT active_index_profile_id FROM article_revisions WHERE id = $1", [id])

    for {field, value} <- [
          {"effective_from", DateTime.to_iso8601(DateTime.add(ctx.now, 1))},
          {"expires_at", DateTime.to_iso8601(ctx.now)},
          {"sensitive", true},
          {"response_mode", "escalate_only"}
        ] do
      set_content(id, Map.put(content, field, value))
      assert {:ok, %{status: :no_evidence}} = search(ctx.claim)
    end

    set_content(id, content)

    SQL.query!(Repo, "UPDATE articles SET current_revision_id = NULL WHERE id = $1", [article])
    assert {:ok, %{status: :no_evidence}} = search(ctx.claim)
    SQL.query!(Repo, "UPDATE articles SET current_revision_id = $2 WHERE id = $1", [article, id])

    SQL.query!(Repo, "UPDATE knowledge_collections SET audience = 'internal' WHERE id = $1", [
      collection
    ])

    assert {:ok, %{status: :no_evidence}} = search(ctx.claim)

    SQL.query!(Repo, "UPDATE knowledge_collections SET audience = 'public' WHERE id = $1", [
      collection
    ])

    for {field, bad, good} <- [
          {"profile_id", "wrong", profile},
          {"content_hash", String.duplicate("c", 64), ctx.revision.content_hash},
          {"generation", 2, 1}
        ] do
      statement =
        "UPDATE article_embeddings SET #{field} = $2 WHERE revision_id = $1 AND locale = 'en-ZA'"

      SQL.query!(Repo, statement, [id, bad])
      assert {:ok, %{status: :no_evidence}} = search(ctx.claim)
      SQL.query!(Repo, statement, [id, good])
    end

    %{rows: [[vector]]} =
      SQL.query!(
        Repo,
        "SELECT vector FROM article_embeddings WHERE revision_id = $1 AND locale = 'en-ZA'",
        [id]
      )

    SQL.query!(
      Repo,
      "UPDATE article_embeddings SET state = 'invalidated', vector = NULL WHERE revision_id = $1 AND locale = 'en-ZA'",
      [id]
    )

    assert {:ok, %{status: :no_evidence}} = search(ctx.claim)
    assert query_rows(ctx) == []
    refute_received :wire

    SQL.query!(
      Repo,
      "UPDATE article_embeddings SET state = 'ready', vector = $2 WHERE revision_id = $1 AND locale = 'en-ZA'",
      [id, vector]
    )

    assert {:ok, %{status: :evidence}} = search(ctx.claim)
    assert_received :wire
  end

  defp set_content(id, content) do
    SQL.query!(Repo, "UPDATE article_revisions SET content = $2 WHERE id = $1", [id, content])
  end

  test "cap and invalid price denial roll back the attempt and synthetic admission count" do
    ctx = setup_search()
    parent = self()

    wire = fn req ->
      send(parent, :wire)
      EmbeddingTransport.fixture_wire(req)
    end

    on_exit(fn -> clear_query_admission(ctx.now) end)

    for budget <- [%{day_cap: 1}, %{price: %{}}] do
      fixture(Map.merge(budget, %{wire: wire, query_admission: true, clock: fn -> ctx.now end}))
      assert {:ok, %{status: :unavailable, evidence: []}} = search(ctx.claim)
      assert query_rows(ctx) == []
      assert admission_count(ctx.now) == []
    end

    refute_received :wire
  end

  test "query T03 locks admission before day then month spend windows" do
    ctx = setup_search()
    fixture(%{query_admission: true, clock: fn -> ctx.now end})
    on_exit(fn -> clear_query_admission(ctx.now) end)
    day = DateTime.to_date(ctx.now)
    month = Date.beginning_of_month(day)

    sibling = SupportDBCase.next_conversation(ctx.support, 1)
    {second, _} = create_run(sibling)
    sibling = SupportDBCase.next_conversation(sibling, 1)
    {third, _} = create_run(sibling)

    assert {:ok, :ok} =
             Repo.transact(fn ->
               VoelgoedAi.Governance.Admission.reserve([
                 VoelgoedAi.Governance.Admission.window(
                   :turn,
                   "synthetic:query_embedding",
                   ctx.now,
                   60,
                   2
                 )
               ])

               SQL.query!(
                 Repo,
                 "UPDATE support_admission_windows SET count = 0 WHERE scope = 'synthetic:query_embedding'"
               )

               {:ok, :ok}
             end)

    assert {:ok, {first_search, second_search}} =
             Repo.transact(fn ->
               assert %{num_rows: 1} = lock_spend("day", day, "")
               first = blocked_task(fn -> search(ctx.claim) end)
               second = Task.async(fn -> search(second) end)

               probe =
                 Task.async(fn ->
                   assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                            SQL.query(Repo, """
                            SELECT count FROM support_admission_windows WHERE scope = 'synthetic:query_embedding'
                            FOR UPDATE NOWAIT
                            """)

                   assert %{num_rows: 1} = lock_spend("month", month, " NOWAIT")
                 end)

               Task.await(probe, 2_000)
               {:ok, {first, second}}
             end)

    assert Enum.all?(
             Task.await_many([first_search, second_search], 5_000),
             &match?({:ok, %{status: :evidence}}, &1)
           )

    assert admission_count(ctx.now) == [[2]]
    assert {:ok, %{status: :unavailable}} = search(third)
    assert query_rows(ctx) == [["succeeded", true, "settled", 8]]
    assert query_rows(%{ctx | claim: second}) == [["succeeded", true, "settled", 8]]
    assert query_rows(%{ctx | claim: third}) == []
  end

  test "only one concurrent search commits a dispatch and a reclaim cannot invoke again" do
    ctx = setup_search()
    parent = self()

    fixture(%{
      consume_dispatch: fn consume ->
        assert {:ok, _} = first = consume.()
        assert {:error, :unavailable} = consume.()
        first
      end,
      wire: fn req ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(req)
      end
    })

    statuses =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> search(ctx.claim) end) end)
      |> Task.await_many(5_000)
      |> Enum.map(fn {:ok, result} -> result.status end)

    assert Enum.sort(statuses) == [:evidence, :unavailable]
    assert_received :wire
    refute_received :wire
    assert query_rows(ctx) == [["succeeded", true, "settled", 8]]

    SQL.query!(Repo, "UPDATE support_runs SET claim_generation = 2 WHERE id = $1", [
      uuid(ctx.claim.run_id)
    ])

    assert {:ok, %{status: :unavailable}} = search(%{ctx.claim | claim_generation: 2})
    refute_received :wire
  end

  for field <- [:lease_expires_at, :deadline_at], boundary <- [:rank, :validate] do
    @cutoff_field field
    @boundary boundary

    test "#{boundary} denies at the exact #{field} while the other cutoff is future" do
      ctx = setup_search()
      cutoff = DateTime.add(ctx.now, 10)
      before_cutoff = DateTime.add(cutoff, -1, :microsecond)
      set_run_cutoff(ctx.claim, @cutoff_field, cutoff)
      parent = self()

      fixture(%{
        clock: fn -> ctx.now end,
        wire: fn req ->
          send(parent, :wire)
          EmbeddingTransport.fixture_wire(req)
        end,
        before_settlement: fn _ ->
          if @boundary == :rank, do: set_support_clock(ctx, cutoff)
        end
      })

      observe_rank = fn _, _, _ -> send(parent, :rank_executed) end

      Retrieval.with_rank_measurement(observe_rank, fn ->
        Retrieval.with_fixture(ctx.claim, fn search, validate ->
          result = Knowledge.search_published("FAQ", actor: search)
          assert_received :wire
          assert query_rows(ctx) == [["succeeded", true, "settled", 8]]

          case @boundary do
            :rank ->
              assert {:ok, %{status: :unavailable, evidence: []}} = result
              refute_received :rank_executed

            :validate ->
              assert {:ok, %{status: :evidence, evidence: [item]}} = result
              assert_received :rank_executed
              set_support_clock(ctx, before_cutoff)

              assert {:ok, %{status: :evidence, evidence: [^item]}} =
                       Knowledge.validate_evidence([item.citation_id], [@link], actor: validate)

              set_support_clock(ctx, cutoff)

              assert {:ok, %{status: :denied, evidence: []}} =
                       Knowledge.validate_evidence([item.citation_id], [@link], actor: validate)
          end

          refute_received :wire
        end)
      end)
    end

    if boundary == :rank do
      test "rank projects evidence one microsecond before #{field}" do
        ctx = setup_search()
        cutoff = DateTime.add(ctx.now, 10)
        set_run_cutoff(ctx.claim, @cutoff_field, cutoff)

        fixture(%{
          clock: fn -> ctx.now end,
          before_settlement: fn _ ->
            set_support_clock(ctx, DateTime.add(cutoff, -1, :microsecond))
          end
        })

        assert {:ok, %{status: :evidence, evidence: [_]}} = search(ctx.claim)
        assert query_rows(ctx) == [["succeeded", true, "settled", 8]]
      end
    end
  end

  test "embedding inhibit after the query claim releases the reservation before dispatch" do
    ctx = setup_search()
    parent = self()

    fixture(%{
      clock: fn -> ctx.now end,
      after_claim: fn _ ->
        assert %{num_rows: 1} =
                 SQL.query!(Repo, "UPDATE automation_controls SET embedding_inhibited = true")

        assert {:ok, :ok} =
                 RunProcessing.with_run(ctx.claim.run_id, fn config, session, run, now ->
                   assert Ownership.write_enabled?(config)
                   assert RunProcessing.valid_run?(config, session, run)
                   assert run.state == :running
                   assert run.claim_generation == ctx.claim.claim_generation
                   assert DateTime.before?(now, run.deadline_at)
                   assert DateTime.before?(now, run.lease_expires_at)
                   {:ok, :ok}
                 end)
      end,
      wire: fn req ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(req)
      end
    })

    assert {:ok, %{status: :unavailable, evidence: []}} = search(ctx.claim)
    assert query_rows(ctx) == [["rejected", false, "released", nil]]
    refute_received :wire
  end

  defp set_run_cutoff(claim, field, cutoff) do
    assert %{num_rows: 1} =
             SQL.query!(Repo, "UPDATE support_runs SET #{field} = $2 WHERE id = $1", [
               uuid(claim.run_id),
               DateTime.to_naive(cutoff)
             ])
  end

  defp set_support_clock(ctx, now), do: Agent.update(ctx.support.fake, &%{&1 | now: now})

  for change <- [
        :revocation,
        :expiry,
        :grant_withdrawal,
        :generation,
        :index_epoch,
        :revision_profile,
        :embedding_profile,
        :ownership_epoch,
        :human_takeover
      ],
      boundary <- [:rank, :validate] do
    @change change
    @stage boundary

    test "#{boundary} requalifies after #{change}" do
      {ctx, decoy} = evidence_fixture(@change)

      case @stage do
        :rank ->
          assert_rank_after_change(ctx, decoy, @change)

        :validate ->
          Retrieval.with_fixture(ctx.claim, fn search, validate ->
            assert {:ok, %{status: :evidence, evidence: items}} =
                     Knowledge.search_published("FAQ", actor: search)

            target = Enum.find(items, &(&1.revision_id == ctx.revision.id))
            current = Enum.find(items, &(&1.revision_id == decoy))
            assert target.links == [@link]

            assert {:ok, %{status: :evidence, evidence: [^target, ^current]}} =
                     Knowledge.validate_evidence(
                       [target.citation_id, current.citation_id],
                       [@link],
                       actor: validate
                     )

            change_evidence(ctx, @change)

            assert {:ok, %{status: :denied, evidence: []}} =
                     Knowledge.validate_evidence([target.citation_id], [@link], actor: validate)

            assert {:ok, %{status: :denied, evidence: []}} =
                     Knowledge.validate_evidence(
                       [target.citation_id, current.citation_id],
                       [],
                       actor: validate
                     )

            unless @change in [:grant_withdrawal, :ownership_epoch, :human_takeover] do
              assert {:ok, %{status: :evidence, evidence: [^current]}} =
                       Knowledge.validate_evidence([current.citation_id], [], actor: validate)
            end
          end)
      end
    end
  end

  test "rank projection holds the control row against a competing editorial revocation" do
    {ctx, decoy} = evidence_fixture(:revocation)
    parent = self()

    observe = fn _, _, {:ok, _} ->
      writer = blocked_task(fn -> change_evidence(ctx, :revocation) end)

      probe =
        Task.async(fn ->
          assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                   SQL.query(Repo, "SELECT id FROM automation_controls FOR UPDATE NOWAIT")
        end)

      Task.await(probe, 2_000)
      send(parent, {:blocked_editor, writer})
    end

    Retrieval.with_fixture(ctx.claim, fn search, validate ->
      assert {:ok, %{status: :evidence, evidence: items}} =
               Retrieval.with_rank_measurement(observe, fn ->
                 Knowledge.search_published("FAQ", actor: search)
               end)

      assert_received {:blocked_editor, writer}
      assert MapSet.new(items, & &1.revision_id) == MapSet.new([ctx.revision.id, decoy])
      assert :ok = Task.await(writer, 5_000)
      target = Enum.find(items, &(&1.revision_id == ctx.revision.id))

      assert {:ok, %{status: :denied, evidence: []}} =
               Knowledge.validate_evidence([target.citation_id], [@link], actor: validate)
    end)
  end

  defp evidence_fixture(:expiry) do
    expiry = DateTime.add(DateTime.utc_now(), 600)
    ctx = setup_search(%{}, content: %{"expires_at" => DateTime.to_iso8601(expiry)})
    cutoff = DateTime.add(expiry, 30)
    set_run_cutoff(ctx.claim, :deadline_at, cutoff)
    set_run_cutoff(ctx.claim, :lease_expires_at, cutoff)
    {Map.put(ctx, :expiry, expiry), clone_published(ctx, 1, %{})}
  end

  defp evidence_fixture(_change) do
    ctx = setup_search()
    {ctx, clone_published(ctx, 1, %{})}
  end

  defp assert_rank_after_change(ctx, decoy, change) do
    parent = self()
    barrier = make_ref()

    fixture(%{
      clock: fn -> ctx.now end,
      wire: fn req ->
        send(parent, {:embedding_parked, barrier, self()})

        receive do
          {:complete_embedding, ^barrier} -> EmbeddingTransport.fixture_wire(req)
        after
          5_000 -> exit(:embedding_fixture_timeout)
        end
      end
    })

    searcher = Task.async(fn -> search(ctx.claim) end)
    assert_receive {:embedding_parked, ^barrier, adapter}, 5_000

    try do
      change_evidence(ctx, change)
    after
      send(adapter, {:complete_embedding, barrier})
    end

    assert {:ok, result} = Task.await(searcher, 5_000)
    assert query_rows(ctx) == [["succeeded", true, "settled", 8]]

    case change do
      :index_epoch ->
        assert result.status == :evidence

        assert %{index_epoch: 2} =
                 Enum.find(result.evidence, &(&1.revision_id == ctx.revision.id))

      denied when denied in [:grant_withdrawal, :ownership_epoch, :human_takeover] ->
        assert result == %{status: :unavailable, evidence: []}

      _ ->
        assert result.status == :evidence
        assert Enum.map(result.evidence, & &1.revision_id) == [decoy]
    end
  end

  defp change_evidence(ctx, :revocation) do
    args = Map.put(snapshot(ctx.revision), :reason, :obsolete)

    assert {:ok, %{status: :revoked}} =
             invoke(ArticleRevision, :revoke, args, ctx.knowledge.reviewer)

    :ok
  end

  defp change_evidence(ctx, :expiry), do: set_support_clock(ctx, ctx.expiry)

  defp change_evidence(ctx, :grant_withdrawal) do
    admin = ctx.knowledge.admin
    draft = VoelgoedAi.SupportFixtures.draft(admin, ctx.support.assistant)
    args = %{id: draft.id, collection_id: ctx.collection.id}

    assert {:ok, %{collection_ids: [_]}} =
             invoke(AssistantRevision, :grant_collection, args, admin)

    assert {:ok, %{collection_ids: []}} =
             invoke(AssistantRevision, :remove_collection, args, admin)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: draft.id, expected_active_revision_id: ctx.support.revision.id},
               admin
             )
  end

  defp change_evidence(ctx, :human_takeover) do
    event = fn payload ->
      Map.merge(payload, %{
        "id" => ctx.support.event.message_id + 1,
        "message_type" => "outgoing",
        "sender" => %{"type" => "user", "id" => 82}
      })
    end

    assert SupportDBCase.signed_request(ctx.support, event).status == 204

    assert %{rows: [["human_active", true]]} =
             SQL.query!(Repo, "SELECT state, human_inhibit FROM support_sessions WHERE id = $1", [
               uuid(SupportDBCase.session_id(ctx.support))
             ])
  end

  defp change_evidence(ctx, :ownership_epoch) do
    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE support_sessions SET ownership_epoch = ownership_epoch + 1 WHERE id = $1",
               [uuid(SupportDBCase.session_id(ctx.support))]
             )
  end

  defp change_evidence(ctx, :embedding_profile) do
    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE article_embeddings SET profile_id = 'different-profile' WHERE revision_id = $1 AND locale = 'en-ZA'",
               [uuid(ctx.revision.id)]
             )
  end

  defp change_evidence(ctx, change)
       when change in [:generation, :index_epoch, :revision_profile] do
    update =
      case change do
        :generation ->
          "active_index_generation = active_index_generation + 1, publication_generation = publication_generation + 1"

        :index_epoch ->
          "index_epoch = index_epoch + 1"

        :revision_profile ->
          "active_index_profile_id = 'different-profile'"
      end

    assert %{num_rows: 1} =
             SQL.query!(Repo, "UPDATE article_revisions SET #{update} WHERE id = $1", [
               uuid(ctx.revision.id)
             ])
  end

  for loss <- [:after_claim, :after_dispatch] do
    @loss loss
    test "scope loss at #{loss} yields no evidence and retains only the applicable cost" do
      ctx = setup_search()
      parent = self()

      hook = fn _ ->
        assert {:ok, _} =
                 invoke(
                   KnowledgeCollection,
                   :disable,
                   %{id: ctx.collection.id},
                   ctx.knowledge.admin
                 )
      end

      fixture(%{
        @loss => hook,
        :wire => fn req ->
          send(parent, :wire)
          EmbeddingTransport.fixture_wire(req)
        end
      })

      if @loss == :after_claim do
        assert {:ok, %{status: :unavailable, evidence: []}} = search(ctx.claim)
        assert query_rows(ctx) == [["rejected", false, "released", nil]]
        refute_received :wire
      else
        assert {:ok, %{status: :no_evidence, evidence: []}} = search(ctx.claim)
        assert query_rows(ctx) == [["succeeded", true, "settled", 8]]
        assert_received :wire
      end
    end
  end

  for {name, result, expected} <- [
        {:unavailable, 503, ["unknown", true, "unknown", nil]},
        {:timeout, :timeout, ["unknown", true, "unknown", nil]},
        {:missing_usage, :missing_usage, ["unknown", true, "unknown", nil]},
        {:invalid_vector, :invalid_vector, ["failed", true, "settled", 8]},
        {:overflow, :overflow, ["unknown", true, "unknown", nil]},
        {:over_reserve, :over_reserve, ["succeeded", true, "settled", 100_000]}
      ] do
    @result result
    @expected expected

    test "#{name} invokes at most once and provides no lexical fallback" do
      ctx = setup_search()
      parent = self()

      fixture(%{
        wire: fn req ->
          send(parent, {:wire, req.options.max_retries, req.options.redirect})
          wire_result(req, @result)
        end
      })

      assert {:ok, %{status: :unavailable, evidence: []}} = search(ctx.claim)
      assert_received {:wire, 0, false}
      refute_received {:wire, _, _}
      assert query_rows(ctx) == [@expected]
    end
  end

  for {phase, dispatched, terminal} <- [
        {:after_claim, false, ["rejected", false, "released", nil]},
        {:after_dispatch, true, ["unknown", true, "unknown", nil]}
      ] do
    @phase phase
    @dispatched dispatched
    @terminal terminal
    test "sweep handles a crash at #{phase} without live support" do
      ctx = setup_search()
      parent = self()

      fixture(%{
        @phase => fn _ -> throw(:synthetic_crash) end,
        :wire => fn req ->
          send(parent, :wire)
          EmbeddingTransport.fixture_wire(req)
        end,
        :clock => fn -> ctx.now end
      })

      assert catch_throw(search(ctx.claim)) == :synthetic_crash
      refute_received :wire
      assert query_rows(ctx) == [["running", @dispatched, "reserved", nil]]
      SupportDBCase.disable_automation(ctx.support)
      fixture(%{clock: fn -> DateTime.add(ctx.now, 31) end})
      assert :ok = Embedding.sweep()
      assert query_rows(ctx) == [@terminal]
    end
  end

  test "conservative closure qualifies the immutable query parent without live answer authority" do
    ctx = setup_search()
    fixture(%{wire: fn req -> wire_result(req, 503) end, clock: fn -> ctx.now end})

    assert {:ok, %{status: :unavailable}} = search(ctx.claim)
    assert query_rows(ctx) == [["unknown", true, "unknown", nil]]

    %{rows: [[id]]} =
      SQL.query!(Repo, "SELECT id::text FROM inference_runs WHERE support_run_id = $1", [
        uuid(ctx.claim.run_id)
      ])

    SupportDBCase.disable_automation(ctx.support)
    args = %{id: id, reason: :conservative_closure}

    assert {:error, _} = invoke(InferenceRun, :close_unknown_embedding, args, ctx.knowledge.admin)
    fixture(%{closure_approved_by: ctx.knowledge.admin.id})

    assert {:error, _} =
             invoke(InferenceRun, :close_unknown_embedding, args, ctx.knowledge.reviewer)

    for _ <- 1..2 do
      assert {:ok, %{state: :abandoned}} =
               invoke(InferenceRun, :close_unknown_embedding, args, ctx.knowledge.admin)
    end

    assert query_rows(ctx) == [["abandoned", true, "conservatively_settled", 81_920]]
  end

  test "late correlated usage settles the original window after recovery and yields no evidence" do
    ctx = setup_search()
    origin = DateTime.to_date(ctx.now)
    late = DateTime.add(ctx.now, 35, :day)

    fixture(%{
      clock: fn -> ctx.now end,
      before_settlement: fn _ ->
        fixture(%{clock: fn -> late end})
        assert :ok = Embedding.sweep()
        assert query_rows(ctx) == [["unknown", true, "unknown", nil]]
        SupportDBCase.disable_automation(ctx.support)
      end
    })

    assert {:ok, %{status: :unavailable, evidence: []}} = search(ctx.claim)
    assert query_rows(ctx) == [["succeeded", true, "settled", 8]]
    assert :ok = Embedding.sweep()

    assert %{rows: [[^origin, 8]]} =
             SQL.query!(
               Repo,
               """
                 SELECT r.day_window, l.amount_nano_usd
                 FROM inference_runs i JOIN usage_reservations r ON r.inference_run_id = i.id
                 JOIN usage_ledger_entries l ON l.reservation_id = r.id
                 WHERE i.support_run_id = $1
               """,
               [uuid(ctx.claim.run_id)]
             )
  end

  @tag :ranking_measurement
  test "ranking at fixture volume returns four and reports redacted timing" do
    ctx = setup_search()
    bulk_hidden(ctx, 64)

    for index <- 65..255 do
      clone_published(ctx, index, %{}, "Synthetic FAQ")
    end

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:voelgoed_ai, :repo, :query],
        &__MODULE__.control_lock_event/4,
        self()
      )

    fixture(%{clock: &VoelgoedAi.Support.ChatwootAdapter.now/0})

    try do
      {samples, _} =
        Enum.map_reduce(1..20, {ctx.support, ctx.claim}, fn index, {support, claim} ->
          start = System.monotonic_time(:microsecond)

          assert {:ok, %{status: :evidence, evidence: evidence}} =
                   Retrieval.with_rank_measurement(&measure_rank_plan/3, fn -> search(claim) end)

          total = System.monotonic_time(:microsecond) - start
          assert length(evidence) == 4

          assert Enum.map(evidence, & &1.revision_id) ==
                   Enum.sort(Enum.map(evidence, & &1.revision_id))

          assert_received {:ranking_sample, nodes}
          assert_received {:rank_control_lock, timing}
          branches = for {"WindowAgg", rows, time} <- nodes, rows == 10, do: time

          if index == 1 do
            # Remove conds, filter values, relation names, parameters and IDs.
            IO.puts(
              "Result: redacted ranking plan nodes (type, rows) #{inspect(Enum.map(nodes, fn {type, rows, _} -> {type, rows} end), limit: :infinity)}"
            )
          end

          assert length(branches) == 2

          next =
            if index < 20 do
              if rem(index, 8) == 0, do: SupportDBCase.advance_clock(support, 60)
              sibling = SupportDBCase.next_conversation(support, 1)
              {claim, _} = create_run(sibling)
              {sibling, claim}
            else
              {support, claim}
            end

          {[total, timing | Enum.map(branches, &round(&1 * 1000))], next}
        end)

      for {values, label} <-
            Enum.zip(Enum.zip_with(samples, & &1), [
              "end_to_end",
              "control_lock",
              "vector_plan",
              "lexical_plan"
            ]) do
        sorted = Enum.sort(values)
        IO.puts("Result: #{label} us p50=#{Enum.at(sorted, 9)} p95=#{Enum.at(sorted, 18)}")
      end
    after
      :telemetry.detach(handler)
      Process.delete({__MODULE__, :control_locked})
      Process.delete({__MODULE__, :rank_measured})
    end
  end

  defp measure_rank_plan(sql, params, {:ok, _}) do
    %{rows: [[[%{"Plan" => plan}]]]} =
      SQL.query!(Repo, "EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params,
        log: false,
        telemetry_event: nil
      )

    Process.put({__MODULE__, :rank_measured}, true)
    send(self(), {:ranking_sample, plan_nodes(plan)})
  end

  @doc false
  def control_lock_event(_, _, %{query: query}, test) when test == self() do
    key = {__MODULE__, :control_locked}

    cond do
      query =~ ~s("automation_controls") and query =~ "FOR UPDATE" ->
        Process.put(key, System.monotonic_time(:microsecond))

      String.downcase(query) == "commit" ->
        started = Process.delete(key)

        if Process.delete({__MODULE__, :rank_measured}) && started do
          send(test, {:rank_control_lock, System.monotonic_time(:microsecond) - started})
        end

      true ->
        :ok
    end
  end

  def control_lock_event(_, _, _, _), do: :ok

  defp plan_nodes(plan) do
    [
      {plan["Node Type"], plan["Actual Rows"], plan["Actual Total Time"]}
      | Enum.flat_map(Map.get(plan, "Plans", []), &plan_nodes/1)
    ]
  end

  test "opposite branch ranks yield an exact fused tie ordered by revision UUID" do
    ctx = setup_search()
    lower = clone_published(ctx, 1, %{})
    upper = ctx.revision.id
    assert lower < upper

    {:ok, orthogonal} = Ash.Vector.new([0.0, 1.0 | List.duplicate(0.0, 1534)])

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE article_embeddings SET vector = $2 WHERE revision_id = $1",
               [uuid(lower), orthogonal]
             )

    observe = fn _, _, {:ok, %{rows: rows}} ->
      ranks =
        Map.new(rows, fn [id | columns] -> {Ecto.UUID.load!(id), Enum.take(columns, -2)} end)

      orders =
        for permutation <- [rows, Enum.reverse(rows)] do
          for {id, score, _} <- Retrieval.sort_fixture_ranks(permutation) do
            {Ecto.UUID.load!(id), score}
          end
        end

      send(self(), {:fused_ranks, ranks, orders})
    end

    assert {:ok, %{status: :evidence, evidence: evidence}} =
             Retrieval.with_rank_measurement(observe, fn -> search(ctx.claim) end)

    assert Enum.map(evidence, & &1.revision_id) == [lower, upper]
    assert_received {:fused_ranks, ranks, orders}
    assert ranks == %{lower => [2, 1], upper => [1, 2]}
    expected = [{lower, {123, 3_782}}, {upper, {123, 3_782}}]
    assert orders == [expected, expected]
  end

  defp setup_search(scope \\ %{}, opts \\ []) do
    knowledge = setup_knowledge(%{embedding_index: true})
    collection = collection(knowledge)
    fixture(%{})

    content =
      payload()
      |> Map.put("applicability", scope)
      |> Map.update!("source_references", fn [source] ->
        [Map.put(source, "public_link", @link)]
      end)
      |> Map.merge(Keyword.get(opts, :content, %{}))

    revision = draft_revision(knowledge, collection)

    assert {:ok, revision} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(revision), :content, content),
               knowledge.editor
             )

    reviewed = review(knowledge, revision)

    assert {:ok, revision} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), knowledge.reviewer)

    for id <- request_index(knowledge, revision), do: assert(:ok = Embedding.index(id))

    assert :ok =
             FinalizePublication.perform(%Oban.Job{
               args: %{"revision_id" => revision.id, "generation" => 1}
             })

    support =
      SupportDBCase.setup(
        staff: {knowledge, knowledge.admin, nil},
        before_publish: fn admin, rev ->
          if Keyword.get(opts, :grant?, true) do
            assert {:ok, _} =
                     invoke(
                       AssistantRevision,
                       :grant_collection,
                       %{id: rev.id, collection_id: collection.id},
                       admin
                     )
          end
        end
      )

    {claim, now} = create_run(support)

    %{
      support: support,
      knowledge: knowledge,
      claim: claim,
      now: now,
      revision: revision,
      collection: collection
    }
  end

  defp create_run(support) do
    assert {:ok, event_id} = Ingress.accept(support.event)
    assert :ok = RunProcessing.process_event(event_id)
    session_id = SupportDBCase.session_id(support)
    now = VoelgoedAi.Support.ChatwootAdapter.now()

    assert %{rows: [[run_id]]} =
             SQL.query!(
               Repo,
               """
               UPDATE support_runs SET state = 'running', started_at = $2,
                 lease_expires_at = $2::timestamp + interval '30 seconds', claim_generation = 1, attempt_count = 1
               WHERE session_id = $1 RETURNING id::text
               """,
               [uuid(session_id), DateTime.to_naive(now)]
             )

    on_exit(fn -> cleanup_query_attempts(run_id) end)

    {%{
       run_id: run_id,
       inbox:
         Map.take(support.event, [:installation_ref, :external_account_id, :external_inbox_id]),
       claim_generation: 1,
       locale: "en-ZA",
       scope: %{}
     }, now}
  end

  defp bulk_hidden(ctx, count) do
    # A missing context match makes these published rows ineligible. Their
    # UUIDs sort before the visible revision and their lexical score is better.
    for i <- 1..count do
      clone_published(ctx, i, %{"brand" => ["unverified"]})
    end
  end

  defp clone_published(ctx, index, scope, title \\ "Synthetic FAQ Synthetic FAQ Synthetic FAQ") do
    article = Ash.UUIDv7.generate()
    revision = Ash.UUIDv7.bingenerate(DateTime.add(ctx.now, index - 86_400))

    raw =
      payload()
      |> Map.put("applicability", scope)
      |> Map.update!("localized_content", fn variants ->
        Enum.map(variants, &Map.put(&1, "title", title))
      end)

    assert {:ok, content} = VoelgoedAi.Knowledge.Content.parse(raw)
    hash = VoelgoedAi.Knowledge.Content.hash(content)

    SQL.query!(
      Repo,
      """
      INSERT INTO articles (id, article_ref, slug, collection_id, owner_id, status, inserted_at, updated_at)
      SELECT $2, article_ref || $3::text, slug || $3::text, collection_id, owner_id,
        status, inserted_at, updated_at FROM articles WHERE id = $1
      """,
      [uuid(ctx.revision.article_id), uuid(article), "-clone-#{index}"]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO article_revisions (id, article_id, revision_number, status, edit_version,
        content, content_hash, content_hash_version, review_hash, approved_by_id, approved_at,
        created_by_id, contributor_ids, publication_generation, publication_collection_epoch,
        publication_profile_id, publication_deadline_at, publication_requested_by_id,
        published_at, active_index_generation, active_index_profile_id, index_epoch, inserted_at, updated_at)
      SELECT $2, $3, revision_number, status, edit_version, $4, $5, content_hash_version, $5,
        approved_by_id, approved_at, created_by_id, contributor_ids, publication_generation,
        publication_collection_epoch, publication_profile_id, publication_deadline_at,
        publication_requested_by_id, published_at, active_index_generation, active_index_profile_id,
        index_epoch, inserted_at, updated_at FROM article_revisions WHERE id = $1
      """,
      [uuid(ctx.revision.id), revision, uuid(article), content, hash]
    )

    SQL.query!(Repo, "UPDATE articles SET current_revision_id = $2 WHERE id = $1", [
      uuid(article),
      revision
    ])

    embedding = uuid(Ash.UUIDv7.generate())
    attempt = uuid(Ash.UUIDv7.generate())

    SQL.query!(
      Repo,
      """
      INSERT INTO article_embeddings (id, revision_id, generation, locale, profile_id, content_hash,
        state, attempt_count, deadline_at, inserted_at, updated_at)
      SELECT $2, $3, generation, locale, profile_id, $4, 'queued', 0, deadline_at,
        inserted_at, updated_at FROM article_embeddings WHERE revision_id = $1 AND locale = 'en-ZA'
      """,
      [uuid(ctx.revision.id), embedding, revision, hash]
    )

    SQL.query!(
      Repo,
      """
      INSERT INTO inference_runs (id, article_embedding_id, purpose, provider, model_id, profile_id,
        ordinal, deadline_at, state, dispatch_fence, correlation_id, inserted_at, updated_at)
      SELECT $2, $3, i.purpose, provider, model_id, i.profile_id, ordinal, i.deadline_at, 'queued',
        $2, $2, i.inserted_at, i.updated_at
      FROM article_embeddings v JOIN inference_runs i ON i.id = v.last_attempt_id
      WHERE v.revision_id = $1 AND v.locale = 'en-ZA'
      """,
      [uuid(ctx.revision.id), attempt, embedding]
    )

    SQL.query!(
      Repo,
      """
      UPDATE article_embeddings clone SET state = 'ready', vector = v.vector, attempt_count = 1,
        last_attempt_id = $3
      FROM article_embeddings v WHERE clone.id = $2 AND v.revision_id = $1 AND v.locale = 'en-ZA'
      """,
      [uuid(ctx.revision.id), embedding, attempt]
    )

    Ecto.UUID.load!(revision)
  end

  defp search(claim) do
    Retrieval.with_fixture(claim, fn search, _ ->
      Knowledge.search_published("FAQ", actor: search)
    end)
  end

  defp query_rows(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT i.state, i.dispatched_at IS NOT NULL, r.state, l.amount_nano_usd
      FROM inference_runs i JOIN usage_reservations r ON r.inference_run_id = i.id
      LEFT JOIN usage_ledger_entries l ON l.reservation_id = r.id
      WHERE i.support_run_id = $1
      """,
      [uuid(ctx.claim.run_id)]
    ).rows
  end

  defp lock_spend(kind, start, lock) do
    SQL.query!(
      Repo,
      """
      SELECT id FROM spend_windows WHERE kind = $1 AND scope = 'global' AND window_start = $2
      FOR UPDATE#{lock}
      """,
      [kind, start]
    )
  end

  defp admission_count(now) do
    SQL.query!(
      Repo,
      """
      SELECT count FROM support_admission_windows WHERE scope = 'synthetic:query_embedding'
        AND starts_at = (to_timestamp($1) AT TIME ZONE 'UTC')
      """,
      [div(DateTime.to_unix(now), 60) * 60]
    ).rows
  end

  defp clear_query_admission(now) do
    SQL.query!(
      Repo,
      """
      DELETE FROM support_admission_windows WHERE scope = 'synthetic:query_embedding'
        AND starts_at = (to_timestamp($1) AT TIME ZONE 'UTC')
      """,
      [div(DateTime.to_unix(now), 60) * 60]
    )
  end

  defp wire_result(req, status) when is_integer(status),
    do: {req, Req.Response.new(status: status)}

  defp wire_result(req, :timeout), do: {req, %Req.TransportError{reason: :timeout}}

  defp wire_result(req, change) do
    {req, response} = EmbeddingTransport.fixture_wire(req)

    body =
      case change do
        :invalid_vector ->
          put_in(response.body, ["data", Access.at(0), "embedding"], [0.0])

        :missing_usage ->
          Map.delete(response.body, "usage")

        :overflow ->
          Map.put(response.body, "usage", %{
            "total_tokens" => 9_223_372_036_854_775_807,
            "prompt_tokens" => 9_223_372_036_854_775_807
          })

        :over_reserve ->
          Map.put(response.body, "usage", %{"total_tokens" => 40_000, "prompt_tokens" => 40_000})
      end

    {req, %{response | body: body}}
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
