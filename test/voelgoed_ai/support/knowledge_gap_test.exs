defmodule VoelgoedAi.Support.KnowledgeGapTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.ShadowWorkflowFixture
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest, only: [get: 2]
  import Plug.Conn, only: [get_session: 1, put_private: 3]

  @endpoint VoelgoedAiWeb.Endpoint

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo, StaffFixtures, StaffKnowledgeFixture, SupportDBCase}
  alias VoelgoedAi.Intelligence.EmbeddingTransport
  alias VoelgoedAi.Knowledge.{GapEvidence, KnowledgeGap, Retrieval}
  alias VoelgoedAi.Support.ChatwootAdapter
  alias VoelgoedAiWeb.{GapLiveSocket, StaffLiveSocket}

  @moduletag :requires_pgvector
  @question "Synthetic rehearsal day"

  test "a healthy lookup without the qualified topic records one occurrence and hands off locally" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)

    assert :ok = perform(id)
    assert :ok = perform(id)
    assert %{state: :completed, shadow_disposition: :local_handoff} = run(id)
    assert [["missing", "open", "en-ZA"]] = occurrences(id)
    assert_no_writes(ctx)
  end

  test "another unknown request routes locally without recording a gap" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, "Synthetic rehearsal day and check my account")
    configure(ctx)

    assert :ok = perform(id)
    assert %{state: :completed, shadow_disposition: :local_handoff} = run(id)
    assert [] = occurrences(id)
    assert_no_writes(ctx)
  end

  test "missing locale and incompatible approved facts have distinct causes" do
    ctx = setup_faq(:af, "exact", content: &topic(&1, "Monday", false))
    enable_gap(ctx)
    id = queue(ctx, "Sintetiese repetisiedag")
    configure(ctx)
    assert :ok = perform(id)
    assert [["insufficient", "open", "af-ZA"]] = occurrences(id)
    assert %{rows: [[true, false]]} = source_count(id)
    assert_no_writes(ctx)
  end

  test "only incompatible values qualify when two approved answers compete" do
    ctx =
      setup_faq(:en, "exact",
        content: &topic(&1, "Monday"),
        decoy: &topic(&1, "Friday")
      )

    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)
    assert [["conflicting", "open", "en-ZA"]] = occurrences(id)
    assert %{rows: [[true, true]]} = source_count(id)
    assert_no_writes(ctx)
  end

  test "equivalent or unrecognized fixture facts do not qualify as conflict" do
    ctx = setup_faq(:en, "exact", content: &topic(&1, "Monday"), decoy: &topic(&1, "Monday"))
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)
    assert [] = occurrences(id)
    assert %{shadow_disposition: :local_handoff} = run(id)
    assert_no_writes(ctx)
  end

  test "revocation after retrieval invalidates an otherwise proven conflict at T04" do
    ctx =
      setup_faq(:en, "exact",
        content: &topic(&1, "Monday"),
        decoy: &topic(&1, "Friday")
      )

    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    owner = self()

    task =
      Task.async(fn ->
        Retrieval.with_rank_measurement(
          fn _, _, _ ->
            Agent.update(ctx.support.fake, &Map.put(&1, :decision_history_barrier, owner))
          end,
          fn -> perform(id) end
        )
      end)

    assert_receive {:decision_history, worker}, 5_000
    revoke(ctx)
    send(worker, :resume_decision_history)
    assert :ok = Task.await(task, 6_000)
    assert [] = occurrences(id)
    assert %{shadow_disposition: :local_handoff} = run(id)
    assert_no_writes(ctx)
  end

  test "new coverage from outside the fixture source suppresses a missing gap at T04" do
    ctx = setup_faq(:en, "exact")
    scope = enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    owner = self()

    task =
      Task.async(fn ->
        Retrieval.with_rank_measurement(
          fn _, _, _ ->
            Agent.update(ctx.support.fake, &Map.put(&1, :decision_history_barrier, owner))
          end,
          fn -> perform(id) end
        )
      end)

    assert_receive {:decision_history, worker}, 5_000

    raw =
      VoelgoedAi.KnowledgeFixtures.payload()
      |> topic("Monday")
      |> Map.put("source_references", [%{"kind" => "document", "ref" => "ordinary-faq"}])

    %{id: revision_id} = publish(ctx.staff, %{id: scope.collection_id}, raw, "-LATE")
    send(worker, :resume_decision_history)

    assert :ok = Task.await(task, 6_000)
    assert %{state: :completed, shadow_disposition: :local_handoff} = run(id)
    assert [] = occurrences(id)

    fresh = queue(next_conversation(ctx, 1), @question)
    assert :ok = perform(fresh)

    assert %{typed_decision: %{decision: "answer_exact", evidence_revision_ids: [^revision_id]}} =
             run(fresh)

    assert [] = occurrences(fresh)
    assert_no_writes(ctx)
  end

  test "optional proof restores the outer timeout after success and a canceled statement" do
    ctx = setup_faq(:en, "exact", content: &topic(&1, "Monday"))
    scope = enable_gap(ctx)
    id = queue(ctx, @question)

    gap =
      Map.merge(scope, %{
        assistant_revision_id: run(id).assistant_revision_id,
        locale: "en-ZA",
        applicability: "general",
        topic: "synthetic_rehearsal_day"
      })

    proof = fn expected ->
      assert {:ok, :usable} =
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL statement_timeout = '3s'")

                 assert GapEvidence.addressable?(gap, ctx.target.id, ChatwootAdapter.now()) ==
                          expected

                 assert %{rows: [["3s"]]} = SQL.query!(Repo, "SHOW statement_timeout")
                 :usable
               end)
    end

    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          SQL.query!(Repo, "LOCK TABLE article_embeddings IN ACCESS EXCLUSIVE MODE")
          send(owner, :proof_table_locked)

          receive do
            :release_proof_table -> :released
          after
            5_000 -> flunk("proof table lock was not released")
          end
        end)
      end)

    assert_receive :proof_table_locked, 5_000

    try do
      proof.(false)
    after
      send(blocker.pid, :release_proof_table)
    end

    assert {:ok, :released} = Task.await(blocker)
    proof.(true)
  end

  test "embedding failure and revoked or withdrawn source authority create no gap" do
    ctx = setup_faq(:en, "exact", content: &topic(&1, "Monday"), decoy: &topic(&1, "Friday"))
    scope = enable_gap(ctx)
    first = queue(ctx, @question)
    configure(ctx, embedding: fn request -> {request, Req.Response.new(status: 503)} end)
    assert :ok = perform(first)
    assert [] = occurrences(first)

    revoke(ctx)
    ctx = next_conversation(ctx, 1)
    second = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(second)
    assert [] = occurrences(second)

    ctx = next_conversation(ctx, 2)
    third = queue(ctx, @question)

    # Simulate a live grant withdrawal in the disposable database, leaving
    # the sighted binding and approval rows in place.
    SQL.query!(Repo, "DELETE FROM assistant_knowledge_grants WHERE collection_id = $1", [
      uuid(scope.collection_id)
    ])

    configure(ctx)
    assert :ok = perform(third)
    assert [] = occurrences(third)
    assert_no_writes(ctx)
  end

  test "an exhausted query budget cannot turn an unverified lookup into a gap" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)

    settings = Application.fetch_env!(:voelgoed_ai, :embedding_fixture)
    VoelgoedAi.KnowledgeFixtures.fixture(Map.put(settings, :day_cap, 1))

    assert :ok = perform(id)
    assert [] = occurrences(id)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 0, generation: 0}
    assert_no_writes(ctx)
  end

  test "an expired claim cannot register a finding already observed during retrieval" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    owner = self()

    task =
      Task.async(fn ->
        Retrieval.with_rank_measurement(
          fn _, _, _ ->
            Agent.update(ctx.support.fake, &Map.put(&1, :decision_history_barrier, owner))
          end,
          fn -> perform(id) end
        )
      end)

    assert_receive {:decision_history, worker}, 5_000
    SupportDBCase.advance_clock(ctx.support, 60)
    send(worker, :resume_decision_history)
    assert :ok = Task.await(task, 6_000)
    assert %{state: :failed, reason_code: :deadline} = run(id)
    assert [] = occurrences(id)
    assert_no_writes(ctx)
  end

  test "competing workers create one occurrence and the second worker cannot change it" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    owner = self()

    configure(ctx,
      embedding: fn request ->
        send(owner, {:embedding, self()})

        receive do
          :resume -> EmbeddingTransport.fixture_wire(request)
        after
          4_000 -> raise "embedding barrier timed out"
        end
      end
    )

    first = Task.async(fn -> perform(id) end)
    assert_receive {:embedding, provider}, 5_000
    assert :ok = Task.async(fn -> perform(id) end) |> Task.await()
    assert [] = occurrences(id)
    send(provider, :resume)
    assert :ok = Task.await(first)
    assert [["missing", "open", "en-ZA"]] = occurrences(id)
    assert_no_writes(ctx)
  end

  test "handoff storage failure rolls back a completed run and its gap" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    session_id = SupportDBCase.session_id(ctx.support)

    SQL.query!(Repo, """
    ALTER TABLE outbound_deliveries ADD CONSTRAINT synthetic_gap_handoff_failure
    CHECK (session_id <> '#{session_id}' OR purpose <> 'handoff_status') NOT VALID
    """)

    try do
      result = perform(id)
      assert match?({:error, _}, result)
      assert %{state: :running, shadow_disposition: nil} = run(id)
      assert [] = occurrences(id)
      assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
      assert [] = SupportDBCase.writes(ctx.support)
    after
      SQL.query!(
        Repo,
        "ALTER TABLE outbound_deliveries DROP CONSTRAINT synthetic_gap_handoff_failure"
      )
    end
  end

  test "gap storage failure rolls back completion before staging the handoff" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)

    with_rejected_write(
      "knowledge_gaps",
      "synthetic_gap_insert_failure",
      "support_run_id <> '#{id}'",
      fn ->
        assert {:error, _} = perform(id)
        assert %{state: :running, shadow_disposition: nil} = run(id)
        assert [] = occurrences(id)
        assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
        assert [] = SupportDBCase.writes(ctx.support)
      end
    )
  end

  test "concurrent staff writes and a rejected audit preserve the reviewed version" do
    ctx = setup_faq(:en, "exact")
    enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)
    assert {:ok, %{rows: [initial]}} = invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.reviewer)

    with_rejected_write(
      "audit_events",
      "synthetic_gap_audit_failure",
      "knowledge_gap_target_id IS DISTINCT FROM '#{initial.id}'",
      fn ->
        assert {:error, _} = change(:review, initial, ctx.staff.reviewer)

        assert {:ok, %{rows: [^initial]}} =
                 invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.reviewer)

        assert [] = audits(initial.id)
      end
    )

    attempts =
      for actor <- [ctx.staff.reviewer, ctx.staff.editor],
          do: Task.async(fn -> change(:review, initial, actor) end)

    results = Enum.map(attempts, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{status: :in_review, review_version: 2}}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert [["gap_reviewed"]] = audits(initial.id)
    assert_no_writes(ctx)
  end

  test "review requires scope, compares versions, audits transitions, and links a terminal recurrence" do
    ctx = setup_faq(:en, "exact")
    scope = enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)
    assert {:ok, %{rows: [gap]}} = invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.editor)
    assert {:error, _} = invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.admin)

    assert {:error, _} =
             Ash.create(
               KnowledgeGap,
               %{
                 assistant_id: scope.assistant_id,
                 assistant_revision_id: ctx.support.revision.id,
                 binding_id: scope.binding_id,
                 collection_id: scope.collection_id,
                 support_run_id: id,
                 cause: :missing,
                 topic: "synthetic_rehearsal_day",
                 locale: "en-ZA",
                 applicability: "general"
               },
               action: :register,
               actor: ctx.staff.reviewer
             )

    refute match?(
             {:ok, _},
             Ash.read(KnowledgeGap, action: :scoped_rows, actor: ctx.staff.reviewer)
           )

    assert {:ok, %{status: :in_review, review_version: 2}} =
             change(:review, gap, ctx.staff.editor)

    assert {:error, _} = change(:defer, gap, ctx.staff.editor)
    gap = %{gap | review_version: 2}
    assert {:error, _} = change(:dismiss, gap, ctx.staff.editor, %{reason: :duplicate_issue})

    assert {:ok, %{status: :open, review_version: 3} = deferred} =
             change(:defer, gap, ctx.staff.editor)

    assert {:ok, reviewing} = change(:review, deferred, ctx.staff.reviewer)

    assert {:ok, terminal} =
             change(:dismiss, reviewing, ctx.staff.reviewer, %{reason: :duplicate_issue})

    assert {:error, _} = change(:review, terminal, ctx.staff.reviewer)

    assert [["gap_reviewed"], ["gap_deferred"], ["gap_reviewed"], ["gap_dismissed"]] =
             audits(gap.id)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "knowledge_gaps_immutable"}}} =
             SQL.query(Repo, "UPDATE knowledge_gaps SET topic = 'other' WHERE id = $1", [
               uuid(gap.id)
             ])

    Application.delete_env(:voelgoed_ai, :knowledge_gap_fixture)
    assert {:error, _} = invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.reviewer)
    Application.put_env(:voelgoed_ai, :knowledge_gap_fixture, scope)

    ctx = next_conversation(ctx, 1)
    repeat = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(repeat)

    assert {:ok, %{rows: [recurrent, ^terminal]}} =
             invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.reviewer)

    assert recurrent.recurrence_of_id == terminal.id
    assert recurrent.id != terminal.id
    assert_no_writes(ctx)
  end

  test "address requires the exact current approved revision, collection scope and attestation" do
    ctx = setup_faq(:en, "exact")
    scope = enable_gap(ctx)
    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)
    assert {:ok, %{rows: [gap]}} = invoke(KnowledgeGap, :list_gaps, %{}, ctx.staff.reviewer)
    assert {:ok, gap} = change(:review, gap, ctx.staff.reviewer)

    assert {:error, _} =
             change(:address, gap, ctx.staff.reviewer, %{
               attested: true,
               revision_id: ctx.target.id
             })

    raw = topic(VoelgoedAi.KnowledgeFixtures.payload(), "Monday")
    invalid = publish(ctx.staff, %{id: scope.collection_id}, raw, "-REVOKED")
    revoke(%{ctx | target: invalid})

    assert {:error, _} =
             change(:address, gap, ctx.staff.reviewer, %{attested: true, revision_id: invalid.id})

    candidate = publish(ctx.staff, %{id: scope.collection_id}, raw, "-CURRENT")
    args = %{revision_id: candidate.id, attested: false}
    assert {:error, _} = change(:address, gap, ctx.staff.reviewer, args)
    assert {:error, _} = change(:address, gap, ctx.staff.editor, %{args | attested: true})

    VoelgoedAi.KnowledgeFixtures.scope(%{ctx.staff | reviewer: ctx.staff.editor}, %{
      id: scope.collection_id
    })

    assert {:error, _} = change(:address, gap, ctx.staff.reviewer, %{args | attested: true})
    VoelgoedAi.KnowledgeFixtures.scope(ctx.staff, %{id: scope.collection_id})

    assert {:ok, %{status: :addressed, resolved_revision_id: resolved}} =
             change(:address, gap, ctx.staff.reviewer, %{args | attested: true})

    assert resolved == candidate.id
    assert [["gap_reviewed"], ["gap_addressed"]] = audits(gap.id)
    assert_no_writes(ctx)
  end

  test "a scoped operator can use the gap route and socket while editorial access remains denied" do
    ctx = setup_faq(:en, "exact")
    scope = enable_gap(ctx)

    assert {:ok, _} =
             Accounts.set_roles(ctx.staff.admin, ctx.staff.editor.id, [:support_operator])

    assert {:ok, operator} = StaffFixtures.authenticate(ctx.staff.editor.id)
    assert operator.id in scope.staff_ids

    empty = StaffKnowledgeFixture.read_page(operator, "/staff/gaps")
    assert empty.status == 200
    assert empty.resp_body =~ "No verified gaps in this queue."

    id = queue(ctx, @question)
    configure(ctx)
    assert :ok = perform(id)

    page = StaffKnowledgeFixture.read_page(operator, "/staff/gaps")
    assert page.status == 200
    assert page.resp_body =~ "Approved source missing"
    refute page.resp_body =~ @question
    refute page.resp_body =~ ctx.support.assistant.id
    refute page.resp_body =~ id
    assert StaffKnowledgeFixture.read_page(operator, "/staff/knowledge").status == 302

    info = %{uri: URI.parse(StaffKnowledgeFixture.origin()), session: get_session(page)}
    assert {:ok, _} = GapLiveSocket.connect(%{}, %Phoenix.Socket{}, info)
    assert :error = StaffLiveSocket.connect(%{}, %Phoenix.Socket{}, info)

    assert :error =
             GapLiveSocket.connect(%{}, %Phoenix.Socket{}, %{
               info
               | uri: URI.parse("https://wrong.example.test")
             })

    page = put_private(page, :live_view_connect_info, %{session: get_session(page)})
    assert {:ok, view, html} = live(page)
    assert html =~ "Start review"
    assert {:ok, %{rows: [gap]}} = invoke(KnowledgeGap, :list_gaps, %{}, operator)
    selector = "#review-#{gap.id}"
    next = render_submit(element(view, selector), %{"gap_id" => gap.id, "expected_version" => 1})
    assert next =~ "In review"
    assert next =~ "Dismiss"
    refute next =~ "Mark addressed"
    assert {:ok, _} = Accounts.disable(ctx.staff.admin, operator.id)

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_click(view, "refresh", %{})

    assert_no_writes(ctx)
  end

  defp with_rejected_write(table, constraint, check, operation) do
    SQL.query!(
      Repo,
      "ALTER TABLE #{table} ADD CONSTRAINT #{constraint} CHECK (#{check}) NOT VALID"
    )

    try do
      operation.()
    after
      SQL.query!(Repo, "ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")
    end
  end

  defp topic(raw, day, include_af \\ true) do
    af_day = if day == "Monday", do: "Maandag", else: "Vrydag"

    variants = [
      %{
        "locale" => "en-ZA",
        "title" => @question,
        "approved_answer" => "The rehearsal is on #{day}."
      }
    ]

    variants =
      if include_af do
        variants ++
          [
            %{
              "locale" => "af-ZA",
              "title" => "Sintetiese repetisiedag",
              "approved_answer" => "Die repetisie is op #{af_day}."
            }
          ]
      else
        variants
      end

    %{
      raw
      | "localized_content" => variants,
        "source_references" => [%{"kind" => "document", "ref" => "synthetic-rehearsal-day-v1"}]
    }
  end

  defp next_conversation(ctx, increment),
    do: %{ctx | support: SupportDBCase.next_conversation(ctx.support, increment)}

  defp change(action, gap, actor, opts \\ %{}),
    do:
      invoke(
        KnowledgeGap,
        action,
        Map.merge(opts, %{id: gap.id, expected_version: gap.review_version}),
        actor
      )

  defp audits(id) do
    SQL.query!(
      Repo,
      "SELECT event FROM audit_events WHERE knowledge_gap_target_id = $1 ORDER BY id",
      [uuid(id)]
    ).rows
  end

  defp source_count(id),
    do:
      SQL.query!(
        Repo,
        """
        SELECT first_source_id IS NOT NULL, second_source_id IS NOT NULL
        FROM knowledge_gaps WHERE support_run_id = $1
        """,
        [uuid(id)]
      )

  defp enable_gap(ctx) do
    binding = ctx.support.binding_id

    assert %{rows: [[collection]]} =
             SQL.query!(Repo, "SELECT collection_id::text FROM articles WHERE id = $1", [
               uuid(ctx.target.article_id)
             ])

    scope = %{
      binding_id: binding,
      assistant_id: ctx.support.assistant.id,
      collection_id: collection,
      staff_ids: [ctx.staff.editor.id, ctx.staff.reviewer.id]
    }

    Application.put_env(:voelgoed_ai, :knowledge_gap_fixture, scope)

    on_exit(fn ->
      Application.delete_env(:voelgoed_ai, :knowledge_gap_fixture)

      SQL.query!(
        Repo,
        """
        DELETE FROM audit_events WHERE knowledge_gap_target_id IN
          (SELECT id FROM knowledge_gaps WHERE binding_id = $1)
        """,
        [uuid(binding)]
      )

      SQL.query!(Repo, "DELETE FROM knowledge_gaps WHERE binding_id = $1", [uuid(binding)])
    end)

    scope
  end

  defp occurrences(id) do
    SQL.query!(
      Repo,
      "SELECT cause, status, locale FROM knowledge_gaps WHERE support_run_id = $1",
      [uuid(id)]
    ).rows
  end
end
