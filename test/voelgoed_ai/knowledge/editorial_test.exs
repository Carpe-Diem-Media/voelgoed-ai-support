defmodule VoelgoedAi.Knowledge.EditorialTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffFixtures, only: [authenticate: 1]
  import VoelgoedAi.SupportFixtures, except: [setup: 0]
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo}
  alias VoelgoedAi.Governance.AuditEvent

  alias VoelgoedAi.Intelligence.{
    Assistant,
    AssistantRevision,
    Embedding,
    EmbeddingProfile,
    EmbeddingTransport,
    InferenceRun
  }

  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Content, KnowledgeCollection}
  alias VoelgoedAi.Knowledge.Workers.IndexArticle
  alias VoelgoedAi.Support.Configuration

  setup :setup_knowledge

  test "a stale draft snapshot disables editing, submission and withdrawal", ctx do
    draft = draft_revision(ctx, collection(ctx))
    content = Map.put(draft.content, "effective_from", "2026-02-01T00:00:00Z")
    store_content(draft, content)

    assert {:ok, %{action_hints: %{submit_review: false, edit_draft: false, withdraw: false}}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)

    assert {:error, _} =
             invoke(ArticleRevision, :submit_review, snapshot(draft), ctx.editor)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :withdraw,
               Map.put(snapshot(draft), :reason, :withdrawn_by_staff),
               ctx.editor
             )
  end

  @tag :embedding_index
  test "malformed stored publication dates return a revision view and fail eligibility", ctx do
    now = ~U[2026-11-26 00:00:00Z]
    fixture(%{clock: fn -> now end})
    {_collection, revision} = approved(ctx)

    for field <- ["effective_from", "expires_at"], value <- [42, "garbage"] do
      assert_stored_date(ctx, revision, field, value, :unavailable, now)
    end
  end

  @tag :embedding_index
  test "stored offset dates are compared in UTC for notices and fail eligibility", ctx do
    now = ~U[2026-11-26 00:00:00Z]
    fixture(%{clock: fn -> now end})
    {_collection, revision} = approved(ctx)

    assert_stored_date(
      ctx,
      revision,
      "effective_from",
      "2026-11-25T23:30:00-01:00",
      :not_yet_effective,
      now
    )

    assert_stored_date(ctx, revision, "expires_at", "2026-11-26T01:00:00+02:00", :expired, now)

    assert_stored_date(
      ctx,
      revision,
      "effective_from",
      "2026-11-26T01:00:00+02:00",
      :unavailable,
      now
    )

    assert_stored_date(
      ctx,
      revision,
      "expires_at",
      "2026-11-25T23:30:00-01:00",
      :unavailable,
      now
    )
  end

  defp assert_stored_date(ctx, revision, field, value, blocker, now) do
    content = Map.put(revision.content, field, value)
    store_content(revision, content)

    assert {:error, :stale_request} = Embedding.eligible_content(content, now)

    assert {:ok,
            %{
              status: :approved,
              action_hints: %{request_publish: false},
              publication_blocker: ^blocker,
              content: %{^field => ^value}
            }} = invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.reviewer)
  end

  defp store_content(revision, content) do
    assert %{num_rows: 1} =
             SQL.query!(Repo, "UPDATE article_revisions SET content = $1 WHERE id = $2", [
               content,
               Ecto.UUID.dump!(revision.id)
             ])
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "publication is separate from approval and only a reviewer can queue the locales", ctx do
    collection = collection(ctx)
    reviewed = review(ctx, draft_revision(ctx, collection))
    args = Map.put(snapshot(reviewed), :expected_current_revision_id, nil)

    assert {:error, _} = invoke(ArticleRevision, :request_publish, args, ctx.reviewer)
    assert {:ok, _} = invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)
    assert {:error, _} = invoke(ArticleRevision, :request_publish, args, ctx.editor)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :request_publish,
               %{args | expected_current_revision_id: Ash.UUIDv7.generate()},
               ctx.reviewer
             )

    assert {:ok, %{status: :publishing}} =
             invoke(ArticleRevision, :request_publish, args, ctx.reviewer)

    assert %{rows: [["af-ZA", "queued"], ["en-ZA", "queued"]]} =
             SQL.query!(
               Repo,
               "SELECT locale, state FROM article_embeddings WHERE revision_id = $1 ORDER BY locale",
               [Ecto.UUID.dump!(reviewed.id)]
             )

    assert %{rows: [[worker, 2, true, 2], [recovery, 2, true, 2]]} =
             SQL.query!(
               Repo,
               """
               SELECT worker, count(*), bool_and(args - 'embedding_id' = '{}'::jsonb),
                      count(DISTINCT args->>'embedding_id')
               FROM oban_jobs WHERE args->>'embedding_id' IN
                 (SELECT id::text FROM article_embeddings WHERE revision_id = $1)
               GROUP BY worker ORDER BY worker
               """,
               [Ecto.UUID.dump!(reviewed.id)]
             )

    assert worker == inspect(IndexArticle)
    assert recovery == "VoelgoedAi.Knowledge.Workers.RecoverIndexing"
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "dispatch follows committed reservation and only one worker per locale reaches the wire",
       ctx do
    {_collection, revision} = approved(ctx)
    [id, other] = request_index(ctx, revision)
    parent = self()

    wire = fn request ->
      send(parent, {:wire, self(), reservation_rows(id), request.body})

      receive do
        :respond -> EmbeddingTransport.fixture_wire(request)
      end
    end

    fixture(%{
      wire: wire,
      after_claim: fn _ -> send(parent, :probe_claim) end,
      after_dispatch: fn _ -> send(parent, :probe_dispatch) end,
      consume_dispatch: fn take ->
        results = [Task.async(take), Task.async(take)] |> Task.await_many()
        send(parent, {:fence_results, Enum.map(results, &elem(&1, 0)) |> Enum.sort()})
        Enum.find(results, &match?({:ok, _, _, _}, &1))
      end
    })

    task = Task.async(fn -> Embedding.index(id) end)

    assert_receive :probe_claim, 5_000
    assert_receive {:fence_results, [:error, :ok]}, 5_000
    assert_receive :probe_dispatch, 5_000
    assert_receive {:wire, wire_pid, [["running", true, "reserved", 81_920, nil]], body}, 7_000
    body = if is_map(body), do: body, else: Jason.decode!(IO.iodata_to_binary(body))
    assert body["model"] == "text-embedding-3-small"
    assert body["dimensions"] == 1536
    assert byte_size(Jason.encode!(body["input"])) > 0
    refute Jason.encode!(body["input"]) =~ "synthetic-faq-v1"
    assert :ok = Embedding.index(id)
    refute_receive {:wire, _, _, _}, 50

    send(wire_pid, :respond)
    assert :ok = Task.await(task)
    assert [["succeeded", true, "settled", 81_920, 8]] = reservation_rows(id)

    assert {:error, :proof_rolled_back} =
             Repo.transact(fn ->
               assert {:error,
                       %Postgrex.Error{
                         postgres: %{
                           code: :unique_violation,
                           constraint: "usage_ledger_entries_entry_key_index"
                         }
                       }} =
                        SQL.query(
                          Repo,
                          """
                          INSERT INTO usage_ledger_entries
                          SELECT (jsonb_populate_record(NULL::usage_ledger_entries,
                            to_jsonb(l) || jsonb_build_object('id', uuidv7()))).*
                          FROM usage_ledger_entries l
                          JOIN inference_runs i ON i.id = l.inference_run_id WHERE i.article_embedding_id = $1
                          """,
                          [Ecto.UUID.dump!(id)]
                        )

               {:error, :proof_rolled_back}
             end)

    assert [["ready", 1536]] = vector_rows(id)

    fixture(%{})
    assert :ok = Oban.Testing.perform_job(IndexArticle, %{"embedding_id" => other}, repo: Repo)
    assert [["ready", 1536]] = vector_rows(other)

    assert {:ok, %{status: :publishing}} =
             invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.reviewer)

    assert {:ok, %{current_revision_id: nil}} =
             invoke(Article, :read_article, %{id: revision.article_id}, ctx.reviewer)
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "article wire failures enter the adapter once and settle only correlated usage", ctx do
    {_collection, revision} = approved(ctx)
    parent = self()

    for {fault, action, state, reservation, amount} <- [
          {:service_unavailable, :request_publish, "unknown", "unknown", nil},
          {:timeout, :retry_publication, "unknown", "unknown", nil},
          {:malformed_json, :retry_publication, "unknown", "unknown", nil},
          {:invalid_vector, :retry_publication, "failed", "settled", 8}
        ] do
      [id, sibling] = request_index(ctx, revision, action)

      wire = fn request ->
        send(parent, {:wire_fault, fault, request.options[:max_retries]})

        case fault do
          :service_unavailable ->
            {request,
             Req.Response.new(
               status: 503,
               headers: [{"retry-after", "0"}],
               body: %{"error" => %{"message" => "fixture"}}
             )}

          :timeout ->
            {request, %Req.TransportError{reason: :timeout}}

          :malformed_json ->
            {request,
             Req.Response.new(
               status: 200,
               headers: [{"content-type", "application/json"}],
               body: "{"
             )}

          :invalid_vector ->
            {request, reply} = response(request, 3, :zero)

            {request,
             reply
             |> Req.Response.put_header("content-type", "application/json")
             |> Map.put(:body, Jason.encode!(reply.body))}
        end
      end

      fixture(%{wire: wire})
      assert :ok = Embedding.index(id)
      assert_received {:wire_fault, ^fault, limit}
      refute_received {:wire_fault, ^fault, _}
      assert limit == 0
      assert [[^state, true, ^reservation, 81_920, ^amount]] = reservation_rows(id)

      case amount do
        nil -> assert [] == ledger_rows(id)
        8 -> assert [[_, "settlement", "settlement", nil, 8, 3, nil]] = ledger_rows(id)
      end

      assert [[_, nil]] = vector_rows(id)
      assert [["invalidated", nil]] = vector_rows(sibling)
      assert :ok = Embedding.index(id)
      assert :ok = Embedding.index(sibling)
      refute_received {:wire_fault, ^fault, _}
    end
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "outstanding spend crosses UTC rollover and a late result settles to the origin window",
       ctx do
    # Load ReqLLM's local catalog before timing the worker's arrival at the fake adapter.
    model = "#{EmbeddingProfile.provider()}:#{EmbeddingProfile.model()}"
    assert {:ok, _} = ReqLLM.Embedding.validate_model(model)

    {_collection, revision} = approved(ctx)
    parent = self()
    origin = ~U[2027-01-31 23:59:50.000000Z]
    {:ok, clock} = Agent.start_link(fn -> origin end)

    fixture(%{
      clock: fn -> Agent.get(clock, & &1) end,
      day_cap: 81_920,
      month_cap: 81_920,
      wire: fn request ->
        send(parent, {:wire_rollover, self()})

        receive do
          :complete -> EmbeddingTransport.fixture_wire(request)
        end
      end
    })

    [id, other] = request_index(ctx, revision)
    task = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:wire_rollover, wire}, 3_000
    Agent.update(clock, fn _ -> DateTime.add(origin, 15) end)

    assert :ok = Embedding.index(other)
    refute_receive {:wire_rollover, _}, 50
    assert [] == reservation_rows(other)
    assert [["failed", nil]] = vector_rows(other)

    send(wire, :complete)
    assert :ok = Task.await(task)
    assert [["succeeded", true, "settled", 81_920, 8]] = reservation_rows(id)
    assert [["invalidated", nil]] = vector_rows(id)

    assert [["day", ~D[2027-01-31], 8], ["month", ~D[2027-01-01], 8]] =
             SQL.query!(
               Repo,
               "SELECT kind, window_start, settled_nano_usd FROM spend_windows WHERE settled_nano_usd > 0 AND window_start IN ('2027-01-31','2027-01-01','2027-02-01') ORDER BY kind"
             ).rows
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "disable fences a pre-dispatch claim and revoke cancels the generation", ctx do
    {collection, revision} = approved(ctx)
    [id, sibling] = request_index(ctx, revision)
    parent = self()

    fixture(%{
      after_claim: fn _ ->
        send(parent, {:claimed, self()})

        receive do
          :continue -> :ok
        end
      end,
      wire: fn request ->
        send(parent, :stale_wire)
        EmbeddingTransport.fixture_wire(request)
      end
    })

    task = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:claimed, worker}, 3_000
    assert {:ok, _} = invoke(KnowledgeCollection, :disable, %{id: collection.id}, ctx.admin)
    assert {:ok, _} = invoke(KnowledgeCollection, :enable, %{id: collection.id}, ctx.admin)
    send(worker, :continue)
    assert :ok = Task.await(task)
    refute_receive :stale_wire, 50
    assert [["rejected", false, "released", 81_920, nil]] = reservation_rows(id)
    assert [["invalidated", nil]] = vector_rows(sibling)

    args = Map.put(snapshot(revision), :reason, :obsolete)
    assert {:ok, %{status: :revoked}} = invoke(ArticleRevision, :revoke, args, ctx.reviewer)
    assert :ok = Embedding.index(sibling)
    refute_receive :stale_wire, 50
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "revoke clears ready and queued vectors and the shape check rejects unusable vectors",
       ctx do
    {_collection, revision} = approved(ctx)
    [id, sibling] = request_index(ctx, revision)
    parent = self()

    fixture(%{
      wire: fn request ->
        send(parent, :wire)
        EmbeddingTransport.fixture_wire(request)
      end
    })

    assert :ok = Embedding.index(id)
    assert_receive :wire
    assert [["ready", 1536]] = vector_rows(id)
    assert [["queued", nil]] = vector_rows(sibling)

    # Retrieval reads embedding rows directly, so the stored shape must hold
    # without relying on application checks.
    for sql <- [
          "UPDATE article_embeddings SET vector = NULL WHERE id = $1",
          "UPDATE article_embeddings SET vector = array_fill(0::real, ARRAY[1536])::vector WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{constraint: "article_embeddings_shape"}}} =
               SQL.query(Repo, sql, [Ecto.UUID.dump!(id)])
    end

    # Worker rechecks are a second fence; revocation itself must clear the rows.
    args = Map.put(snapshot(revision), :reason, :obsolete)
    assert {:ok, %{status: :revoked}} = invoke(ArticleRevision, :revoke, args, ctx.reviewer)
    assert [["invalidated", nil]] = vector_rows(id)
    assert [["invalidated", nil]] = vector_rows(sibling)
    assert :ok = Embedding.index(sibling)
    refute_receive :wire, 50
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "an early recovery run waits for the queued deadline", ctx do
    {_collection, revision} = approved(ctx)
    [id, _sibling] = request_index(ctx, revision)
    fixture(%{})

    assert {:snooze, wait} = Embedding.recover(id)
    assert wait in 1..60
    assert [["queued", nil]] = vector_rows(id)
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "archive clears ready vectors of a publishing revision", ctx do
    {_collection, revision} = approved(ctx)
    [id, sibling] = request_index(ctx, revision)
    fixture(%{})
    assert :ok = Embedding.index(id)
    assert [["ready", 1536]] = vector_rows(id)

    assert {:ok, %{status: :archived}} =
             invoke(
               Article,
               :archive,
               %{id: revision.article_id, reason: :obsolete},
               ctx.reviewer
             )

    assert [["invalidated", nil]] = vector_rows(id)
    assert [["invalidated", nil]] = vector_rows(sibling)
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "missing gate, price, cap or reservation storage denies before the adapter", ctx do
    {_collection, revision} = approved(ctx)
    parent = self()
    [first, _] = request_index(ctx, revision)

    wire = fn request ->
      send(parent, :unexpected_wire)
      EmbeddingTransport.fixture_wire(request)
    end

    fixture(%{enabled: false, wire: wire})
    assert :ok = Embedding.index(first)
    assert [] == reservation_rows(first)

    for settings <- [%{price: nil}, %{day_cap: nil}, %{month_cap: 81_919}] do
      fixture(%{wire: wire})
      [id, _] = request_index(ctx, revision, :retry_publication)
      fixture(Map.put(settings, :wire, wire))
      assert :ok = Embedding.index(id)
      assert [] == reservation_rows(id)
      assert [["failed", nil]] = vector_rows(id)
    end

    fixture(%{wire: wire})
    [id, _] = request_index(ctx, revision, :retry_publication)

    SQL.query!(Repo, """
    CREATE FUNCTION fail_b1_reserve() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 'synthetic reserve commit failure'; END; $$
    """)

    try do
      SQL.query!(Repo, """
      CREATE CONSTRAINT TRIGGER fail_b1_reserve AFTER INSERT ON usage_reservations
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fail_b1_reserve()
      """)

      assert {:error, :indexing_storage} = Embedding.index(id)
      assert [] == reservation_rows(id)
      refute_receive :unexpected_wire, 50
    after
      SQL.query!(Repo, "DROP TRIGGER IF EXISTS fail_b1_reserve ON usage_reservations")
      SQL.query!(Repo, "DROP FUNCTION fail_b1_reserve()")
    end
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "committed dispatch risk survives recovery and an authorized closure gets one late correction",
       ctx do
    {_collection, revision} = approved(ctx)
    parent = self()
    origin = ~U[2027-01-31 23:59:50.000000Z]
    {:ok, clock} = Agent.start_link(fn -> origin end)

    fixture(%{
      clock: fn -> Agent.get(clock, & &1) end,
      day_cap: 81_920,
      month_cap: 81_920,
      before_settlement: fn attempt ->
        if self() != parent do
          send(parent, {:settlement, self(), attempt.id})

          receive do
            :complete -> :ok
          after
            8_000 -> exit(:article_settlement_fixture_timeout)
          end
        end
      end
    })

    [id, _] = request_index(ctx, revision)
    task = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:settlement, worker, attempt_id}, 5_000
    Agent.update(clock, fn _ -> DateTime.add(origin, 65) end)
    args = %{id: attempt_id, reason: :conservative_closure}

    {ceiling, ceiling_id} =
      try do
        assert :ok = Embedding.recover(id)
        assert [["unknown", true, "unknown", 81_920, nil]] = reservation_rows(id)
        assert :ok = Embedding.index(id)

        [candidate, _] = request_index(ctx, revision, :retry_publication)
        assert :ok = Embedding.index(candidate)
        assert [] == reservation_rows(candidate)

        assert {:error, _} = invoke(InferenceRun, :close_unknown_embedding, args, ctx.reviewer)

        stale_session = %{ctx.admin | generation: ctx.admin.generation - 1}

        assert {:error, _} =
                 financial_decision(InferenceRun, :close_unknown_embedding, args, stale_session)

        reject_financial_audit(:close_unknown_inference, fn ->
          assert {:error, _} =
                   financial_decision(InferenceRun, :close_unknown_embedding, args, ctx.admin)

          assert [["unknown", true, "unknown", 81_920, nil]] = reservation_rows(id)
          assert [] == ledger_rows(id)
          assert [] == origin_windows()
        end)

        for _ <- 1..2 do
          assert {:ok, %{state: :abandoned}} =
                   financial_decision(InferenceRun, :close_unknown_embedding, args, ctx.admin)
        end

        assert [["abandoned", true, "conservatively_settled", 81_920, 81_920]] =
                 reservation_rows(id)

        assert [[ceiling_id, "settlement", "settlement", nil, 81_920, nil, admin]] =
                 ceiling = ledger_rows(id)

        assert admin == ctx.admin.id

        assert [[admin]] ==
                 SQL.query!(
                   Repo,
                   """
                   SELECT actor_staff_id::text FROM audit_events
                   WHERE event = 'close_unknown_inference' AND actor_staff_id = $1
                   """,
                   [Ecto.UUID.dump!(admin)]
                 ).rows

        assert [["day", ~D[2027-01-31], 81_920], ["month", ~D[2027-01-01], 81_920]] ==
                 origin_windows()

        {ceiling, ceiling_id}
      after
        send(worker, :complete)
      end

    assert :ok = Task.await(task)

    assert correction =
             [_, "correction", "late-usage", ^ceiling_id, -81_912, 3, nil] =
             Enum.at(ledger_rows(id), 1)

    assert ledger_rows(id) == ceiling ++ [correction]
    assert Enum.sum(Enum.map(ledger_rows(id), &Enum.at(&1, 4))) == 8

    assert {:ok, %{state: :abandoned}} =
             financial_decision(InferenceRun, :close_unknown_embedding, args, ctx.admin)

    assert :ok = Embedding.recover(id)
    assert :ok = Embedding.index(id)
    assert ledger_rows(id) == ceiling ++ [correction]
    assert [["failed", nil]] = vector_rows(id)
    assert [["day", ~D[2027-01-31], 8], ["month", ~D[2027-01-01], 8]] == origin_windows()
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "article settlement wins over a later qualified close", ctx do
    {_collection, revision} = approved(ctx)
    owner = self()
    origin = ~U[2027-01-31 23:59:50Z]
    {:ok, clock} = Agent.start_link(fn -> origin end)

    fixture(%{
      clock: fn -> Agent.get(clock, & &1) end,
      before_settlement: fn attempt ->
        send(owner, {:settlement, self(), attempt.id})

        receive do
          :settle -> :ok
        after
          5_000 -> exit(:settlement_barrier_timeout)
        end
      end
    })

    [id, _] = request_index(ctx, revision)
    worker = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:settlement, pid, attempt_id}, 5_000

    Agent.update(clock, fn _ -> DateTime.add(origin, 65) end)
    assert :ok = Embedding.recover(id)
    send(pid, :settle)
    assert :ok = Task.await(worker)
    args = %{id: attempt_id, reason: :conservative_closure}

    assert {:error, _} =
             financial_decision(InferenceRun, :close_unknown_embedding, args, ctx.admin)

    assert [["succeeded", true, "settled", 81_920, 8]] = reservation_rows(id)
    assert [[_, "settlement", "settlement", nil, 8, 3, nil]] = ledger_rows(id)
    assert [["failed", nil]] = vector_rows(id)
  end

  for window <- ["day", "month"] do
    @tag :requires_pgvector
    @tag :embedding_index
    @tag origin_window: window
    test "late usage overflow in the origin #{window} survives rollover and blocks reset", ctx do
      alias VoelgoedAi.Governance.{AutomationControl, FinancialControl}

      {_collection, revision} = approved(ctx)
      owner = self()
      origin = ~U[2027-01-31 23:59:50Z]
      {:ok, clock} = Agent.start_link(fn -> origin end)

      fixture(%{
        clock: fn -> Agent.get(clock, & &1) end,
        wire: &response(&1, 40_000),
        before_settlement: fn attempt ->
          send(owner, {:about_to_settle, self(), attempt.id})

          receive do
            :settle -> :ok
          after
            5_000 -> exit(:settlement_barrier_timeout)
          end
        end
      })

      [id, _] = request_index(ctx, revision)
      worker = Task.async(fn -> Embedding.index(id) end)
      assert_receive {:about_to_settle, pid, attempt_id}, 5_000
      Agent.update(clock, fn _ -> DateTime.add(origin, 65) end)
      assert :ok = Embedding.recover(id)
      close = %{id: attempt_id, reason: :conservative_closure}

      assert {:error, _} =
               FinancialControl.with_decision(
                 :close_unknown_embedding,
                 ctx.admin.id,
                 revision.id,
                 fn ->
                   invoke(InferenceRun, :close_unknown_embedding, close, ctx.admin)
                 end
               )

      assert {:ok, %{state: :abandoned}} =
               financial_decision(InferenceRun, :close_unknown_embedding, close, ctx.admin)

      date = if ctx.origin_window == "day", do: ~D[2027-01-31], else: ~D[2027-01-01]

      update_window = fn amount ->
        SQL.query!(
          Repo,
          "UPDATE spend_windows SET settled_nano_usd = $1 WHERE kind = $2 AND window_start = $3",
          [amount, ctx.origin_window, date]
        )
      end

      update_window.(9_223_372_036_854_775_807)

      first_occurrence =
        try do
          send(pid, :settle)
          assert :ok = Task.await(worker)

          assert [["abandoned", true, "conservatively_settled", 81_920, 81_920]] =
                   reservation_rows(id)

          assert [_] = ledger_rows(id)

          assert %{rows: [[40_000, nil]]} =
                   SQL.query!(
                     Repo,
                     """
                     SELECT (overflow_evidence->>'input_tokens')::bigint, overflow_resolved_at
                     FROM inference_runs WHERE id = $1
                     """,
                     [Ecto.UUID.dump!(attempt_id)]
                   )

          assert %{rows: [[true, occurrence]]} =
                   SQL.query!(
                     Repo,
                     "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
                   )

          reset = %{lane: :embedding, occurrence: occurrence}

          assert {:error, _} =
                   financial_decision(
                     AutomationControl,
                     :reset_financial_inhibit,
                     reset,
                     ctx.admin
                   )

          assert :ok = Embedding.recover(id)
          assert [_] = ledger_rows(id)

          assert %{rows: [[^occurrence]]} =
                   SQL.query!(
                     Repo,
                     "SELECT embedding_inhibit_occurrence::text FROM automation_controls"
                   )

          occurrence
        after
          update_window.(81_920)
        end

      assert :ok = Embedding.recover(id)
      assert [_, [_, "correction", "late-usage", _, 18_080, 40_000, nil]] = ledger_rows(id)
      assert :ok = Embedding.recover(id)
      assert [_, _] = ledger_rows(id)

      assert [["abandoned", true, "conservatively_settled", 81_920, 81_920]] =
               reservation_rows(id)

      assert [["day", ~D[2027-01-31], 100_000], ["month", ~D[2027-01-01], 100_000]] ==
               origin_windows()

      assert [["failed", nil]] = vector_rows(id)

      assert %{rows: [[true, occurrence]]} =
               SQL.query!(
                 Repo,
                 "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
               )

      reset = %{lane: :embedding, occurrence: occurrence}
      assert {:error, _} = invoke(AutomationControl, :reset_financial_inhibit, reset, ctx.admin)
      refute occurrence == first_occurrence
      stale = %{reset | occurrence: first_occurrence}

      assert {:error, _} =
               financial_decision(AutomationControl, :reset_financial_inhibit, stale, ctx.admin)

      reject_financial_audit(:reset_embedding_inhibit, fn ->
        assert {:error, _} =
                 financial_decision(AutomationControl, :reset_financial_inhibit, reset, ctx.admin)

        assert %{rows: [[true, ^occurrence]]} =
                 SQL.query!(
                   Repo,
                   "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
                 )
      end)

      set_legacy_generation_inhibit()

      assert {:error, _} =
               financial_decision(AutomationControl, :reset_financial_inhibit, reset, ctx.admin)

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT count(*) FROM audit_events
                 WHERE event = 'reset_embedding_inhibit' AND correlation_id = $1
                 """,
                 [Ecto.UUID.dump!(occurrence)]
               )

      SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibited = false")

      assert {:ok, ^reset} =
               financial_decision(AutomationControl, :reset_financial_inhibit, reset, ctx.admin)

      assert {:error, _} =
               financial_decision(AutomationControl, :reset_financial_inhibit, reset, ctx.admin)

      assert %{rows: [[1]]} =
               SQL.query!(
                 Repo,
                 """
                 WITH removed AS (
                   DELETE FROM audit_events WHERE event = 'reset_embedding_inhibit' AND correlation_id = $1 RETURNING id
                 ) SELECT count(*) FROM removed
                 """,
                 [Ecto.UUID.dump!(occurrence)]
               )
    end
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "a lost process releases only a pre-dispatch reservation and holds after the fence", ctx do
    {_collection, revision} = approved(ctx)
    now = ~U[2027-01-31 23:58:00.000000Z]
    {:ok, clock} = Agent.start_link(fn -> now end)
    parent = self()

    base = %{
      clock: fn -> Agent.get(clock, & &1) end,
      wire: fn request ->
        send(parent, :wire_hit)
        EmbeddingTransport.fixture_wire(request)
      end
    }

    fixture(base)

    for {stage, action, attempt_state, reserve_state, dispatched} <- [
          {:after_claim, :request_publish, "rejected", "released", false},
          {:after_dispatch, :retry_publication, "unknown", "unknown", true},
          {:before_settlement, :retry_publication, "unknown", "unknown", true}
        ] do
      [id, _] = request_index(ctx, revision, action)
      fixture(Map.put(base, stage, fn _ -> exit(:synthetic_crash) end))
      {pid, ref} = spawn_monitor(fn -> Embedding.index(id) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :synthetic_crash}, 5_000
      Agent.update(clock, &DateTime.add(&1, 61))
      assert :ok = Embedding.recover(id)
      assert :ok = Embedding.recover(id)
      assert :ok = Embedding.index(id)
      assert [[^attempt_state, ^dispatched, ^reserve_state, 81_920, nil]] = reservation_rows(id)
      assert [] == ledger_rows(id)
      if stage == :before_settlement, do: assert_receive(:wire_hit)
      refute_receive :wire_hit, 50
    end
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "an inhibit committed after the reservation stops dispatch and releases the hold",
       ctx do
    {_collection, revision} = approved(ctx)
    parent = self()

    fixture(%{
      wire: fn request ->
        send(parent, :wire_hit)
        EmbeddingTransport.fixture_wire(request)
      end,
      after_claim: fn _ ->
        SQL.query!(Repo, "UPDATE automation_controls SET embedding_inhibited = true")
        :ok
      end
    })

    [id, _] = request_index(ctx, revision)
    assert :ok = Embedding.index(id)
    assert [["rejected", false, "released", 81_920, nil]] = reservation_rows(id)
    assert [] == ledger_rows(id)
    assert [["failed", nil]] = vector_rows(id)
    refute_receive :wire_hit, 50
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "a cheaper fixture price cannot reserve the approved embedding request", ctx do
    {_collection, revision} = approved(ctx)
    [id, _] = request_index(ctx, revision)
    owner = self()

    fixture(%{
      price: %{
        version: "embedding-fixture-v1",
        rate_nano_usd: 1,
        token_unit: 2,
        max_input_tokens: 32_768
      },
      wire: fn request ->
        send(owner, :wire)
        EmbeddingTransport.fixture_wire(request)
      end
    })

    assert :ok = Embedding.index(id)
    assert [] == reservation_rows(id)
    refute_received :wire
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "article wire entry denies cap drift after the marker and preserves the hold", ctx do
    {_collection, revision} = approved(ctx)
    [id, _] = request_index(ctx, revision)
    owner = self()

    wire = fn request ->
      send(owner, :wire)
      EmbeddingTransport.fixture_wire(request)
    end

    fixture(%{
      wire: wire,
      after_dispatch: fn _ -> fixture(%{wire: wire, month_cap: 81_919}) end
    })

    assert :ok = Embedding.index(id)
    assert [["unknown", true, "unknown", 81_920, nil]] = reservation_rows(id)
    assert [] == ledger_rows(id)
    refute_received :wire
  end

  @tag :requires_pgvector
  @tag :embedding_index
  @tag :frozen_embedding_dispatch
  test "article wire entry retains its admitted cap after the current cap increases", ctx do
    {_collection, revision} = approved(ctx)
    clock = fn -> ~U[2034-05-01 00:00:00Z] end
    owner = self()

    wire = fn request ->
      send(owner, :wire)
      EmbeddingTransport.fixture_wire(request)
    end

    fixture(%{clock: clock})
    [id, sibling] = request_index(ctx, revision)

    fixture(%{
      clock: clock,
      wire: wire,
      day_cap: 81_920,
      month_cap: 81_920,
      after_dispatch: fn _ ->
        fixture(%{clock: clock, wire: wire})
        assert :ok = Embedding.index(sibling)
        assert [["succeeded", true, "settled", 81_920, 8]] = reservation_rows(sibling)
      end
    })

    assert :ok = Embedding.index(id)
    assert_received :wire
    refute_received :wire
    assert [["unknown", true, "unknown", 81_920, nil]] = reservation_rows(id)
    assert [] == ledger_rows(id)
  end

  defp set_legacy_generation_inhibit do
    assert %{rows: [[false, nil, nil]]} =
             SQL.query!(Repo, """
             SELECT generation_inhibited, generation_inhibit_occurrence, generation_inhibit_budget
             FROM automation_controls
             """)

    SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibited = true")

    on_exit(fn ->
      SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibited = false")
    end)
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "article wire entry denies a legacy generation inhibit after the marker", ctx do
    {_collection, revision} = approved(ctx)
    [id, _] = request_index(ctx, revision)
    owner = self()

    fixture(%{
      wire: fn request ->
        send(owner, :wire)
        EmbeddingTransport.fixture_wire(request)
      end,
      after_dispatch: fn _ ->
        set_legacy_generation_inhibit()
      end
    })

    assert :ok = Embedding.index(id)
    assert [["unknown", true, "unknown", 81_920, nil]] = reservation_rows(id)
    assert [] == ledger_rows(id)
    assert [["failed", nil]] = vector_rows(id)
    refute_received :wire
  end

  @tag :reset_authority
  @tag :requires_pgvector
  @tag :embedding_index
  test "a later fixture budget cannot reset an article embedding overage", ctx do
    alias VoelgoedAi.Governance.AutomationControl

    origin = ~U[2028-01-31 23:59:50Z]
    {_collection, revision} = approved(ctx)

    fixture(%{
      clock: fn -> origin end,
      day_cap: 81_920,
      month_cap: 81_920,
      wire: &response(&1, 40_000)
    })

    [id, _] = request_index(ctx, revision)
    assert :ok = Embedding.index(id)
    assert [["succeeded", true, "settled", 81_920, 100_000]] = reservation_rows(id)

    assert [[true, occurrence]] =
             SQL.query!(
               Repo,
               "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
             ).rows

    reset = %{lane: :embedding, occurrence: occurrence}

    decide = fn ->
      VoelgoedAi.SupportFixtures.financial_decision(
        AutomationControl,
        :reset_financial_inhibit,
        reset,
        ctx.admin
      )
    end

    assert {:error, _} = decide.()
    fixture(%{clock: fn -> origin end, day_cap: 10_000_000, month_cap: 100_000_000})
    assert {:error, _} = decide.()

    assert [[true, ^occurrence]] =
             SQL.query!(
               Repo,
               "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
             ).rows

    assert [[0]] =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM audit_events WHERE event = 'reset_embedding_inhibit' AND correlation_id = $1",
               [Ecto.UUID.dump!(occurrence)]
             ).rows

    fixture(%{clock: fn -> DateTime.add(origin, 15) end, day_cap: 1, month_cap: 1})
    assert {:ok, ^reset} = decide.()
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "settlement uses frozen trusted usage and inhibits admission on excess", ctx do
    {_collection, revision} = approved(ctx)
    parent = self()

    wire = fn request ->
      send(parent, {:pricing_wire, self()})

      receive do
        :complete -> response(request, 40_000)
      end
    end

    fixture(%{wire: wire})
    [id, sibling] = request_index(ctx, revision)
    task = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:pricing_wire, wire_pid}, 8_000

    fixture(%{
      wire: wire,
      price: %{
        version: "fixture-change",
        rate_nano_usd: 99,
        token_unit: 1,
        max_input_tokens: 32_768
      }
    })

    send(wire_pid, :complete)
    assert :ok = Task.await(task)
    assert [["succeeded", true, "settled", 81_920, 100_000]] = reservation_rows(id)
    assert [[_, "settlement", "settlement", nil, 100_000, 40_000, nil]] = ledger_rows(id)

    assert %{rows: [["embedding-fixture-v1", 5, 2, "over_reserve"]]} =
             SQL.query!(
               Repo,
               """
               SELECT price_version, rate_nano_usd, token_unit, reason_code FROM usage_ledger_entries
               WHERE inference_run_id IN (SELECT id FROM inference_runs WHERE article_embedding_id = $1)
               """,
               [Ecto.UUID.dump!(id)]
             )

    assert :ok = Embedding.index(id)
    assert :ok = Embedding.index(sibling)
    assert [] == reservation_rows(sibling)
    refute_receive {:pricing_wire, _}, 50
  end

  for failure <- [:raise, :exit] do
    @tag :requires_pgvector
    @tag :embedding_index
    @tag decoder_failure: failure
    test "trusted embedding usage survives a decoder #{failure}", ctx do
      {_collection, revision} = approved(ctx)

      fixture(%{
        wire: fn request ->
          {request, response} = EmbeddingTransport.fixture_wire(request)

          request =
            Req.Request.prepend_response_steps(request,
              synthetic_decoder_failure: fn _ ->
                case ctx.decoder_failure do
                  :raise -> raise "synthetic decoder failure"
                  :exit -> exit(:synthetic_decoder_failure)
                end
              end
            )

          {request, response}
        end
      })

      [id, _] = request_index(ctx, revision)
      assert :ok = Embedding.index(id)
      assert [["failed", true, "settled", 81_920, 8]] = reservation_rows(id)
      assert [[_, "settlement", "settlement", nil, 8, 3, nil]] = ledger_rows(id)
      assert [["failed", nil]] = vector_rows(id)
    end
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "malformed usage or cost overflow holds risk and invalid vectors charge known usage",
       ctx do
    {_collection, revision} = approved(ctx)

    for {tokens, vector, action, attempt_state, reservation_state, actual} <- [
          {3.0, :valid, :request_publish, "unknown", "unknown", nil},
          {3, :zero, :retry_publication, "failed", "settled", 8},
          {9_223_372_036_854_775_807, :valid, :retry_publication, "unknown", "unknown", nil}
        ] do
      [id, _] = request_index(ctx, revision, action)
      fixture(%{wire: fn request -> response(request, tokens, vector) end})
      assert :ok = Embedding.index(id)
      assert [[^attempt_state, true, ^reservation_state, 81_920, ^actual]] = reservation_rows(id)
      assert [["failed", nil]] = vector_rows(id)
    end

    assert %{rows: [[true]]} =
             SQL.query!(Repo, "SELECT embedding_inhibited FROM automation_controls")
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "the control lock precedes variant and reservation writes at the spend cap", ctx do
    {_collection, revision} = approved(ctx)
    [id, sibling] = request_index(ctx, revision)
    parent = self()

    fixture(%{
      day_cap: 81_920,
      month_cap: 81_920,
      after_claim: fn _ ->
        send(parent, {:held, self()})

        receive do
          :continue -> :ok
        end
      end
    })

    assert {:ok, worker} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SELECT id FROM automation_controls FOR UPDATE")
               worker = blocked_task(fn -> Embedding.index(id) end)

               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          "SELECT id FROM article_embeddings WHERE id = $1 FOR UPDATE NOWAIT",
                          [Ecto.UUID.dump!(id)]
                        )

               {:ok, worker}
             end)

    assert_receive {:held, worker_pid}, 5_000
    assert :ok = Embedding.index(sibling)
    assert [] == reservation_rows(sibling)
    send(worker_pid, :continue)
    assert :ok = Task.await(worker)
    assert [["rejected", false, "released", 81_920, nil]] = reservation_rows(id)
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "archiving during the wire call preserves settlement and prevents a ready write", ctx do
    {_collection, revision} = approved(ctx)
    [id, sibling] = request_index(ctx, revision)
    parent = self()

    fixture(%{
      before_settlement: fn _ ->
        send(parent, {:wire_complete, self()})

        receive do
          :settle -> :ok
        end
      end
    })

    task = Task.async(fn -> Embedding.index(id) end)
    assert_receive {:wire_complete, worker}, 8_000

    assert {:ok, %{status: :archived}} =
             invoke(
               Article,
               :archive,
               %{id: revision.article_id, reason: :obsolete},
               ctx.reviewer
             )

    send(worker, :settle)
    assert :ok = Task.await(task)
    assert [["succeeded", true, "settled", 81_920, 8]] = reservation_rows(id)
    assert [["invalidated", nil]] = vector_rows(id)
    assert [["invalidated", nil]] = vector_rows(sibling)
  end

  test "collection lifecycle requires live ADMIN authority and advances epochs", ctx do
    args = %{slug: ctx.slug, name: "Synthetic FAQs", audience: :public}

    for actor <- [nil, ctx.editor, %{ctx.admin | generation: ctx.admin.generation + 1}] do
      assert {:error, _} = invoke(KnowledgeCollection, :create, args, actor)
    end

    assert {:ok, %{status: :disabled} = row} =
             invoke(KnowledgeCollection, :create, args, ctx.admin)

    for {action, status} <- [enable: :active, disable: :disabled, retire: :retired] do
      assert {:error, _} = invoke(KnowledgeCollection, action, %{id: row.id}, ctx.editor)

      assert {:ok, %{status: ^status}} =
               invoke(KnowledgeCollection, action, %{id: row.id}, ctx.admin)
    end

    assert {:error, _} = invoke(KnowledgeCollection, :enable, %{id: row.id}, ctx.admin)

    assert {:ok, %{security_epoch: 3}} =
             invoke(KnowledgeCollection, :read_collection, %{id: row.id}, ctx.admin)
  end

  test "review guards the exact snapshot and rollback keeps the prior state", ctx do
    collection = collection(ctx)
    revision = draft_revision(ctx, collection)
    submitted = review(ctx, revision)
    args = snapshot(submitted)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(submitted), :content, payload()),
               ctx.editor
             )

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :approve,
               attest(%{args | expected_hash: String.duplicate("0", 64)}),
               ctx.reviewer
             )

    assert {:ok, %{status: :draft} = changed} =
             invoke(
               ArticleRevision,
               :request_changes,
               Map.put(snapshot(submitted), :reason, :source_correction),
               ctx.reviewer
             )

    submitted = review(ctx, changed)
    Process.put({VoelgoedAi.Knowledge.Editorial, :reject_audit}, :approve)

    assert {:error, _} =
             invoke(ArticleRevision, :approve, attest(snapshot(submitted)), ctx.reviewer)

    Process.delete({VoelgoedAi.Knowledge.Editorial, :reject_audit})

    assert {:ok, %{status: :in_review}} =
             invoke(ArticleRevision, :read_revision, %{id: submitted.id}, ctx.reviewer)

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'article_revision_id' = $1", [
        revision.id
      ])
    end)

    jobs = SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows

    assert {:ok, %{status: :approved, approved_by_id: id}} =
             invoke(ArticleRevision, :approve, attest(snapshot(submitted)), ctx.reviewer)

    assert id == ctx.reviewer.id
    assert SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows == jobs
  end

  test "editorial actions deny unrelated, unscoped, stale and direct storage actors", ctx do
    collection = collection(ctx)
    rev = draft_revision(ctx, collection)
    read = %{id: rev.id}

    assert {:ok, second} =
             invoke(
               ArticleRevision,
               :create_draft,
               %{article_id: rev.article_id, content: payload()},
               ctx.editor
             )

    reviewed = review(ctx, second)

    for {resource, action, args, wrong_role} <- [
          {Article, :create_draft, draft_args(ctx, collection), ctx.reviewer},
          {ArticleRevision, :create_draft, %{article_id: rev.article_id, content: payload()},
           ctx.reviewer},
          {ArticleRevision, :edit_draft, Map.put(snapshot(rev), :content, payload()),
           ctx.reviewer},
          {ArticleRevision, :submit_review, snapshot(rev), ctx.reviewer},
          {ArticleRevision, :request_changes,
           Map.put(snapshot(reviewed), :reason, :source_correction), ctx.editor},
          {ArticleRevision, :approve, Map.put(attest(snapshot(reviewed)), :self_approval, true),
           ctx.editor},
          {ArticleRevision, :withdraw, Map.put(snapshot(rev), :reason, :withdrawn_by_staff), nil},
          {Article, :archive, %{id: rev.article_id, reason: :obsolete}, ctx.editor},
          {ArticleRevision, :read_revision, read, nil}
        ] do
      for actor <- [
            nil,
            ctx.admin,
            wrong_role,
            %{ctx.editor | generation: ctx.editor.generation + 1},
            %{ctx.reviewer | generation: ctx.reviewer.generation + 1},
            struct(VoelgoedAi.Support.ActionScope.Processing,
              action: action,
              resource: resource,
              target: rev.id,
              inbox: :fixture
            )
          ] do
        assert {:error, _} = invoke(resource, action, args, actor)
      end

      Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope)

      for actor <- [ctx.editor, ctx.reviewer],
          do: assert({:error, _} = invoke(resource, action, args, actor))

      scope(ctx, collection)
    end

    assert {:error, _} =
             Repo.transact(fn ->
               ArticleRevision
               |> Ash.Query.for_read(:storage_row, read,
                 actor: %VoelgoedAi.Knowledge.Storage{ref: make_ref()}
               )
               |> Ash.read_one()
             end)
  end

  test "the current pointer cannot reference a revision of another article", ctx do
    collection = collection(ctx)
    first = draft_revision(ctx, collection)

    other = %{
      draft_args(ctx, collection)
      | article_ref: "VG-KB-other-" <> alphabetic_suffix(ctx.slug),
        slug: "other-faq"
    }

    assert {:ok, %{article: article}} = invoke(Article, :create_draft, other, ctx.editor)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "articles_current_revision_fkey"}}} =
             SQL.query(Repo, "UPDATE articles SET current_revision_id = $1 WHERE id = $2", [
               Ecto.UUID.dump!(first.id),
               Ecto.UUID.dump!(article.id)
             ])
  end

  test "scoped editors and reviewers can withdraw without granting ADMIN content access", ctx do
    collection = collection(ctx)
    draft = draft_revision(ctx, collection)
    assert {:error, _} = invoke(Article, :read_article, %{id: draft.article_id}, ctx.admin)

    assert {:ok, %{status: :withdrawn}} =
             invoke(
               ArticleRevision,
               :withdraw,
               Map.put(snapshot(draft), :reason, :withdrawn_by_staff),
               ctx.editor
             )

    revision_args = %{article_id: draft.article_id, content: payload()}

    assert {:ok, %{revision_number: 2} = second} =
             invoke(ArticleRevision, :create_draft, revision_args, ctx.editor)

    reviewed = review(ctx, second)

    assert {:ok, %{status: :withdrawn}} =
             invoke(
               ArticleRevision,
               :withdraw,
               Map.put(snapshot(reviewed), :reason, :withdrawn_by_staff),
               ctx.reviewer
             )

    args = %{target_kind: :knowledge_revision, id: reviewed.id}

    assert {:error, _} =
             invoke(VoelgoedAi.Governance.AuditEvent, :knowledge_history, args, ctx.admin)

    assert {:ok, history} =
             invoke(VoelgoedAi.Governance.AuditEvent, :knowledge_history, args, ctx.reviewer)

    assert Enum.map(history, & &1.event) == [:withdraw, :submit_review, :create_draft]
  end

  test "concurrent edits and approvals serialize on real connections", ctx do
    collection = collection(ctx)
    rev = draft_revision(ctx, collection)

    args =
      Map.put(
        snapshot(rev),
        :content,
        put_in(
          payload(),
          ["localized_content", Access.at(0), "approved_answer"],
          "Updated synthetic answer."
        )
      )

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'article_revision_id' = $1", [rev.id])
    end)

    jobs = SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows
    winner = compete(fn -> invoke(ArticleRevision, :edit_draft, args, ctx.editor) end)
    assert SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows == jobs
    in_review = review(ctx, winner)

    assert %{status: :approved} =
             compete(fn ->
               invoke(ArticleRevision, :approve, attest(snapshot(in_review)), ctx.reviewer)
             end)
  end

  test "standalone dates and minute times in FAQ prose preserve their original bytes" do
    for {label, answer} <- [
          {:date_only, "Published on 2026-01-01."},
          {:english, "Published on 2026-01-01 10:00."},
          {:afrikaans, "Gepubliseer op (2026-01-01 10:00)."}
        ] do
      input = put_in(payload(), ["localized_content", Access.at(0), "approved_answer"], answer)
      result = Content.parse(input)

      assert match?({:ok, _}, result), "rejected benign #{label}"
      {:ok, canonical} = result

      assert Enum.any?(canonical["localized_content"], &(&1["approved_answer"] == answer)),
             "changed original #{label} bytes"
    end
  end

  test "date exemption leaves malformed times and contact-shaped text subject to PII checks" do
    for {label, answer} <- [
          {:invalid_day, "2026-02-29 10:00"},
          {:invalid_month, "2026-13-01 10:00"},
          {:invalid_hour, "2026-01-01 24:00"},
          {:invalid_minute, "2026-01-01 10:60"},
          {:seconds, "2026-01-01 10:00:00"},
          {:partial, "2026-01-01 10:0"},
          {:date_in_word, "ref2026-01-01 10:00"},
          {:time_in_word, "2026-01-01 10:00suffix"},
          {:sign_prefix, "+2026-01-01 10:00"},
          {:digit_prefix, "123.2026-01-01 10:00"},
          {:digit_suffix, "2026-01-01 10:00 12345678"},
          {:punctuated_suffix, "2026-01-01 10:00-12345678"},
          {:email, "2026-01-01 10:00. Contact nobody@example.test."},
          {:phone, "2026-01-01 10:00. Contact +27 00 000 0000."}
        ] do
      input = put_in(payload(), ["localized_content", Access.at(0), "approved_answer"], answer)

      assert match?({:error, _}, Content.parse(input)), "accepted prohibited #{label}"
    end
  end

  test "canonical hash sorts locale keys and scope and preserves answer text" do
    assert {:ok, content} = Content.parse(payload())
    hash = Content.hash(content)
    reversed = update_in(payload(), ["localized_content"], &Enum.reverse/1)
    assert {:ok, other} = Content.parse(reversed)
    assert Content.hash(other) == hash
    equivalent_time = %{reversed | "effective_from" => "2026-01-01T02:00:00+02:00"}
    assert {:ok, equivalent} = Content.parse(equivalent_time)
    assert Content.hash(equivalent) == hash
    scope = %{"product" => ["synthetic-z", "synthetic-a"]}
    assert {:ok, scoped} = Content.parse(%{payload() | "applicability" => scope})

    assert {:ok, reversed_scope} =
             Content.parse(%{
               payload()
               | "applicability" => %{"product" => Enum.reverse(scope["product"])}
             })

    assert Content.hash(scoped) == Content.hash(reversed_scope)
    refute Content.hash(scoped) == hash

    assert {:ok, changed} =
             Content.parse(
               put_in(
                 payload(),
                 ["localized_content", Access.at(0), "approved_answer"],
                 "Synthetic answer. "
               )
             )

    refute Content.hash(changed) == hash
  end

  test "self-approval requires the reviewer role and explicit attestation", ctx do
    collection = collection(ctx)
    revision = draft_revision(ctx, collection) |> then(&review(ctx, &1))

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.editor.id, [:knowledge_editor, :knowledge_reviewer])

    assert {:error, _} = invoke(ArticleRevision, :approve, attest(snapshot(revision)), ctx.editor)
    assert {:ok, both} = authenticate(ctx.editor.id)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{editors: [both.id], reviewers: [both.id]}
    })

    assert {:error, _} = invoke(ArticleRevision, :approve, attest(snapshot(revision)), both)
    args = Map.put(attest(snapshot(revision)), :self_approval, true)
    assert {:ok, %{status: :approved}} = invoke(ArticleRevision, :approve, args, both)

    assert approval_reason(revision.id) == "self_approval_attested"
  end

  test "editing another staff member's draft requires a self-approval attestation", ctx do
    collection = collection(ctx)
    reviewer = enable_reviewer_edits(ctx, collection)
    revision = draft_revision(ctx, collection)

    content =
      put_in(
        payload(),
        ["localized_content", Access.at(0), "approved_answer"],
        "Revised synthetic answer."
      )

    assert {:ok, edited} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(revision), :content, content),
               reviewer
             )

    reviewed = review(ctx, edited)
    args = attest(snapshot(reviewed))

    assert {:error, error} = invoke(ArticleRevision, :approve, args, reviewer)
    assert Exception.message(error) =~ "approval_denied"

    assert {:ok, %{status: :approved}} =
             invoke(ArticleRevision, :approve, %{args | self_approval: true}, reviewer)

    assert approval_reason(reviewed.id) == "self_approval_attested"
  end

  test "submitting another staff member's draft requires a self-approval attestation", ctx do
    collection = collection(ctx)
    reviewer = enable_reviewer_edits(ctx, collection)

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.admin.id, [:admin, :knowledge_reviewer])

    assert {:ok, independent} = authenticate(ctx.admin.id)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{
        editors: [ctx.editor.id, reviewer.id],
        reviewers: [reviewer.id, independent.id]
      }
    })

    revision = draft_revision(ctx, collection)
    reviewed = review(%{ctx | editor: reviewer}, revision)
    args = attest(snapshot(reviewed))

    assert {:error, error} = invoke(ArticleRevision, :approve, args, reviewer)
    assert Exception.message(error) =~ "approval_denied"

    assert {:ok, %{status: :approved}} = invoke(ArticleRevision, :approve, args, independent)
    assert approval_reason(reviewed.id) == "source_verified"
  end

  test "a disabled collection fences all draft and review writes", ctx do
    collection = collection(ctx)
    submitted = review(ctx, draft_revision(ctx, collection))

    assert {:ok, draft} =
             invoke(
               ArticleRevision,
               :create_draft,
               %{article_id: submitted.article_id, content: payload()},
               ctx.editor
             )

    assert {:ok, _} = invoke(KnowledgeCollection, :disable, %{id: collection.id}, ctx.admin)

    new_article = %{
      draft_args(ctx, collection)
      | article_ref: "VG-KB-" <> alphabetic_suffix(ctx.slug) <> "-NEW",
        slug: "new-faq"
    }

    for {resource, action, args, actor} <- [
          {ArticleRevision, :edit_draft, Map.put(snapshot(draft), :content, payload()),
           ctx.editor},
          {ArticleRevision, :submit_review, snapshot(draft), ctx.editor},
          {ArticleRevision, :approve, attest(snapshot(submitted)), ctx.reviewer},
          {ArticleRevision, :create_draft, %{article_id: draft.article_id, content: payload()},
           ctx.editor},
          {Article, :create_draft, new_article, ctx.editor}
        ] do
      assert {:error, error} = invoke(resource, action, args, actor)
      assert Exception.message(error) =~ "inactive_scope"
    end
  end

  test "knowledge history returns the newest 100 events", ctx do
    collection = collection(ctx)
    ids = for _ <- 1..101, do: Ecto.UUID.dump!(Ash.UUIDv7.generate())

    SQL.query!(
      Repo,
      """
      INSERT INTO audit_events
        (id, actor_kind, actor_staff_id, target_kind, knowledge_collection_target_id,
         event, reason_code, operational_after, correlation_id, occurred_at)
      SELECT id, 'staff', $1, 'knowledge_collection', $2, 'enable', 'local_admin',
             '{"status":"active"}', id, now() + ordinal * interval '1 second'
      FROM unnest($3::uuid[]) WITH ORDINALITY AS event(id, ordinal)
      """,
      [Ecto.UUID.dump!(ctx.admin.id), Ecto.UUID.dump!(collection.id), ids]
    )

    assert {:ok, history} =
             invoke(
               AuditEvent,
               :knowledge_history,
               %{target_kind: :knowledge_collection, id: collection.id},
               ctx.reviewer
             )

    expected_ids = ids |> Enum.reverse() |> Enum.take(100) |> Enum.map(&Ecto.UUID.load!/1)
    assert Enum.map(history, & &1.id) == expected_ids
  end

  test "sensitive approvals stay pending and archive fences editing", ctx do
    collection = collection(ctx)
    args = put_in(draft_args(ctx, collection), [:content, "sensitive"], true)
    assert {:ok, %{revision: rev}} = invoke(Article, :create_draft, args, ctx.editor)
    reviewed = review(ctx, rev)

    assert {:error, _} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    assert {:ok, %{status: :archived}} =
             invoke(Article, :archive, %{id: rev.article_id, reason: :obsolete}, ctx.reviewer)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :request_changes,
               Map.put(snapshot(reviewed), :reason, :source_correction),
               ctx.reviewer
             )
  end

  test "grants reject internal scope and freeze at publication", ctx do
    public = collection(ctx)
    internal = collection(ctx, "-other", :internal)
    assistant = create(ctx.admin, ctx.slug)
    allow_fixture(assistant)
    revision = draft(ctx.admin, assistant)
    args = %{id: revision.id, collection_id: public.id}

    assert {:error, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{args | collection_id: internal.id},
               ctx.admin
             )

    for actor <- [
          nil,
          ctx.editor,
          ctx.reviewer,
          %{ctx.admin | generation: ctx.admin.generation + 1}
        ] do
      assert {:error, _} = invoke(AssistantRevision, :grant_collection, args, actor)
      assert {:error, _} = invoke(AssistantRevision, :remove_collection, args, actor)
    end

    assert {:ok, _} = invoke(AssistantRevision, :grant_collection, args, ctx.admin)
    assert {:ok, _} = invoke(AssistantRevision, :remove_collection, args, ctx.admin)
    assert {:ok, _} = invoke(AssistantRevision, :grant_collection, args, ctx.admin)
    assert {:ok, _} = invoke(KnowledgeCollection, :disable, %{id: public.id}, ctx.admin)
    publish_args = %{id: revision.id, expected_active_revision_id: nil}
    assert {:error, _} = invoke(AssistantRevision, :publish, publish_args, ctx.admin)
    assert {:ok, _} = invoke(KnowledgeCollection, :enable, %{id: public.id}, ctx.admin)

    assert {:ok, published} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: nil},
               ctx.admin
             )

    assert published.config_hash_version == 2
    assert published.collection_ids == [public.id]
    next = draft(ctx.admin, assistant)

    assert {:ok, next} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: next.id, expected_active_revision_id: published.id},
               ctx.admin
             )

    assert next.collection_ids == []
    refute next.config_hash == published.config_hash
    assert {:error, _} = invoke(AssistantRevision, :remove_collection, args, ctx.admin)
  end

  test "published v2 configuration rejects a changed grant set", ctx do
    granted = collection(ctx)
    added = collection(ctx, "-other")
    assistant = create(ctx.admin, ctx.slug)
    allow_fixture(assistant)
    revision = draft(ctx.admin, assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{id: revision.id, collection_id: granted.id},
               ctx.admin
             )

    assert {:ok, %{id: id, config_hash_version: 2}} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: nil},
               ctx.admin
             )

    current = %Assistant{id: assistant.id, active_revision_id: id}
    assert {:ok, %{id: ^id}} = Repo.transact(fn -> Configuration.current_revision(current) end)

    SQL.query!(
      Repo,
      "INSERT INTO assistant_knowledge_grants (id, assistant_revision_id, collection_id) VALUES ($1, $2, $3)",
      Enum.map([Ash.UUIDv7.generate(), id, added.id], &Ecto.UUID.dump!/1)
    )

    assert {:error, :stale_policy} =
             Repo.transact(fn -> Configuration.current_revision(current) end)
  end

  test "assistant publication locks its previous revision before collections", ctx do
    public = collection(ctx)
    assistant = create(ctx.admin, ctx.slug)
    allow_fixture(assistant)
    first = draft(ctx.admin, assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: first.id, expected_active_revision_id: nil},
               ctx.admin
             )

    next = draft(ctx.admin, assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{id: next.id, collection_id: public.id},
               ctx.admin
             )

    assert {:ok, task} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SELECT id FROM assistant_revisions WHERE id = $1 FOR UPDATE", [
                 Ecto.UUID.dump!(first.id)
               ])

               task =
                 blocked_task(fn ->
                   invoke(
                     AssistantRevision,
                     :publish,
                     %{id: next.id, expected_active_revision_id: first.id},
                     ctx.admin
                   )
                 end)

               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          "SELECT id FROM knowledge_collections WHERE id = $1 FOR UPDATE NOWAIT",
                          [Ecto.UUID.dump!(public.id)]
                        )

               {:ok, task}
             end)

    assert {:ok, %{status: :published}} = Task.await(task, 5_000)
  end

  test "portable import rejects tampering, PII and collisions and round trips a draft", ctx do
    collection = collection(ctx)
    args = draft_args(ctx, collection)

    entry = %{
      "article_ref" => args.article_ref,
      "slug" => args.slug,
      "source_revision_number" => 1,
      "source_content_hash" => Content.hash(elem(Content.parse(payload()), 1)),
      "content" => payload()
    }

    doc = %{"schema_version" => 1, "collection_slug" => collection.slug, "articles" => [entry]}

    invoke_import = fn action, document ->
      invoke(
        KnowledgeCollection,
        action,
        %{id: collection.id, document: Jason.encode!(document)},
        ctx.editor
      )
    end

    for actor <- [
          nil,
          ctx.admin,
          ctx.reviewer,
          %{ctx.editor | generation: ctx.editor.generation + 1}
        ],
        action <- [:preview_import, :apply_import] do
      assert {:error, _} =
               invoke(
                 KnowledgeCollection,
                 action,
                 %{id: collection.id, document: Jason.encode!(doc)},
                 actor
               )
    end

    for actor <- [
          nil,
          ctx.admin,
          ctx.editor,
          %{ctx.reviewer | generation: ctx.reviewer.generation + 1}
        ] do
      assert {:error, _} =
               invoke(KnowledgeCollection, :export_articles, %{id: collection.id}, actor)
    end

    assert {:ok, %{articles: [%{outcome: :create}]}} = invoke_import.(:preview_import, doc)

    wrong_hash =
      put_in(doc, ["articles", Access.at(0), "source_content_hash"], String.duplicate("0", 64))

    assert {:error, error} = invoke_import.(:apply_import, wrong_hash)
    assert Exception.message(error) =~ "invalid_portable_document"

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(doc, ["articles", Access.at(0), "status"], "approved")
             )

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(
                 doc,
                 [
                   "articles",
                   Access.at(0),
                   "content",
                   "localized_content",
                   Access.at(0),
                   "approved_answer"
                 ],
                 "Contact customer@example.test"
               )
             )

    canonical = elem(Content.parse(payload()), 1)

    pii =
      put_in(
        canonical,
        ["localized_content", Access.at(0), "approved_answer"],
        "Contact customer@example.test"
      )

    pii_entry = %{entry | "content" => pii, "source_content_hash" => Content.hash(pii)}
    assert {:error, _} = invoke_import.(:apply_import, %{doc | "articles" => [pii_entry]})

    assert {:ok, %{articles: [%{outcome: :create, revision_id: revision_id}]}} =
             invoke_import.(:apply_import, doc)

    assert {:ok, %{articles: [%{outcome: :existing}]}} = invoke_import.(:apply_import, doc)

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(doc, ["articles", Access.at(0), "slug"], "another-slug")
             )

    assert {:ok, %{document: exported}} =
             invoke(KnowledgeCollection, :export_articles, %{id: collection.id}, ctx.reviewer)

    assert {:error, _} =
             invoke(
               KnowledgeCollection,
               :export_articles,
               %{
                 id: collection.id,
                 article_ids: [Ash.UUIDv7.generate()]
               },
               ctx.reviewer
             )

    assert Jason.decode!(exported) ==
             put_in(doc, ["articles", Access.at(0), "content"], elem(Content.parse(payload()), 1))

    assert {:ok, %{articles: [%{outcome: :existing}]}} =
             invoke_import.(:apply_import, Jason.decode!(exported))

    assert {:ok, original} =
             invoke(ArticleRevision, :read_revision, %{id: revision_id}, ctx.reviewer)

    reviewed = review(ctx, original)

    assert {:ok, %{status: :approved}} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    changed =
      put_in(
        canonical,
        ["localized_content", Access.at(0), "approved_answer"],
        "Nuwe sintetiese antwoord."
      )

    changed_entry = %{
      entry
      | "content" => changed,
        "source_content_hash" => Content.hash(changed)
    }

    changed_doc = %{doc | "articles" => [changed_entry]}
    assert {:error, _} = invoke_import.(:apply_import, changed_doc)

    assert {:ok, %{articles: [%{outcome: :new_revision, revision_id: new_id}]}} =
             invoke(
               KnowledgeCollection,
               :apply_import,
               %{
                 id: collection.id,
                 document: Jason.encode!(changed_doc),
                 new_revision_for: original.article_id
               },
               ctx.editor
             )

    assert {:ok, %{revision_number: 2, status: :draft} = imported} =
             invoke(ArticleRevision, :read_revision, %{id: new_id}, ctx.editor)

    assert {:ok, %{status: :approved, content_hash: hash}} =
             invoke(ArticleRevision, :read_revision, %{id: original.id}, ctx.reviewer)

    assert hash == original.content_hash

    assert {:ok, collection_other} =
             invoke(
               KnowledgeCollection,
               :create,
               %{slug: ctx.slug <> "-other", name: "Synthetic FAQs", audience: :public},
               ctx.admin
             )

    assert {:ok, collection_other} =
             invoke(KnowledgeCollection, :enable, %{id: collection_other.id}, ctx.admin)

    scope(ctx, collection_other)

    assert {:error, _} =
             invoke(
               KnowledgeCollection,
               :apply_import,
               %{
                 id: collection_other.id,
                 document: Jason.encode!(%{doc | "collection_slug" => collection_other.slug})
               },
               ctx.editor
             )

    submitter = enable_reviewer_edits(ctx, collection)

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.editor.id, [:knowledge_editor, :knowledge_reviewer])

    assert {:ok, importer} = authenticate(ctx.editor.id)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{editors: [submitter.id], reviewers: [importer.id]}
    })

    reviewed_import = review(%{ctx | editor: submitter}, imported)
    args = attest(snapshot(reviewed_import))

    assert {:error, error} = invoke(ArticleRevision, :approve, args, importer)
    assert Exception.message(error) =~ "approval_denied"

    assert {:ok, %{status: :approved}} =
             invoke(ArticleRevision, :approve, %{args | self_approval: true}, importer)

    assert approval_reason(imported.id) == "self_approval_attested"
  end

  defp ledger_rows(id) do
    SQL.query!(
      Repo,
      """
      SELECT id::text, entry_kind, entry_key, corrects_id::text, amount_nano_usd,
             input_tokens, closure_approved_by_id::text
      FROM usage_ledger_entries
      WHERE inference_run_id IN (SELECT id FROM inference_runs WHERE article_embedding_id = $1)
      ORDER BY inserted_at, id
      """,
      [Ecto.UUID.dump!(id)]
    ).rows
  end

  defp origin_windows do
    SQL.query!(Repo, """
    SELECT kind, window_start, settled_nano_usd FROM spend_windows
    WHERE settled_nano_usd > 0 AND window_start IN ('2027-01-31', '2027-01-01', '2027-02-01')
    ORDER BY kind
    """).rows
  end

  defp response(request, tokens, vector \\ :valid) do
    {request, response} = EmbeddingTransport.fixture_wire(request)
    body = Map.put(response.body, "usage", %{"prompt_tokens" => tokens, "total_tokens" => tokens})

    body =
      if vector == :zero,
        do: put_in(body, ["data", Access.at(0), "embedding"], List.duplicate(0.0, 1536)),
        else: body

    {request, %{response | body: body}}
  end

  defp compete(operation) do
    assert {:ok, {winner, task}} =
             Repo.transact(fn ->
               assert {:ok, winner} = operation.()
               task = blocked_task(operation)
               {:ok, {winner, task}}
             end)

    assert {:error, _} = Task.await(task, 5_000)
    winner
  end

  defp enable_reviewer_edits(ctx, collection) do
    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.reviewer.id, [
               :knowledge_editor,
               :knowledge_reviewer
             ])

    assert {:ok, reviewer} = authenticate(ctx.reviewer.id)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{editors: [ctx.editor.id, reviewer.id], reviewers: [reviewer.id]}
    })

    reviewer
  end

  defp approval_reason(id) do
    assert %{rows: [[reason]]} =
             SQL.query!(
               Repo,
               "SELECT reason_code FROM audit_events WHERE article_revision_target_id = $1 AND event = 'approve'",
               [Ecto.UUID.dump!(id)]
             )

    reason
  end
end
