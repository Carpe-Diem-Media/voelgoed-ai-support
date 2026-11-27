defmodule VoelgoedAi.Support.DecisionEvidenceTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.SupportFixtures, only: [draft: 2, invoke: 4]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Knowledge, Repo, SupportDBCase}
  alias VoelgoedAi.Intelligence.{AssistantRevision, Embedding, EmbeddingTransport}
  alias VoelgoedAi.Knowledge.{ArticleRevision, Retrieval}
  alias VoelgoedAi.Knowledge.Workers.FinalizePublication
  alias VoelgoedAi.Support.{Delivery, RunProcessing, SupportRun}
  alias VoelgoedAi.Support.Workers.Deliver

  for phase <- [:after_rank, :after_commit, :before_dispatch],
      change <- [:revocation, :expiry, :grant, :index_epoch, :human_takeover, :profile] do
    @phase phase
    @change change

    test "#{phase}: #{change} denies the stale decision or send despite an eligible decoy" do
      exercise(@phase, @change, true)
    end

    test "#{phase}: a current #{change} control sends exactly the selected bytes" do
      exercise(@phase, @change, false)
    end
  end

  test "shadow completion stores qualified references without a public intent" do
    ctx = prepare(:revocation, shadow: :en)

    with_ranked(ctx, fn target ->
      assert {:ok, %SupportRun{decision: :no_send, shadow_disposition: :no_send} = completed} =
               complete(ctx, target)

      assert [%{revision_id: id}] = completed.evidence_refs
      assert id == ctx.target.id
      assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "grounded dispatch binds the validated reply text" do
    ctx = prepare(:grounded)

    with_ranked(ctx, fn target ->
      reply = "Die kaartjies kos R25."
      decision = proposal(target, "answer_grounded", reply)

      assert {:ok, delivery} =
               RunProcessing.complete_evidence_fixture(ctx.claim, decision, [target.citation_id])

      assert :ok = Deliver.perform(job(delivery.id))
      assert [{:reply, _, ^reply, _}] = SupportDBCase.writes(ctx.support)
    end)
  end

  for {label, text} <- [
        {"amount", "Die kaartjies kos R250."},
        {"Afrikaans amount multiplier", "Die kaartjies kos R25 miljoen."},
        {"English amount multiplier", "Die kaartjies kos R25 million."},
        {"abbreviated amount multiplier", "Die kaartjies kos R25m."},
        {"multiplier separated by extra whitespace", "Die kaartjies kos R25  miljoen."},
        {"currency", "Die kaartjies kos USD 25."},
        {"bare link", "Besoek example.test."},
        {"date", "Die datum is 25/04/2029."},
        {"email", "Skryf aan agent@example.test."},
        {"link", "Besoek https://example.test."},
        {"secret", "Die password is geheim."}
      ] do
    @text text
    test "grounded completion rejects an unapproved #{label}" do
      ctx = prepare(:grounded)

      with_ranked(ctx, fn target ->
        decision = proposal(target, "answer_grounded", @text)

        assert {:ok, %{state: :failed}} =
                 RunProcessing.complete_evidence_fixture(ctx.claim, decision, [target.citation_id])

        assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
        assert SupportDBCase.writes(ctx.support) == []
      end)
    end
  end

  test "a selected revision cannot be replaced by a decoy or an invented citation" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, %{state: :failed}} =
               RunProcessing.complete_evidence_fixture(ctx.claim, proposal(target), [
                 Ash.UUIDv7.generate()
               ])

      assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a stale completion claim cannot persist an evidence decision" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      {claimed, session, receipts, context} = ctx.claim

      stale =
        {%{claimed | claim_generation: claimed.claim_generation + 1}, session, receipts, context}

      assert {:ok, :stale_claim} =
               RunProcessing.complete_evidence_fixture(stale, proposal(target), [
                 target.citation_id
               ])

      assert %{state: :running, typed_decision: nil} = run(ctx)
      assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
    end)
  end

  test "edits after the dispatch marker deny the captured reply" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      assert :ok =
               dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                 id = ctx.support.event.message_id

                 Agent.update(
                   ctx.support.fake,
                   &Map.put(&1, :decision_messages, %{id => %{text: "Changed"}})
                 )
               end)

      assert %{rows: [["cancelled", "dispatch_denied"]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, reason_code")

      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a human assignment observed after the dispatch marker denies the reply" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      assert :ok =
               dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                 Agent.update(ctx.support.fake, fn state ->
                   %{state | observation: %{state.observation | assignee: :human}}
                 end)
               end)

      assert %{rows: [["cancelled", "dispatch_denied"]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, reason_code")

      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a newer signed customer receipt after the dispatch marker denies the reply" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      assert :ok =
               dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                 assert SupportDBCase.signed_request(ctx.support, fn payload ->
                          Map.put(payload, "id", ctx.support.event.message_id + 1)
                        end).status == 204
               end)

      assert %{rows: [["cancelled", "dispatch_denied"]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, reason_code")

      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a replaced delivery claim cannot dispatch or cancel the current worker" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      assert :ok =
               dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                 # Simulate a changed fence without also making the state terminal.
                 SQL.query!(
                   Repo,
                   """
                   UPDATE outbound_deliveries SET claim_generation = claim_generation + 1 WHERE id = $1
                   """,
                   [uuid(delivery.id)]
                 )
               end)

      assert %{rows: [["sending", 2]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, claim_generation")

      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a control stop after the marker is checked again before the post" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      assert :ok =
               dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                 SupportDBCase.disable_automation(ctx.support)
               end)

      assert %{rows: [["cancelled", "dispatch_denied"]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, reason_code")

      assert SupportDBCase.writes(ctx.support) == []
    end)
  end

  test "a storage failure after the dispatch marker preserves the claim without POST" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)

      try do
        assert {:error, :storage_failure} =
                 dispatch_at(ctx, :before_dispatch, delivery.id, fn ->
                   SQL.query!(
                     Repo,
                     "ALTER TABLE article_embeddings RENAME TO parked_article_embeddings"
                   )
                 end)

        assert %{rows: [["sending", true, 1]]} =
                 SupportDBCase.delivery_rows(
                   ctx.support,
                   "state, dispatch_authorized_at IS NOT NULL, claim_generation"
                 )

        assert :ok = Delivery.deliver(delivery.id)
        assert SupportDBCase.writes(ctx.support) == []
      after
        SQL.query!(
          Repo,
          "ALTER TABLE IF EXISTS parked_article_embeddings RENAME TO article_embeddings"
        )
      end
    end)
  end

  test "T04 rolls back both the decision and intent when delivery enqueue fails" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      SQL.query!(Repo, """
      ALTER TABLE oban_jobs ADD CONSTRAINT reject_typed_reply_job
        CHECK (worker <> 'VoelgoedAi.Support.Workers.Deliver') NOT VALID
      """)

      try do
        result =
          try do
            complete(ctx, target)
          rescue
            Ecto.ConstraintError -> {:error, :constraint}
            Postgrex.Error -> {:error, :constraint}
          end

        assert {:error, _} = result

        assert %{state: :running, typed_decision: nil, evidence_refs: nil} = run(ctx)
        assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")
        assert SupportDBCase.writes(ctx.support) == []
      after
        SQL.query!(Repo, "ALTER TABLE oban_jobs DROP CONSTRAINT reject_typed_reply_job")
      end

      assert {:ok, _} = complete(ctx, target)
    end)
  end

  test "completed evidence, fence and reply commitment are immutable and replay sends once" do
    ctx = prepare(:revocation)

    with_ranked(ctx, fn target ->
      assert {:ok, delivery} = complete(ctx, target)
      completed = run(ctx)

      for expression <- [
            "typed_decision = NULL",
            "evidence_refs = NULL",
            "context_digest = repeat('1', 64)",
            "claim_generation = claim_generation + 1",
            "watermark = watermark + 1"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 SQL.query(Repo, "UPDATE support_runs SET #{expression} WHERE id = $1", [
                   uuid(completed.id)
                 ])
      end

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               SQL.query(
                 Repo,
                 "UPDATE outbound_deliveries SET payload_digest = repeat('1', 64) WHERE id = $1",
                 [uuid(delivery.id)]
               )

      assert {:ok, :stale_claim} = complete(ctx, target)
      assert :ok = Deliver.perform(job(delivery.id))
      assert :ok = Deliver.perform(job(delivery.id))
      assert [%{revision_id: id}] = run(ctx).evidence_refs
      assert id == ctx.target.id
      assert run(ctx) == completed
      assert [{:reply, _, text, _}] = SupportDBCase.writes(ctx.support)
      assert text == target.answer

      assert %{rows: [["sent", 1, 1]]} =
               SupportDBCase.delivery_rows(ctx.support, "state, claim_generation, attempt_count")
    end)
  end

  defp exercise(phase, change, stale?) do
    ctx = prepare(change)

    with_ranked(ctx, fn target ->
      accounting = accounting(ctx)
      assert accounting == [[1, 1]]
      loss = fn -> if stale?, do: invalidate(ctx, change) end

      if phase == :after_rank, do: loss.()
      result = complete(ctx, target)

      case {phase, stale?} do
        {:after_rank, true} ->
          assert {:ok, _} = result
          assert %{typed_decision: nil, evidence_refs: nil} = run(ctx)
          assert %{rows: []} = SupportDBCase.delivery_rows(ctx.support, "id")

        _ ->
          assert {:ok, delivery} = result
          completed = run(ctx)
          assert %{state: :completed, lease_expires_at: nil, claim_generation: 1} = completed
          assert [%{revision_id: revision}] = completed.evidence_refs
          assert revision == ctx.target.id
          assert :ok = dispatch_at(ctx, phase, delivery.id, loss)
          assert run(ctx) == completed

          if stale? do
            assert %{rows: [[state, reason, attempts]]} =
                     SupportDBCase.delivery_rows(ctx.support, "state, reason_code, attempt_count")

            case {phase, change} do
              {:after_commit, _} ->
                assert {state, attempts} == {"cancelled", 0}

              {:before_dispatch, :human_takeover} ->
                assert {state, attempts} == {"unknown", 1}

              {:before_dispatch, _} ->
                assert {state, reason, attempts} == {"cancelled", "dispatch_denied", 1}
            end
          end

          assert :ok = Deliver.perform(job(delivery.id))
      end

      assert accounting(ctx) == accounting

      if stale? do
        assert SupportDBCase.writes(ctx.support) == []
      else
        assert [{:reply, _, reply, _}] = SupportDBCase.writes(ctx.support)
        assert reply == target.answer
      end
    end)
  end

  defp dispatch_at(ctx, :after_commit, id, change) do
    SupportDBCase.block_next_conversation(ctx.support, self())
    task = Task.async(fn -> Deliver.perform(job(id)) end)
    assert_receive {:chatwoot_read, worker}, 2_000
    change.()
    send(worker, :resume_chatwoot_read)
    Task.await(task)
  end

  defp dispatch_at(ctx, :before_dispatch, id, change) do
    parent = self()
    Agent.update(ctx.support.fake, &Map.put(&1, :authorization_barrier, parent))
    task = Task.async(fn -> Deliver.perform(job(id)) end)
    assert_receive {:delivery_authorized, worker}, 2_000
    change.()
    send(worker, :resume_delivery_authorization)
    Task.await(task)
  end

  defp dispatch_at(_, :after_rank, id, _), do: Delivery.deliver(id)

  defp prepare(change, opts \\ []) do
    knowledge = setup_knowledge(%{embedding_index: true})
    fixture(%{})
    collection = collection(knowledge)
    other = collection(knowledge, "-other")

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{editors: [knowledge.editor.id], reviewers: [knowledge.reviewer.id]},
      other.id => %{editors: [knowledge.editor.id], reviewers: [knowledge.reviewer.id]}
    })

    expires = DateTime.add(DateTime.utc_now(), 120)
    target = publish(knowledge, collection, change, expires)
    decoy = publish(knowledge, other, :decoy, expires)

    support =
      SupportDBCase.setup(
        staff: {knowledge, knowledge.admin, nil},
        shadow: opts[:shadow],
        evidence_fixture: true,
        before_publish: fn admin, revision ->
          for col <- [collection, other] do
            grant(admin, revision, col)
          end
        end
      )

    if change == :expiry do
      Agent.update(support.fake, &%{&1 | now: DateTime.add(expires, -4)})
    end

    {:ok, receipt} = SupportDBCase.signed_receipt(support)
    assert :ok = RunProcessing.process_event(receipt.id)
    session = SupportDBCase.session_id(support)

    assert [[id]] =
             SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [
               uuid(session)
             ]).rows

    on_exit(fn -> cleanup_query_attempts(id) end)
    SupportDBCase.advance_clock(support, 2)
    assert {:ok, claim} = RunProcessing.claim_evidence_fixture(id)

    %{
      knowledge: knowledge,
      support: support,
      claim: claim,
      id: id,
      expires: expires,
      target: target,
      decoy: decoy,
      other: other,
      collection: collection,
      locale: if(opts[:shadow], do: "en-ZA", else: "af-ZA")
    }
  end

  defp grant(admin, revision, collection) do
    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{id: revision.id, collection_id: collection.id},
               admin
             )
  end

  defp publish(knowledge, collection, kind, expires) do
    args = draft_args(knowledge, collection)
    args = if kind == :decoy, do: %{args | article_ref: args.article_ref <> "-DECOY"}, else: args

    assert {:ok, %{revision: revision}} =
             invoke(VoelgoedAi.Knowledge.Article, :create_draft, args, knowledge.editor)

    raw =
      case kind do
        :expiry ->
          Map.put(payload(), "expires_at", DateTime.to_iso8601(expires))

        :decoy ->
          Map.update!(payload(), "localized_content", fn locales ->
            Enum.map(locales, &Map.put(&1, "approved_answer", "Eligible decoy."))
          end)

        :grounded ->
          payload()
          |> Map.put("response_mode", "grounded")
          |> Map.update!("localized_content", fn locales ->
            Enum.map(locales, &Map.put(&1, "approved_answer", "Kaartjieprys R25 per persoon."))
          end)

        _ ->
          payload()
      end

    assert {:ok, revision} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(revision), :content, raw),
               knowledge.editor
             )

    reviewed = review(knowledge, revision)

    assert {:ok, approved} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), knowledge.reviewer)

    for id <- request_index(knowledge, approved), do: assert(:ok = Embedding.index(id))

    assert :ok =
             FinalizePublication.perform(%Oban.Job{
               args: %{"revision_id" => approved.id, "generation" => 1}
             })

    approved
  end

  defp with_ranked(ctx, callback) do
    parent = self()

    fixture(%{
      clock: fn -> Agent.get(ctx.support.fake, & &1.now) end,
      wire: fn request ->
        send(parent, :query_wire)
        EmbeddingTransport.fixture_wire(request)
      end
    })

    claim = %{
      run_id: ctx.id,
      claim_generation: 1,
      locale: ctx.locale,
      scope: %{},
      inbox:
        Map.take(ctx.support.event, [:installation_ref, :external_account_id, :external_inbox_id])
    }

    Retrieval.with_fixture(claim, fn search, _ ->
      assert {:ok, %{status: :evidence, evidence: items}} =
               Knowledge.search_published("FAQ", actor: search)

      assert_receive :query_wire
      assert MapSet.new(items, & &1.revision_id) == MapSet.new([ctx.target.id, ctx.decoy.id])
      callback.(Enum.find(items, &(&1.revision_id == ctx.target.id)))
      refute_received :query_wire
    end)
  end

  defp invalidate(ctx, :revocation) do
    assert {:ok, %{status: :revoked}} =
             invoke(
               ArticleRevision,
               :revoke,
               Map.put(snapshot(ctx.target), :reason, :obsolete),
               ctx.knowledge.reviewer
             )
  end

  defp invalidate(ctx, :expiry),
    do: Agent.update(ctx.support.fake, &%{&1 | now: ctx.expires})

  defp invalidate(ctx, :grant) do
    admin = ctx.knowledge.admin
    revision = draft(admin, ctx.support.assistant)
    grant(admin, revision, ctx.other)
    grant(admin, revision, ctx.collection)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :remove_collection,
               %{id: revision.id, collection_id: ctx.collection.id},
               admin
             )

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: ctx.support.revision.id},
               admin
             )
  end

  defp invalidate(ctx, :human_takeover) do
    assert SupportDBCase.signed_request(ctx.support, fn payload ->
             Map.merge(payload, %{
               "id" => ctx.support.event.message_id + 1,
               "message_type" => "outgoing",
               "sender" => %{"type" => "user", "id" => 82}
             })
           end).status == 204
  end

  defp invalidate(ctx, :index_epoch), do: change_index(ctx, "index_epoch = index_epoch + 1")

  defp invalidate(ctx, :profile),
    do: change_index(ctx, "active_index_profile_id = 'stale-profile'")

  defp change_index(ctx, assignment) do
    # Reproduce the locked publication change without a second embedding call.
    assert {:ok, :changed} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SELECT id FROM automation_controls FOR UPDATE")

               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          "UPDATE article_revisions SET #{assignment} WHERE id = $1",
                          [uuid(ctx.target.id)]
                        )

               {:ok, :changed}
             end)
  end

  defp complete(ctx, target),
    do: RunProcessing.complete_evidence_fixture(ctx.claim, proposal(target), [target.citation_id])

  defp proposal(target, decision \\ "answer_exact", reply \\ nil) do
    %{
      "schema_version" => 1,
      "decision" => decision,
      "locale" => target.locale,
      "reason_code" => "supported",
      "evidence_revision_ids" => [target.revision_id],
      "reply_text" => reply
    }
  end

  defp run(ctx) do
    assert {:ok, row} = RunProcessing.with_run(ctx.id, fn _, _, row, _ -> {:ok, row} end)
    row
  end

  defp accounting(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT count(DISTINCT i.id), count(l.id)
      FROM inference_runs i LEFT JOIN usage_ledger_entries l ON l.inference_run_id = i.id
      WHERE i.support_run_id = $1
      """,
      [uuid(ctx.id)]
    ).rows
  end

  defp job(id), do: %Oban.Job{args: %{"delivery_id" => id}}
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
