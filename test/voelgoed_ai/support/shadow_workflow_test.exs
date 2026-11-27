defmodule VoelgoedAi.Support.ShadowWorkflowTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.ShadowWorkflowFixture

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Intelligence.{EmbeddingTransport, Generation}
  alias VoelgoedAi.Support.{EvidenceReply, SupportDecision}
  alias VoelgoedAi.Support.Workers.Sweep

  @moduletag :requires_pgvector

  for {label, locale, subset, severity, input, expected, reason, embedding, generation} <-
        VoelgoedAi.ShadowCases.cases() do
    test "#{label} #{locale} #{subset} #{inspect(input)} routes through signed intake" do
      evaluate_case(
        unquote(
          Macro.escape(
            {label, locale, subset, severity, input, expected, reason, embedding, generation}
          )
        )
      )
    end
  end

  test "revocation after proposal dispatch denies T04 while trusted usage settles" do
    ctx = setup_faq(:en, "grounded", decoy: &decoy/1)
    id = queue(ctx, question(:en))
    owner = self()

    configure(ctx,
      generation: fn req ->
        assert %{"approved_evidence" => [%{"revision_id" => revision}]} = wire_payload(req)
        assert revision == ctx.target.id
        revoke(ctx)
        send(owner, :proposal_returned_after_revocation)
        response(req, ctx)
      end
    )

    assert :ok = perform(id)
    assert_receive :proposal_returned_after_revocation
    assert {:failed, :history_changed, []} = outcome(run(id))

    assert %{rows: [["active", "published"]]} =
             SQL.query!(
               Repo,
               """
               SELECT a.status, r.status FROM articles a JOIN article_revisions r
                 ON r.id = a.current_revision_id WHERE r.id = $1
               """,
               [uuid(ctx.decoy.id)]
             )

    assert_usage(id, 1, 1, :grounded)
    assert_local_handoff(ctx)
    assert_no_writes(ctx)
  end

  test "a missed webhook after generation loses context and routes locally" do
    ctx = setup_faq(:af, "grounded")
    id = queue(ctx, question(:af))

    configure(ctx,
      generation: fn req ->
        SupportDBCase.append_public_input(ctx.support, ctx.support.event.message_id + 1)
        response(req, ctx)
      end
    )

    assert :ok = perform(id)
    assert {:failed, :history_changed, []} = outcome(run(id))
    assert_usage(id, 1, 1, :grounded)
    assert_local_handoff(ctx)
    assert_no_writes(ctx)
  end

  test "a changed public message after generation loses the T04 commitment" do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))

    configure(ctx,
      generation: fn req ->
        put_text(ctx, ctx.support.event.message_id, "Different public question")
        response(req, ctx)
      end
    )

    assert :ok = perform(id)
    assert {:failed, :history_changed, []} = outcome(run(id))
    assert_usage(id, 1, 1, :grounded)
    assert_local_handoff(ctx)
    assert_no_writes(ctx)
  end

  test "a revoked source after embedding cannot be replaced or reach generation" do
    ctx = setup_faq(:af, "grounded", decoy: &decoy/1)
    id = queue(ctx, question(:af))

    configure(ctx,
      generation: fn req -> response(req, ctx) end,
      embedding: fn req ->
        revoke(ctx)
        EmbeddingTransport.fixture_wire(req)
      end
    )

    assert :ok = perform(id)
    assert {"handoff", "unavailable", []} = outcome(run(id))
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 0}
    assert_usage(id, 1, 0, :exact)
    assert_local_handoff(ctx)
    assert_no_writes(ctx)
  end

  test "the pre-generation gate rejects a source changed after ranking" do
    ctx = setup_faq(:en, "grounded", decoy: &decoy/1)
    id = queue(ctx, question(:en))
    owner = self()

    configure(ctx,
      embedding: fn req ->
        Agent.update(ctx.support.fake, &Map.put(&1, :decision_history_barrier, owner))
        EmbeddingTransport.fixture_wire(req)
      end,
      generation: fn req -> response(req, ctx) end
    )

    task = Task.async(fn -> perform(id) end)
    assert_receive {:decision_history, worker}, 5_000
    revoke(ctx)
    send(worker, :resume_decision_history)
    assert :ok = Task.await(task, 6_000)
    assert {"handoff", "unavailable", []} = outcome(run(id))
    assert_usage(id, 1, 0, :grounded)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 0}
    assert_local_handoff(ctx)
    assert_no_writes(ctx)
  end

  test "a human assignee observed after embedding prevents a generation reservation" do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))

    configure(ctx,
      embedding: fn req ->
        Agent.update(ctx.support.fake, &put_in(&1.observation.assignee, :human))
        EmbeddingTransport.fixture_wire(req)
      end,
      generation: fn req -> response(req, ctx) end
    )

    assert :ok = perform(id)
    assert {:cancelled, :scope_denied, []} = outcome(run(id))
    assert_usage(id, 1, 0, :grounded)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 0}
    assert_no_writes(ctx)
  end

  test "global stop fences an in-flight proposal while its trusted usage settles once" do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))
    on_wire = self()

    configure(ctx,
      generation: fn req ->
        SupportDBCase.disable_automation(ctx.support)
        send(on_wire, :stop_committed)
        response(req, ctx)
      end
    )

    assert :ok = perform(id)
    assert_receive :stop_committed
    assert {:cancelled, _, []} = outcome(run(id))
    assert_usage(id, 1, 1, :grounded)
    assert :ok = perform(id)
    assert_no_writes(ctx)
  end

  test "deadline recovery preserves the hold until late trusted usage and never commits a proposal" do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))
    original = run(id)

    configure(ctx,
      generation: fn req ->
        assert %{rows: [[attempt_id]]} =
                 SQL.query!(
                   Repo,
                   """
                   SELECT id::text FROM inference_runs WHERE support_run_id = $1 AND purpose = 'generate'
                   """,
                   [uuid(id)]
                 )

        Agent.update(ctx.support.fake, &%{&1 | now: original.deadline_at})
        assert :ok = Sweep.perform(job("run_id", id))
        assert :ok = Generation.recover(attempt_id)
        assert [_, ["generate", "unknown", nil, nil, "unknown", nil, 525_375_000]] = attempts(id)
        response(req, ctx)
      end
    )

    assert :ok = perform(id)
    assert {:failed, :deadline, []} = outcome(run(id))
    assert_usage(id, 1, 1, :grounded)
    assert_no_writes(ctx)
  end

  for predecessor <- [:known, :unknown] do
    test "the successor inherits deadline and generation budget after a #{predecessor} predecessor" do
      exercise_successor(unquote(predecessor))
    end
  end

  test "an UNKNOWN predecessor query blocks its successor even with spare budget" do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))
    owner = self()

    configure(ctx,
      embedding: fn req ->
        if Agent.get(ctx.hits, & &1.embedding) == 1 do
          send(owner, {:query_parked, self()})

          receive do
            :continue -> {req, %Req.TransportError{reason: :timeout}}
          after
            4_000 -> flunk("the successor was not admitted")
          end
        else
          EmbeddingTransport.fixture_wire(req)
        end
      end,
      generation: fn req -> response(req, ctx) end
    )

    task = Task.async(fn -> perform(id) end)
    assert_receive {:query_parked, request_task}, 4_000
    child = queue(ctx, question(:en), 1)
    assert run(child).parent_run_id == id

    send(request_task, :continue)
    assert :ok = Task.await(task, 6_000)
    assert {:superseded, _, []} = outcome(run(id))
    assert [["query_embedding", "unknown", nil, nil, "unknown", nil, 81_920]] = attempts(id)
    assert :ok = perform(child)
    assert {"handoff", "unavailable", []} = outcome(run(child))
    assert [] = attempts(child)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 0}
    assert_no_writes(ctx)
  end

  test "the shadow worker observes committed query and generation markers outside its idle transaction" do
    ctx = setup_faq(:af, "grounded")
    id = queue(ctx, question(:af))
    owner = self()

    configure(ctx,
      embedding: fn req ->
        send(owner, {:wire, :embedding, self()})

        receive do
          :resume -> EmbeddingTransport.fixture_wire(req)
        after
          4_000 -> flunk("query was not released")
        end
      end,
      generation: fn req ->
        send(owner, {:wire, :generation, self()})

        receive do
          :resume -> response(req, ctx)
        after
          4_000 -> flunk("generation was not released")
        end
      end
    )

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          assert %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(owner, {:checkout, backend})
          perform(id)
        end)
      end)

    assert_receive {:checkout, backend}, 2_000

    for {stage, purpose} <- [embedding: "query_embedding", generation: "generate"] do
      assert_receive {:wire, ^stage, request_task}, 5_000
      committed_before_wire(id, purpose, backend)
      send(request_task, :resume)
    end

    assert :ok = Task.await(task, 6_000)
    assert {"answer_grounded", "supported", [_]} = outcome(run(id))
    assert_no_writes(ctx)
  end

  test "embedding failure telemetry and logs omit the public query and response body" do
    question = "Synthetic FAQ Telemetry Privacy Sentinel"
    response_text = "synthetic embedding provider failure sentinel"

    ctx =
      setup_faq(:en, "grounded",
        content: fn raw ->
          Map.update!(raw, "localized_content", fn variants ->
            Enum.map(variants, &Map.put(&1, "alternative_questions", [question]))
          end)
        end
      )

    id = queue(ctx, question)
    event = [:req_llm, :request, :exception]
    handler = make_ref()

    :ok = :telemetry.attach(handler, event, &__MODULE__.report_exception/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    configure(ctx,
      embedding: fn req ->
        assert IO.iodata_to_binary(req.body) =~ question

        {req,
         Req.Response.new(
           status: 503,
           body: Jason.encode!(%{error: %{message: response_text}}),
           headers: [{"content-type", "application/json"}]
         )}
      end,
      generation: fn _ -> flunk("the embedding failure must stop generation") end
    )

    logs = ExUnit.CaptureLog.capture_log(fn -> assert :ok = perform(id) end)
    assert_receive {:provider_exception, metadata}
    contents = :erlang.term_to_binary(metadata)
    refute contents =~ question
    refute contents =~ response_text
    refute logs =~ question
    refute logs =~ response_text

    assert {"handoff", "unavailable", []} = outcome(run(id))
    assert [["query_embedding", "unknown", nil, nil, "unknown", nil, 81_920]] = attempts(id)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 0}
    assert_no_writes(ctx)
  end

  def report_exception(_event, _measurements, metadata, owner),
    do: send(owner, {:provider_exception, metadata})

  test "disabled binding makes no shadow provider or Chatwoot write calls" do
    ctx = setup_faq(:af, "grounded", enable: false)
    id = queue(ctx, question(:af))
    configure(ctx, generation: fn req -> response(req, ctx) end)

    assert :ok = perform(id)
    assert run(id).typed_decision == nil
    assert Agent.get(ctx.hits, & &1) == %{embedding: 0, generation: 0}
    assert_no_writes(ctx)
  end

  defp exercise_successor(outcome) do
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))
    parent = run(id)
    owner = self()

    configure(ctx,
      generation: fn req ->
        if Agent.get(ctx.hits, & &1.generation) == 1 do
          send(owner, {:generation_parked, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> flunk("successor was not admitted")
          end

          if outcome == :unknown,
            do: response(req, ctx, %{}, %{"usage" => nil}),
            else: response(req, ctx)
        else
          response(req, ctx)
        end
      end
    )

    task = Task.async(fn -> perform(id) end)
    assert_receive {:generation_parked, request_task}, 5_000
    child_id = queue(ctx, question(:en), 1)
    child = run(child_id)
    assert child.parent_run_id == id
    assert child.turn_ref == parent.turn_ref
    assert child.deadline_at == parent.deadline_at

    send(request_task, :continue)
    assert :ok = Task.await(task, 6_000)
    assert {:superseded, _, []} = outcome(run(id))
    assert :ok = perform(child_id)
    assert :ok = perform(child_id)

    if outcome == :known do
      assert {"answer_grounded", "supported", [revision]} = outcome(run(child_id))
      assert revision == ctx.target.id
      assert_usage(child_id, 1, 1, :grounded)

      assert %{rows: [[1], [2]]} =
               SQL.query!(
                 Repo,
                 "SELECT ordinal FROM inference_runs WHERE turn_ref = $1 ORDER BY ordinal",
                 [uuid(parent.turn_ref)]
               )

      assert Agent.get(ctx.hits, & &1) == %{embedding: 2, generation: 2}
    else
      assert {"handoff", "unavailable", []} = outcome(run(child_id))
      assert_usage(id, 1, 1, :unknown)
      assert [] = attempts(child_id)
      assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 1}
    end

    assert_no_writes(ctx)
  end

  defp evaluate_case(
         {label, locale, subset, severity, input, expected, reason, embedding, generation}
       ) do
    opts = if input == :conditional, do: [content: &conditional/1], else: []
    ctx = setup_faq(locale, if(input == :exact, do: "exact", else: "grounded"), opts)
    reference = question(locale)
    id = queue(ctx, if(is_atom(input), do: reference, else: input))

    if input == :private, do: private_history(ctx)

    configurations = [
      generation: fn request ->
        assert %{
                 "approved_evidence" => [%{"revision_id" => revision, "answer" => answer}],
                 "current_public_messages" => [%{"text" => ^reference, "role" => "contact"}],
                 "prior_public_messages" => []
               } = wire_payload(request)

        assert revision == ctx.target.id
        assert answer == approved(locale)
        committed_before_wire(id, "generate")
        scenario_response(request, ctx, input)
      end,
      embedding: fn request ->
        committed_before_wire(id, "query_embedding")
        EmbeddingTransport.fixture_wire(request)
      end
    ]

    configure(ctx, configurations)
    started = System.monotonic_time(:microsecond)
    assert :ok = perform(id)
    elapsed = System.monotonic_time(:microsecond) - started
    row = run(id)

    assert :ok = perform(id)
    assert row == run(id)
    {observed, observed_reason, refs} = outcome(row)
    assert observed == expected
    assert observed_reason == reason

    assert Agent.get(ctx.hits, & &1) == %{
             embedding: embedding,
             generation: generation
           }

    assert_no_writes(ctx)
    expected_refs = if input in [:exact, :grounded], do: [ctx.target.id], else: []
    assert refs == expected_refs

    if input == :exact do
      assert {:ok, text} =
               EvidenceReply.render(row.typed_decision, [
                 %{
                   revision_id: ctx.target.id,
                   locale: row.typed_decision.locale,
                   mode: :exact,
                   answer: approved(locale)
                 }
               ])

      assert text === approved(locale)
      assert row.typed_decision.reply_text == nil
    end

    if input == :grounded, do: assert(row.typed_decision.reply_text === paraphrase(locale))
    if row.typed_decision, do: assert(row.typed_decision.locale == to_string(locale) <> "-ZA")
    accounting = assert_usage(id, embedding, generation, input)

    if System.get_env("VGAS_SHADOW_EVAL") == "1" do
      IO.puts(
        "VGAS_EVAL " <>
          Jason.encode!(%{
            case: label,
            locale: locale,
            subset: subset,
            severity: severity,
            expected: expected,
            observed: observed,
            reason: reason,
            reference_match: refs == expected_refs,
            selected_fixture: if(refs == [], do: nil, else: "target"),
            elapsed_us: elapsed,
            embedding_hits: embedding,
            generation_hits: generation,
            reply_hits: 0,
            status_hits: 0,
            usage: accounting,
            human_semantic_review: "pending"
          })
      )
    end
  end

  defp assert_local_handoff(ctx) do
    assert %{rows: [["handoff_pending", true]]} =
             SQL.query!(
               Repo,
               """
               SELECT state, human_inhibit FROM support_sessions WHERE id = $1
               """,
               [uuid(SupportDBCase.session_id(ctx.support))]
             )
  end

  defp private_history(ctx) do
    Agent.update(ctx.support.fake, fn state ->
      [row] = state.history
      %{state | history: [%{row | id: row.id - 1, visibility: :private, sender: :human}, row]}
    end)
  end

  defp conditional(raw),
    do:
      Map.update!(raw, "localized_content", fn locales ->
        Enum.map(
          locales,
          &Map.put(&1, "escalation_conditions", ["Staff must verify eligibility."])
        )
      end)

  defp decoy(raw),
    do:
      Map.update!(raw, "localized_content", fn locales ->
        Enum.map(locales, &Map.put(&1, "title", &1["title"] <> " decoy"))
      end)

  defp scenario_response(req, ctx, :invented),
    do: response(req, ctx, %{"evidence_revision_ids" => [Ash.UUIDv7.generate()]})

  defp scenario_response(req, ctx, :unsupported),
    do:
      response(req, ctx, %{
        "reply_text" => "Follow the instructions at https://unapproved.example.test."
      })

  defp scenario_response(req, ctx, :extra_key),
    do: response(req, ctx, %{"operation" => "force_reply"})

  defp scenario_response(req, ctx, :unknown),
    do: response(req, ctx, %{}, %{"usage" => nil})

  defp scenario_response(req, ctx, _), do: response(req, ctx)

  defp outcome(%{typed_decision: %SupportDecision{} = d}),
    do: {d.decision, d.reason_code, d.evidence_revision_ids}

  defp outcome(row), do: {row.state, row.reason_code, []}

  defp assert_usage(id, embed, gen, scenario) do
    expected_embedding =
      if embed == 1,
        do: [["query_embedding", "succeeded", 3, nil, "settled", 8, 81_920]],
        else: []

    expected_generation =
      cond do
        gen == 0 -> []
        scenario == :unknown -> [["generate", "unknown", nil, nil, "unknown", nil, 525_375_000]]
        scenario == :extra_key -> [["generate", "failed", 10, 5, "settled", 8_750, 525_375_000]]
        true -> [["generate", "succeeded", 10, 5, "settled", 8_750, 525_375_000]]
      end

    expected = expected_embedding ++ expected_generation
    assert attempts(id) == expected

    Enum.map(expected, fn [purpose, state, input, output, hold, cost, reserved] ->
      %{
        purpose: purpose,
        state: state,
        input: input,
        output: output,
        charge_nano_usd: cost,
        unknown_nano_usd: if(hold == "unknown", do: reserved, else: 0)
      }
    end)
  end
end
