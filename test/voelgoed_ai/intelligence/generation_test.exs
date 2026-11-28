defmodule VoelgoedAi.Intelligence.GenerationTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.SupportFixtures,
    only: [
      invoke: 4,
      blocked_task: 1,
      assert_blocked_by: 2,
      financial_decision: 4,
      reject_financial_audit: 2
    ]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{KnowledgeFixtures, Repo, SupportDBCase}
  alias VoelgoedAi.Governance.AutomationControl
  alias VoelgoedAi.Intelligence.{Embedding, Generation, InferenceRun, SupportProposal}
  alias VoelgoedAi.Support.{DecisionContext, Ingress, RunProcessing}

  @moduletag :requires_pgvector

  @ceiling 525_375_000
  @actual 8_750

  setup tags do
    if tags[:generation] do
      {support, extra} =
        if tags[:vgas20_upgrade] do
          knowledge = KnowledgeFixtures.setup_knowledge(%{embedding_index: true})

          {SupportDBCase.setup(shadow: :af, staff: {knowledge, knowledge.admin, nil}),
           %{knowledge: knowledge}}
        else
          {SupportDBCase.setup(shadow: :af), %{}}
        end

      now = ~U[2031-01-31 23:59:50Z]
      Agent.update(support.fake, &%{&1 | now: now})
      Map.merge(setup_turn(support, now), extra)
    else
      :ok
    end
  end

  test "raw proposal validation rejects coercion and unknown keys" do
    proposal = %{
      "schema_version" => 1,
      "decision" => "handoff",
      "locale" => "af-ZA",
      "reason_code" => "missing_evidence",
      "evidence_revision_ids" => [],
      "reply_text" => nil
    }

    cast = &SupportProposal.cast/1
    assert {:ok, %{locale: "af-ZA"}} = cast.(proposal)
    assert {:error, _} = cast.(%{proposal | "schema_version" => "1"})
    assert {:error, _} = cast.(Map.put(proposal, "extra", true))
  end

  @tag :generation
  test "committed reservation and stateless strict wire options precede the typed result", ctx do
    owner = self()

    opts = %{
      wire: fn request ->
        send(owner, {:wire, request.options[:max_retries], request.options[:receive_timeout]})
        {:ok, body} = request.body |> IO.iodata_to_binary() |> Jason.decode()
        send(owner, {:body, body})
        response(request)
      end,
      after_dispatch: fn attempt ->
        assert DateTime.compare(attempt.deadline_at, DateTime.add(ctx.now, 30, :second)) == :eq
        assert attempt.dispatched_at
        assert rows(ctx) == [[1, "running", true, "reserved", @ceiling, nil, nil, nil]]

        assert [[job]] =
                 SQL.query!(
                   Repo,
                   "SELECT count(*) FROM oban_jobs WHERE args->>'generation_id' = $1",
                   [attempt.id]
                 ).rows

        assert job == 1
      end
    }

    assert {:ok, %{locale: "af-ZA", decision: "handoff"}} = generate(ctx, opts)
    assert_received {:wire, 0, timeout}
    assert timeout in 1..30_000
    refute_received {:wire, _, _}
    assert_received {:body, body}

    assert %{
             "model" => "gpt-6-luna",
             "store" => false,
             "max_output_tokens" => 500,
             "reasoning" => %{"effort" => "none"},
             "text" => %{"format" => %{"strict" => true, "schema" => schema}},
             "input" => [
               %{"role" => "system"},
               %{"role" => "user", "content" => [%{"text" => data}]}
             ]
           } = body

    assert schema == SupportProposal.schema()
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "previous_response_id")

    assert %{"locale" => "af-ZA", "current_public_messages" => [%{"text" => "Sintetiese vraag"}]} =
             Jason.decode!(data)

    assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
    assert ledger(ctx) == [["settlement", @actual, nil, ~D[2031-01-31], ~D[2031-01-01]]]
    assert {:error, _} = generate(ctx, opts)
    refute_received {:wire, _, _}
    assert SupportDBCase.writes(ctx.support) == []
  end

  for {fault, attempt, reservation, charge} <- [
        {:decode, "unknown", "unknown", nil},
        {:invalid, "failed", "settled", @actual},
        {:wrapper, "failed", "settled", @actual},
        {:refusal, "failed", "settled", @actual},
        {:truncated, "failed", "settled", @actual},
        {:missing_usage, "unknown", "unknown", nil},
        {:uncorrelated, "unknown", "unknown", nil},
        {:wrong_model, "unknown", "unknown", nil},
        {:status_503, "unknown", "unknown", nil},
        {:timeout, "unknown", "unknown", nil}
      ] do
    @tag :generation
    @fault fault
    @attempt attempt
    @reservation reservation
    @charge charge
    test "one bounded wire entry for #{fault}", ctx do
      owner = self()

      opts = %{
        wire: fn request ->
          send(owner, {:wire, request.options[:max_retries]})
          fault(request, @fault)
        end
      }

      assert {:error, _} = generate(ctx, opts)
      assert_received {:wire, 0}
      refute_received {:wire, _}
      assert [[1, @attempt, true, @reservation, @ceiling, @charge, _, _]] = rows(ctx)
      assert length(ledger(ctx)) == if(is_nil(@charge), do: 0, else: 1)
      assert :ok = Embedding.sweep()
      assert {:error, _} = generate(ctx, opts)
      refute_received {:wire, _}
    end
  end

  for fault <- [:http_failure, :nested_failure, :decode_failure, :provider_decode_failure] do
    @tag :generation
    @tag :review_regression
    @fault fault
    test "ReqLLM exception telemetry redacts #{fault}", ctx do
      owner = self()
      event = [:req_llm, :request, :exception]
      request_marker = "Sintetiese vraag"
      response_marker = "synthetic-response-marker"
      handler = make_ref()

      :ok = :telemetry.attach(handler, event, &__MODULE__.relay_telemetry/4, owner)
      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, _} =
               generate(ctx, %{
                 wire: fn request ->
                   assert IO.iodata_to_binary(request.body) =~ request_marker

                   case @fault do
                     :http_failure ->
                       wire(request, 503, Jason.encode!(%{error: %{message: response_marker}}))

                     :nested_failure ->
                       {request,
                        ReqLLM.Error.API.Request.exception(
                          status: 503,
                          reason: response_marker,
                          response_body: response_marker,
                          request_body: request.body,
                          cause: %RuntimeError{message: response_marker},
                          headers: %{"x-synthetic" => [response_marker]},
                          provider_code: response_marker
                        )}

                     :decode_failure ->
                       wire(request, 200, ~s({"#{response_marker}":))

                     :provider_decode_failure ->
                       response(request, %{"output" => response_marker})
                   end
                 end
               })

      assert_received {^event, %{duration: duration}, metadata}
      serialized = :erlang.term_to_binary(metadata)
      assert :binary.match(serialized, request_marker) == :nomatch
      assert :binary.match(serialized, response_marker) == :nomatch
      assert duration >= 0
      assert %{finish_reason: :error, error: %ReqLLM.Error.API.Request{} = error} = metadata

      {status, reason} =
        if @fault in [:decode_failure, :provider_decode_failure],
          do: {nil, "response decode failed"},
          else: {503, "provider HTTP failure"}

      assert metadata.http_status == status
      assert error.reason == reason

      assert Map.take(error, [:request_body, :response_body, :cause, :headers, :provider_code]) ==
               %{
                 request_body: nil,
                 response_body: nil,
                 cause: nil,
                 headers: nil,
                 provider_code: nil
               }

      if @fault == :provider_decode_failure do
        assert rows(ctx) == [[1, "failed", true, "settled", @ceiling, @actual, 10, 5]]
        assert ledger(ctx) == [["settlement", @actual, nil, ~D[2031-01-31], ~D[2031-01-01]]]
      else
        assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
        assert ledger(ctx) == []
      end
    end
  end

  for {output, state} <- [{500, "succeeded"}, {501, "failed"}] do
    @tag :generation
    @tag :review_regression
    @output output
    @expected_state state
    test "frozen output cap with #{output} correlated output tokens", ctx do
      owner = self()

      opts = %{
        wire: fn request ->
          send(owner, :wire)

          response(request, %{
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => @output,
              "total_tokens" => 10 + @output
            }
          })
        end
      }

      result = generate(ctx, opts)
      assert_received :wire
      actual = 5_000 + 750 * @output
      expected_ledger = [["settlement", actual, nil, ~D[2031-01-31], ~D[2031-01-01]]]
      assert ledger(ctx) == expected_ledger

      if @output == 500 do
        assert {:ok, %{decision: "handoff"}} = result
      else
        assert {:error, _} = result
      end

      assert rows(ctx) == [[1, @expected_state, true, "settled", @ceiling, actual, 10, @output]]
      assert :ok = Embedding.sweep()
      assert {:error, _} = generate(ctx, opts)
      refute_received :wire
      assert ledger(ctx) == expected_ledger
    end
  end

  for disable <- [true, false] do
    @tag :generation
    @tag :review_regression
    @disable disable
    test "adapter entry after committed marker with automation disable #{disable}", ctx do
      owner = self()
      event = [:req_llm, :request, :start]
      barrier = make_ref()
      :ok = :telemetry.attach(barrier, event, &__MODULE__.park_request/4, {owner, barrier})
      on_exit(fn -> :telemetry.detach(barrier) end)

      {caller, backend} =
        on_connection(fn ->
          generate(ctx, %{
            wire: fn request ->
              send(owner, {barrier, :wire, self(), Repo.in_transaction?()})
              response(request)
            end
          })
        end)

      assert_receive {^barrier, :request_started, adapter}, 5_000
      refute adapter == caller.pid
      assert rows(ctx) == [[1, "running", true, "reserved", @ceiling, nil, nil, nil]]
      assert_idle(backend)

      if @disable do
        assert {:ok, _} = invoke(AutomationControl, :disable_automation, %{}, ctx.support.admin)
      end

      send(adapter, {barrier, :resume})
      result = Task.await(caller)

      if @disable do
        assert {:error, _} = result
        refute_received {^barrier, :wire, _, _}
        assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
        assert ledger(ctx) == []
      else
        assert {:ok, %{decision: "handoff"}} = result
        assert_received {^barrier, :wire, ^adapter, false}
        refute_received {^barrier, :wire, _, _}
        assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
      end
    end
  end

  def relay_telemetry(event, measurements, metadata, owner) do
    send(owner, {event, measurements, metadata})
  end

  def park_request(_event, _measurements, _metadata, {owner, barrier}) do
    send(owner, {barrier, :request_started, self()})

    receive do
      {^barrier, :resume} -> :ok
    after
      10_000 -> raise "unreleased request-entry barrier"
    end
  end

  @tag :generation
  test "an unconsumed expired attempt releases while a consumed marker holds", ctx do
    owner = self()

    opts = %{
      after_claim: fn attempt ->
        SupportDBCase.advance_clock(ctx.support, 30)
        assert :ok = Generation.recover(attempt.id)
        assert :ok = Generation.recover(attempt.id)
      end,
      wire: fn req ->
        send(owner, :wire)
        response(req)
      end
    }

    assert {:error, _} = generate(ctx, opts)
    assert rows(ctx) == [[1, "rejected", false, "released", @ceiling, nil, nil, nil]]
    assert ledger(ctx) == []
    refute_received :wire
  end

  @tag :generation
  test "recovery holds a dispatched attempt and a response after closure only corrects its origin charge",
       ctx do
    {caller, id, adapter, barrier} = park(ctx)

    SupportDBCase.advance_clock(ctx.support, 35 * 24 * 60 * 60)
    assert :ok = Generation.recover(id)
    assert :ok = Generation.recover(id)
    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
    assert ledger(ctx) == []

    assert {:error, %Ash.Error.Unknown{} = wrong_lane} =
             VoelgoedAi.SupportFixtures.financial_decision(
               InferenceRun,
               :close_unknown_embedding,
               %{id: id, reason: :conservative_closure},
               ctx.support.admin
             )

    assert Exception.message(wrong_lane) =~ "embedding closure denied"
    assert ledger(ctx) == []

    for _ <- 1..2 do
      assert {:ok, %{state: :abandoned}} =
               VoelgoedAi.SupportFixtures.financial_decision(
                 InferenceRun,
                 :close_unknown_generation,
                 %{id: id, reason: :conservative_closure},
                 ctx.support.admin
               )
    end

    assert [[settlement, "settlement", @ceiling, nil]] = ledger_identity(ctx)
    send(adapter, {:resume, barrier})
    assert {:error, _} = Task.await(caller)
    assert :ok = Generation.recover(id)

    assert [[^settlement, "settlement", @ceiling, nil], [_, "late-usage", delta, ^settlement]] =
             ledger_identity(ctx)

    assert delta == @actual - @ceiling

    assert rows(ctx) == [
             [1, "abandoned", true, "conservatively_settled", @ceiling, @ceiling, 10, 5]
           ]

    assert origin_windows() == [
             ["day", ~D[2031-01-31], @actual],
             ["month", ~D[2031-01-01], @actual]
           ]

    assert SupportDBCase.writes(ctx.support) == []
  end

  @tag :generation
  test "generation settlement wins over a later qualified close", ctx do
    {caller, id, adapter, barrier} = park(ctx)
    operation = :close_unknown_generation
    args = %{id: id, reason: :conservative_closure}
    admin = ctx.support.admin

    assert {:error, _} =
             VoelgoedAi.SupportFixtures.financial_decision(InferenceRun, operation, args, admin)

    SupportDBCase.advance_clock(ctx.support, 30)
    assert :ok = Generation.recover(id)
    send(adapter, {:resume, barrier})
    assert {:error, _} = Task.await(caller)

    assert {:error, _} =
             VoelgoedAi.SupportFixtures.financial_decision(InferenceRun, operation, args, admin)

    assert [[_, "settlement", @actual, nil]] = ledger_identity(ctx)
    assert [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]] = rows(ctx)
  end

  @tag :generation
  test "authority loss during I/O settles actual usage and suppresses the proposal", ctx do
    {caller, id, adapter, barrier} = park(ctx)
    assert {:ok, _} = invoke(AutomationControl, :disable_automation, %{}, ctx.support.admin)
    send(adapter, {:resume, barrier})
    assert {:error, _} = Task.await(caller)
    assert :ok = Generation.recover(id)
    assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
    assert [_] = ledger(ctx)
    assert SupportDBCase.writes(ctx.support) == []
  end

  @tag :generation
  test "recovery alone suppresses a late result when the original support claim still qualifies",
       ctx do
    {caller, id, adapter, barrier} = park(ctx)
    SupportDBCase.advance_clock(ctx.support, 30)
    assert :ok = Generation.recover(id)
    SupportDBCase.advance_clock(ctx.support, -30)

    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
    send(adapter, {:resume, barrier})
    assert {:error, _} = Task.await(caller)
    assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
    assert [_] = ledger(ctx)
  end

  @tag :generation
  test "recovery rechecks the deadline after a real attempt-row lock wait", ctx do
    {caller, id, adapter, barrier} = park(ctx)
    SupportDBCase.advance_clock(ctx.support, 30)

    assert {:ok, recovery} =
             Repo.transact(fn ->
               assert {:ok, %{num_rows: 1}} = lock_attempt(id)
               task = blocked_task(&Embedding.sweep/0)
               SupportDBCase.advance_clock(ctx.support, -30)
               {:ok, task}
             end)

    assert :ok = Task.await(recovery)
    assert rows(ctx) == [[1, "running", true, "reserved", @ceiling, nil, nil, nil]]
    send(adapter, {:resume, barrier})
    assert {:ok, %{decision: "handoff"}} = Task.await(caller)
  end

  @tag :generation
  test "qualified successor inherits the original two slots across UTC rollover", ctx do
    owner = self()

    opts = %{
      wire: fn request ->
        send(owner, :wire)
        response(request)
      end
    }

    assert {:ok, _} = generate(ctx, opts)
    assert_received :wire
    SupportDBCase.advance_clock(ctx.support, 15)
    successor = successor(ctx)
    assert {:ok, _} = generate(successor, opts)
    assert_received :wire
    assert {:error, _} = generate(successor, opts)
    refute_received :wire

    assert rows(ctx) == [
             [1, "succeeded", true, "settled", @ceiling, @actual, 10, 5],
             [2, "succeeded", true, "settled", @ceiling, @actual, 10, 5]
           ]

    assert ledger(ctx) == [
             ["settlement", @actual, nil, ~D[2031-01-31], ~D[2031-01-01]],
             ["settlement", @actual, nil, ~D[2031-02-01], ~D[2031-02-01]]
           ]
  end

  @tag :generation
  test "ambiguous attempt blocks the successor even in a new budget window", ctx do
    assert {:error, _} = generate(ctx, %{wire: &fault(&1, :timeout)})
    SupportDBCase.advance_clock(ctx.support, 15)
    successor = successor(ctx)
    owner = self()

    assert {:error, _} =
             generate(successor, %{
               wire: fn request ->
                 send(owner, :wire)
                 response(request)
               end
             })

    refute_received :wire
    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
  end

  @tag :generation
  test "an actual over the ceiling is charged and inhibits additional generation", ctx do
    assert {:error, _} =
             generate(ctx, %{
               wire:
                 &response(&1, %{
                   "usage" => %{
                     "input_tokens" => 1_050_001,
                     "output_tokens" => 500,
                     "total_tokens" => 1_050_501
                   }
                 })
             })

    assert [[1, "failed", true, "settled", @ceiling, actual, 1_050_001, 500]] = rows(ctx)
    assert actual == @ceiling + 500

    assert [[true]] =
             SQL.query!(Repo, "SELECT generation_inhibited FROM automation_controls").rows

    owner = self()

    assert {:error, _} =
             generate(successor(ctx), %{
               wire: fn request ->
                 send(owner, :wire)
                 response(request)
               end
             })

    refute_received :wire
  end

  @tag :generation
  test "generation reset uses the caps approved for the tripped occurrence", ctx do
    assert {:error, _} = generate(ctx, overage_options())
    assert [[true, occurrence]] = inhibit_state(:generation)
    assert is_binary(occurrence)
    assert [[_, "settlement", actual, nil]] = ledger_identity(ctx)
    assert actual == @ceiling + 500

    owner = self()

    wire = fn request ->
      send(owner, :generation_wire)
      response(request)
    end

    sibling = SupportDBCase.next_conversation(ctx.support, 1)
    blocked = setup_turn(sibling, ctx.now)

    {reset_task, admission_task} =
      queue_reset_and_admission(ctx, occurrence, blocked, %{wire: wire})

    assert {:error, _} = Task.await(reset_task)
    assert {:error, _} = Task.await(admission_task)
    refute_received :generation_wire
    assert rows(blocked) == []
    assert [[true, ^occurrence]] = inhibit_state(:generation)
    assert reset_audits(occurrence) == 0

    SupportDBCase.advance_clock(ctx.support, 15)
    next = successor(ctx)

    {reset_task, admission_task} =
      queue_reset_and_admission(ctx, occurrence, next, %{overage_options() | wire: wire})

    assert {:ok, %{lane: :generation, occurrence: ^occurrence}} = Task.await(reset_task)
    assert {:ok, _} = Task.await(admission_task)
    assert_received :generation_wire
    assert [[false, nil]] = inhibit_state(:generation)
    assert reset_audits(occurrence) == 1
    assert {:error, _} = reset(ctx, :generation, occurrence)
    assert reset_audits(occurrence) == 1
  end

  @tag :generation
  test "generation reset denies a missing or mismatched admission budget", ctx do
    assert {:error, _} = generate(ctx, overage_options())
    assert [[true, occurrence]] = inhibit_state(:generation)
    SupportDBCase.advance_clock(ctx.support, 15)

    [[approved]] =
      SQL.query!(Repo, "SELECT generation_inhibit_budget FROM automation_controls").rows

    assert %{"quote" => %{"day_cap" => @ceiling, "month_cap" => @ceiling}} = approved

    for invalid <- [
          nil,
          put_in(approved, ["quote", "profile"], "other-profile"),
          put_in(approved, ["quote", "day_cap"], 2 * @ceiling),
          Map.put(approved, "attempt_id", Ash.UUIDv7.generate())
        ] do
      SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibit_budget = $1", [invalid])
      assert {:error, _} = reset(ctx, :generation, occurrence)
      assert [[true, ^occurrence]] = inhibit_state(:generation)
      assert reset_audits(occurrence) == 0
    end

    SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibit_budget = $1", [approved])
    assert {:ok, _} = reset(ctx, :generation, occurrence)
    assert reset_audits(occurrence) == 1
  end

  @tag :generation
  @tag :reset_authority
  test "an unrelated successful attempt cannot attest a generation trip", ctx do
    sibling = setup_turn(SupportDBCase.next_conversation(ctx.support, 1), ctx.now)
    assert {:ok, _} = generate(sibling, %{wire: &response/1})

    assert [[attempt, quote]] =
             SQL.query!(
               Repo,
               "SELECT id::text, generation_budget FROM inference_runs WHERE turn_ref = $1",
               [uuid(sibling.turn_ref)]
             ).rows

    SupportDBCase.advance_clock(ctx.support, 15)

    tripping =
      setup_turn(
        SupportDBCase.next_conversation(ctx.support, 2),
        VoelgoedAi.Support.ChatwootAdapter.now()
      )

    assert {:error, _} = generate(tripping, overage_options())
    assert [[true, occurrence]] = inhibit_state(:generation)

    SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibit_budget = $1", [
      %{"attempt_id" => attempt, "quote" => quote}
    ])

    assert {:error, _} = reset(tripping, :generation, occurrence)
    assert [[true, ^occurrence]] = inhibit_state(:generation)
    assert reset_audits(occurrence) == 0
  end

  @tag :generation
  @tag :reset_authority
  test "a rejected trip audit rolls back the inhibit and settlement", ctx do
    before = origin_windows()

    reject_financial_audit(:trip_generation_inhibit, fn ->
      assert {:error, _} = generate(ctx, overage_options())
    end)

    assert [[false, nil]] = inhibit_state(:generation)
    assert [] = ledger_identity(ctx)
    assert [[1, "running", true, "reserved", @ceiling, nil, nil, nil]] = rows(ctx)
    assert Enum.all?(origin_windows(), fn [_, _, total] -> total == 0 end)
    assert Enum.all?(before, fn [_, _, total] -> total == 0 end)
  end

  @tag :generation
  @tag :reset_authority
  test "a conflicting retrip cannot become resettable even with its own quote", ctx do
    first_budget = %{day_cap: 2 * @ceiling, month_cap: 2 * @ceiling}
    conflicting = setup_turn(SupportDBCase.next_conversation(ctx.support, 1), ctx.now)
    high_budget = %{day_cap: 3 * @ceiling, month_cap: 3 * @ceiling}
    wire = overage_options().wire
    {first, _, first_adapter, first_barrier} = park(ctx, wire, first_budget)
    {second, second_id, second_adapter, second_barrier} = park(conflicting, wire, high_budget)

    send(first_adapter, {:resume, first_barrier})
    assert {:error, _} = Task.await(first)
    assert [[true, first_occurrence]] = inhibit_state(:generation)

    send(second_adapter, {:resume, second_barrier})
    assert {:error, _} = Task.await(second)
    assert [[true, occurrence]] = inhibit_state(:generation)
    refute occurrence == first_occurrence
    SupportDBCase.advance_clock(ctx.support, 15)

    assert {:error, _} = reset(ctx, :generation, first_occurrence)
    assert {:error, _} = reset(ctx, :generation, occurrence)

    assert [[quote, false]] =
             SQL.query!(
               Repo,
               """
               SELECT inhibit_quote, inhibit_reset_eligible
               FROM audit_events
               WHERE event = 'trip_generation_inhibit' AND correlation_id = $1 AND inhibit_attempt_id = $2
               """,
               [uuid(occurrence), uuid(second_id)]
             ).rows

    SQL.query!(Repo, "UPDATE automation_controls SET generation_inhibit_budget = $1", [
      %{"attempt_id" => second_id, "quote" => quote}
    ])

    assert {:error, _} = reset(ctx, :generation, occurrence)
    assert [[true, ^occurrence]] = inhibit_state(:generation)
    assert reset_audits(first_occurrence) == 0
    assert reset_audits(occurrence) == 0
  end

  defp queue_reset_and_admission(ctx, occurrence, next, opts) do
    assert {:ok, tasks} =
             Repo.transact(fn ->
               assert %{rows: [[holder]]} =
                        SQL.query!(
                          Repo,
                          "SELECT pg_backend_pid() FROM automation_controls FOR UPDATE"
                        )

               {reset_task, reset_backend} =
                 on_connection(fn -> reset(ctx, :generation, occurrence) end)

               assert_blocked_by(reset_backend, holder)

               {admission_task, admission_backend} =
                 on_connection(fn -> generate(next, opts) end)

               assert_blocked_by(admission_backend, reset_backend)
               {:ok, {reset_task, admission_task}}
             end)

    tasks
  end

  @tag :generation
  test "unclassified embedding exposure blocks generation admission and reset across rollover",
       ctx do
    assert {:error, _} = generate(ctx, overage_options())
    assert [[true, occurrence]] = inhibit_state(:generation)
    legacy_inhibit(:embedding)
    SupportDBCase.advance_clock(ctx.support, 15)

    assert {:error, _} = reset(ctx, :generation, occurrence)
    assert reset_audits(occurrence) == 0

    # Remove this test's classified generation inhibit to exercise the other
    # lane's unclassified guard independently of the lane's own flag.
    SQL.query!(
      Repo,
      "UPDATE automation_controls SET generation_inhibited = false, generation_inhibit_occurrence = NULL"
    )

    next = successor(ctx)
    owner = self()

    assert {:error, _} =
             generate(next, %{
               wire: fn request ->
                 send(owner, :wire)
                 response(request)
               end
             })

    refute_received :wire
    assert [[1, "failed", true, "settled", @ceiling, _, 1_050_001, 500]] = rows(ctx)
    assert [_] = ledger(ctx)
    assert [[true, nil]] = inhibit_state(:embedding)
  end

  @tag :generation
  test "a legacy embedding inhibit at the last wire check preserves the committed hold", ctx do
    owner = self()

    assert {:error, _} =
             generate(ctx, %{
               after_dispatch: fn _ -> legacy_inhibit(:embedding) end,
               wire: fn request ->
                 send(owner, :wire)
                 response(request)
               end
             })

    refute_received :wire
    assert [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]] = rows(ctx)
    assert ledger(ctx) == []
    assert [[true, nil]] = inhibit_state(:embedding)
  end

  @tag :generation
  test "trusted usage retrips a legacy generation inhibit without classifying it", ctx do
    opts = overage_options()

    assert {:error, _} =
             generate(ctx, %{
               opts
               | wire: fn request ->
                   legacy_inhibit(:generation)
                   opts.wire.(request)
                 end
             })

    assert [[true, nil]] = inhibit_state(:generation)
    assert [[_, "settlement", actual, nil]] = ledger_identity(ctx)
    assert actual == @ceiling + 500
  end

  @finance_version 20_261_127_150_639
  @tag :generation
  @tag :vgas20_upgrade
  @tag skip: System.get_env("VGAS_VERIFY_VGAS20_UPGRADE") != "true"
  test "populated upgrade preserves a predecessor overflow flag and booked charge", ctx do
    # This proof changes the schema. Restrict it to the disposable runner.
    assert System.get_env("VGAS_F04_DISPOSABLE") == "1"
    assert Repo.config()[:hostname] == "127.0.0.1"
    assert Repo.config()[:port] in [55434, 55436, 55437, 55438]

    assert [["vgas_test", "vgas_test", "180007", "0.8.7", false, false, false, false, false]] =
             SQL.query!(Repo, """
             SELECT current_database(), current_user, current_setting('server_version_num'),
               (SELECT extversion FROM pg_extension WHERE extname = 'vector'),
               rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
             FROM pg_roles WHERE rolname = current_user
             """).rows

    {_collection, revision} = KnowledgeFixtures.approved(ctx.knowledge)
    {caller, id, adapter, barrier} = park(ctx, overage_options().wire)
    SupportDBCase.advance_clock(ctx.support, 30)
    assert :ok = Generation.recover(id)

    assert {:ok, %{state: :abandoned}} =
             financial_decision(
               InferenceRun,
               :close_unknown_generation,
               %{id: id, reason: :conservative_closure},
               ctx.support.admin
             )

    assert [[settlement, "settlement", @ceiling, nil]] = ledger_identity(ctx)

    assert %{num_rows: 1} =
             SQL.query!(Repo, "DELETE FROM audit_events WHERE settlement_target_id = $1", [
               settlement
             ])

    # Stop automation before rewinding operational safety migrations for
    # the SQL-only predecessor phase. Preserve the financial hold and proof.
    SupportDBCase.disable_automation(ctx.support)
    newer = Ecto.Migrator.run(Repo, :down, to_exclusive: @finance_version)

    on_exit(fn ->
      Ecto.Migrator.run(Repo, :up, strict_version_order: true, all: true)
    end)

    assert_raise Postgrex.Error, ~r/VGAS-20 rollback would remove financial evidence/, fn ->
      Ecto.Migrator.run(Repo, :down, step: 1)
    end

    # The predecessor booked the same ceiling and could only set the flag
    # when its late correction overflowed. Remove synthetic post-upgrade
    # evidence before reconstructing that exact shape on the old schema.
    SQL.query!(Repo, "UPDATE inference_runs SET generation_budget = NULL WHERE id = $1", [
      uuid(id)
    ])

    # Exercise the downgrade guard when the trip audit is the only new evidence.
    # The synthetic row models an occurrence that is no longer on the control.
    %{rows: [[trip_id]]} =
      SQL.query!(
        Repo,
        """
        INSERT INTO audit_events (
          id, actor_kind, target_kind, control_target_id, event, reason_code,
          inhibit_attempt_id, inhibit_reset_eligible, correlation_id, occurred_at
        )
        SELECT $1, 'support_worker', 'automation_control', id, 'trip_generation_inhibit',
          'amount_overflow', $2, false, $3, now()
        FROM automation_controls
        RETURNING id
        """,
        [uuid(Ash.UUIDv7.generate()), uuid(id), uuid(Ash.UUIDv7.generate())]
      )

    try do
      assert_raise Postgrex.Error, ~r/VGAS-20 rollback would remove financial evidence/, fn ->
        Ecto.Migrator.run(Repo, :down, step: 1)
      end
    after
      SQL.query!(Repo, "DELETE FROM audit_events WHERE id = $1", [trip_id])
    end

    assert [@finance_version] = Ecto.Migrator.run(Repo, :down, step: 1)

    try do
      legacy_inhibit(:generation)

      assert [[1, "abandoned", true, "conservatively_settled", @ceiling, @ceiling, nil, nil]] =
               rows(ctx)

      assert [[^settlement, "settlement", @ceiling, nil]] = ledger_identity(ctx)
    after
      expected = [@finance_version | Enum.reverse(newer)]
      assert ^expected = Ecto.Migrator.run(Repo, :up, strict_version_order: true, all: true)
    end

    assert [[true, nil]] = inhibit_state(:generation)

    assert [[nil, nil, nil, nil]] =
             SQL.query!(
               Repo,
               """
               SELECT generation_budget, embedding_budget, overflow_evidence, overflow_resolved_at
               FROM inference_runs WHERE id = $1
               """,
               [uuid(id)]
             ).rows

    before = {rows(ctx), ledger_identity(ctx), origin_windows()}
    owner = self()
    sibling = SupportDBCase.next_conversation(ctx.support, 1)
    next = setup_turn(sibling, DateTime.add(ctx.now, 30))

    assert {:error, _} =
             generate(next, %{
               wire: fn request ->
                 send(owner, :generation_wire)
                 response(request)
               end
             })

    KnowledgeFixtures.fixture(%{
      wire: fn request ->
        send(owner, :embedding_wire)
        VoelgoedAi.Intelligence.EmbeddingTransport.fixture_wire(request)
      end
    })

    [article_embedding, _] = KnowledgeFixtures.request_index(ctx.knowledge, revision)
    assert :ok = Embedding.index(article_embedding)

    assert [[0]] =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM inference_runs WHERE article_embedding_id = $1",
               [uuid(article_embedding)]
             ).rows

    assert rows(next) == []
    refute_received :generation_wire
    refute_received :embedding_wire
    reset_id = Ash.UUIDv7.generate()
    assert {:error, _} = reset(ctx, :generation, reset_id)
    assert reset_audits(reset_id) == 0
    assert {rows(ctx), ledger_identity(ctx), origin_windows()} == before

    send(adapter, {:resume, barrier})
    assert {:error, _} = Task.await(caller)
    assert [[true, nil]] = inhibit_state(:generation)

    assert [[^settlement, "settlement", @ceiling, nil], [_, "late-usage", 500, ^settlement]] =
             ledger_identity(ctx)

    assert [[1, "abandoned", true, "conservatively_settled", @ceiling, @ceiling, 1_050_001, 500]] =
             rows(ctx)

    assert origin_windows() == [
             ["day", ~D[2031-01-31], @ceiling + 500],
             ["month", ~D[2031-01-01], @ceiling + 500]
           ]

    assert :ok = Generation.recover(id)
    assert length(ledger_identity(ctx)) == 2
    assert SupportDBCase.writes(ctx.support) == []
  end

  defp legacy_inhibit(:embedding) do
    on_exit(fn ->
      SQL.query!(Repo, "UPDATE automation_controls SET embedding_inhibited = false")
    end)

    SQL.query!(
      Repo,
      "UPDATE automation_controls SET embedding_inhibited = true WHERE NOT embedding_inhibited"
    )
  end

  defp legacy_inhibit(:generation) do
    SQL.query!(
      Repo,
      "UPDATE automation_controls SET generation_inhibited = true WHERE NOT generation_inhibited"
    )
  end

  defp inhibit_state(:generation) do
    SQL.query!(
      Repo,
      "SELECT generation_inhibited, generation_inhibit_occurrence::text FROM automation_controls"
    ).rows
  end

  defp inhibit_state(:embedding) do
    SQL.query!(
      Repo,
      "SELECT embedding_inhibited, embedding_inhibit_occurrence::text FROM automation_controls"
    ).rows
  end

  defp reset(ctx, lane, occurrence) do
    financial_decision(
      AutomationControl,
      :reset_financial_inhibit,
      %{lane: lane, occurrence: occurrence},
      ctx.support.admin
    )
  end

  defp reset_audits(occurrence) do
    [[count]] =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM audit_events WHERE event = 'reset_generation_inhibit' AND correlation_id = $1",
        [uuid(occurrence)]
      ).rows

    count
  end

  defp overage_options do
    %{
      day_cap: @ceiling,
      month_cap: @ceiling,
      wire:
        &response(&1, %{
          "usage" => %{
            "input_tokens" => 1_050_001,
            "output_tokens" => 500,
            "total_tokens" => 1_050_501
          }
        })
    }
  end

  @tag :generation
  test "stale scope, forged actors and open caller transactions cannot reach dispatch", ctx do
    owner = self()

    opts = %{
      wire: fn request ->
        send(owner, :wire)
        response(request)
      end
    }

    for actor <- [nil, %Generation{ref: make_ref()}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               invoke(SupportProposal, :generate, args(ctx), actor)
    end

    assert {:error, _} =
             Generation.with_fixture(ctx.run_id, 2, opts, fn actor ->
               invoke(SupportProposal, :generate, %{args(ctx) | claim_generation: 2}, actor)
             end)

    assert {:ok, :checked} =
             Generation.with_fixture(ctx.run_id, 1, opts, fn actor ->
               Repo.transact(fn ->
                 assert {:error, _} = invoke(SupportProposal, :generate, args(ctx), actor)
                 {:ok, :checked}
               end)
             end)

    assert rows(ctx) == []
    refute_received :wire
  end

  @tag :generation
  test "one claimant consumes the dispatch fence under PostgreSQL contention", ctx do
    parent = self()
    token = make_ref()

    opts = %{
      after_claim: fn attempt ->
        send(parent, {token, :claimed, attempt.id})

        receive do
          {^token, :dispatch} -> :ok
        after
          10_000 -> raise "unreleased claim barrier"
        end
      end,
      wire: fn request ->
        if Req.Request.get_private(request, :fixture_probe) do
          response(request)
        else
          send(parent, {token, :adapter, self()})
          probe = Req.Request.put_private(request, :fixture_probe, true)
          {_, %Req.TransportError{reason: :closed}} = ReqLLM.Transport.run(probe)

          receive do
            {^token, :respond} -> response(request)
          after
            10_000 -> raise "unreleased response barrier"
          end
        end
      end
    }

    {first, first_backend} = on_connection(fn -> generate(ctx, opts) end)
    assert_receive {^token, :claimed, id}, 5_000
    first_pid = first.pid

    assert {:ok, second} =
             Repo.transact(fn ->
               %{rows: [[holder]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
               assert {:ok, %{num_rows: 1}} = lock_attempt(id)
               send(first_pid, {token, :dispatch})
               assert_blocked_by(first_backend, holder)

               {second, second_backend} = on_connection(fn -> generate(ctx, opts) end)
               assert_blocked_by(second_backend, first_backend)

               assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                        Task.async(fn ->
                          SQL.query(
                            Repo,
                            "SELECT id FROM inference_runs WHERE id = $1 FOR UPDATE NOWAIT",
                            [uuid(id)]
                          )
                        end)
                        |> Task.await()

               {:ok, second}
             end)

    assert_receive {^token, :adapter, adapter}, 5_000
    assert_idle(first_backend)
    assert {:error, _} = Task.await(second)
    send(adapter, {token, :respond})
    assert {:ok, %{decision: "handoff"}} = Task.await(first)
    refute_received {^token, :adapter, _}
    assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
  end

  @tag :generation
  test "deadline reached after the marker stops wire entry while preserving the hold", ctx do
    parent = self()

    opts = %{
      after_dispatch: fn _ -> SupportDBCase.advance_clock(ctx.support, 30) end,
      wire: fn request ->
        send(parent, :wire)
        response(request)
      end
    }

    assert {:error, _} = generate(ctx, opts)
    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
    assert ledger(ctx) == []
    refute_received :wire
  end

  @tag :generation
  test "generation denies an unverified price and either exhausted cap before transport", ctx do
    owner = self()

    wire = fn req ->
      send(owner, :wire)
      response(req)
    end

    for config <- [%{price: %{}}, %{day_cap: @ceiling - 1}, %{month_cap: @ceiling - 1}] do
      assert {:error, _} = generate(ctx, Map.put(config, :wire, wire))
      assert rows(ctx) == []
      assert ledger(ctx) == []
      refute_received :wire
    end
  end

  @tag :generation
  test "a held ceiling counts against a different turn in the next UTC day and month", ctx do
    assert {:error, _} = generate(ctx, %{wire: &fault(&1, :timeout)})
    SupportDBCase.advance_clock(ctx.support, 15)
    next = SupportDBCase.next_conversation(ctx.support, 1)
    sibling = setup_turn(next, DateTime.add(ctx.now, 15, :second))
    parent = self()

    wire = fn request ->
      send(parent, :wire)
      response(request)
    end

    assert {:error, _} = generate(sibling, %{wire: wire, day_cap: @ceiling, month_cap: @ceiling})
    refute_received :wire
    assert rows(sibling) == []

    assert {:ok, _} =
             generate(sibling, %{wire: wire, day_cap: 2 * @ceiling, month_cap: 2 * @ceiling})

    assert_received :wire
    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
    assert rows(sibling) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
  end

  @tag :generation
  test "PostgreSQL rejects a generation attempt with a different turn from its run", ctx do
    assert {:ok, _} = generate(ctx, %{wire: &response/1})

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "inference_runs_generation_lineage_fkey"}}} =
             SQL.query(Repo, "UPDATE inference_runs SET turn_ref = $2 WHERE turn_ref = $1", [
               uuid(ctx.turn_ref),
               uuid(Ash.UUIDv7.generate())
             ])

    assert rows(ctx) == [[1, "succeeded", true, "settled", @ceiling, @actual, 10, 5]]
  end

  @tag :generation
  test "the total request deadline stops a parked adapter and holds its committed attempt", ctx do
    SQL.query!(
      Repo,
      "UPDATE support_runs SET lease_expires_at = started_at + interval '1 second' WHERE id = $1",
      [uuid(ctx.run_id)]
    )

    owner = self()

    opts = %{
      wire: fn request ->
        send(owner, {:wire, self(), request.options[:receive_timeout]})
        Process.sleep(:infinity)
      end
    }

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = generate(ctx, opts)
    assert (System.monotonic_time(:millisecond) - started) in 500..4_000
    assert_received {:wire, adapter, timeout}
    assert timeout in 1..1_000
    refute Process.alive?(adapter)
    refute_received {:wire, _, _}
    assert rows(ctx) == [[1, "unknown", true, "unknown", @ceiling, nil, nil, nil]]
  end

  @tag :generation
  test "a typed proposal in the wrong locale settles usage and yields no proposal", ctx do
    wire = fn request ->
      response(request, %{
        "proposal" => %{
          "schema_version" => 1,
          "decision" => "handoff",
          "locale" => "en-ZA",
          "reason_code" => "missing_evidence",
          "evidence_revision_ids" => [],
          "reply_text" => nil
        }
      })
    end

    assert {:error, _} = generate(ctx, %{wire: wire})
    assert rows(ctx) == [[1, "failed", true, "settled", @ceiling, @actual, 10, 5]]
    assert [_] = ledger(ctx)
  end

  defp setup_turn(support, now) do
    assert {:ok, receipt} = Ingress.accept(%{support.event | received_at: now})
    assert :ok = RunProcessing.process_event(receipt)
    session = SupportDBCase.session_id(support)

    assert %{rows: [[run_id, turn_ref]]} =
             SQL.query!(
               Repo,
               """
               UPDATE support_runs SET state = 'running', started_at = $2,
                 lease_expires_at = $2::timestamp + interval '30 seconds',
                 claim_generation = 1, attempt_count = 1
               WHERE session_id = $1 RETURNING id::text, turn_ref::text
               """,
               [uuid(session), DateTime.to_naive(now)]
             )

    on_exit(fn -> clean(turn_ref) end)
    %{support: support, run_id: run_id, turn_ref: turn_ref, now: now}
  end

  defp on_connection(operation) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(parent, {ref, backend})
          operation.()
        end)
      end)

    assert_receive {^ref, backend}, 5_000
    {task, backend}
  end

  defp assert_idle(backend) do
    assert [[true, "idle"]] =
             SQL.query!(
               Repo,
               "SELECT xact_start IS NULL, state FROM pg_stat_activity WHERE pid = $1",
               [backend]
             ).rows
  end

  defp args(ctx) do
    %{
      run_id: ctx.run_id,
      claim_generation: 1,
      context: %DecisionContext{
        prior: [],
        current: [%{role: :contact, text: "Sintetiese vraag"}],
        commitment: :crypto.hash(:sha256, "synthetic context")
      },
      evidence: []
    }
  end

  defp generate(ctx, opts) do
    Generation.with_fixture(ctx.run_id, 1, opts, fn actor ->
      invoke(SupportProposal, :generate, args(ctx), actor)
    end)
  end

  defp response(request, context \\ %{}) do
    proposal =
      Map.get(context, "proposal", %{
        "schema_version" => 1,
        "decision" => "handoff",
        "locale" => "af-ZA",
        "reason_code" => "missing_evidence",
        "evidence_revision_ids" => [],
        "reply_text" => nil
      })

    fields = %{
      "id" => "resp_synthetic",
      "model" => "gpt-6-luna",
      "status" => "completed",
      "output" => [
        %{
          "id" => "msg_synthetic",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" => Jason.encode!(Map.get(context, "wrapper", %{"result" => proposal}))
            }
          ]
        }
      ],
      "usage" => %{
        "input_tokens" => 10,
        "output_tokens" => 5,
        "total_tokens" => 15,
        "output_tokens_details" => %{"reasoning_tokens" => 2}
      }
    }

    body = fields |> Map.merge(Map.drop(context, ["proposal", "wrapper"])) |> Jason.encode!()
    wire(request, 200, body)
  end

  defp fault(request, :decode), do: wire(request, 200, "{")
  defp fault(request, :invalid), do: response(request, %{"proposal" => %{"decision" => 1}})

  defp fault(request, :wrapper),
    do:
      response(request, %{"wrapper" => %{"result" => %{"decision" => "handoff"}, "extra" => true}})

  defp fault(request, :refusal), do: response(request, %{"output" => []})
  defp fault(request, :truncated), do: response(request, %{"status" => "incomplete"})
  defp fault(request, :missing_usage), do: response(request, %{"usage" => nil})
  defp fault(request, :uncorrelated), do: response(request, %{"id" => nil})
  defp fault(request, :wrong_model), do: response(request, %{"model" => "other"})
  defp fault(request, :status_503), do: wire(request, 503, "{}")
  defp fault(request, :timeout), do: {request, %Req.TransportError{reason: :timeout}}

  defp wire(request, status, body) do
    {request,
     Req.Response.new(
       status: status,
       body: body,
       headers: [
         {"x-request-id", "req_synthetic"},
         {"content-type", "application/json"}
       ]
     )}
  end

  defp park(ctx, wire \\ &response/1, budget \\ %{}) do
    owner = self()
    barrier = make_ref()

    opts = %{
      after_dispatch: fn attempt -> send(owner, {barrier, :dispatch, attempt.id}) end,
      wire: fn request ->
        send(owner, {barrier, :adapter, self()})

        receive do
          {:resume, ^barrier} -> wire.(request)
        after
          10_000 -> raise "unreleased generation test barrier"
        end
      end
    }

    caller =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(owner, {barrier, :backend, backend})
          generate(ctx, Map.merge(opts, budget))
        end)
      end)

    assert_receive {^barrier, :backend, backend}, 5_000
    assert_receive {^barrier, :dispatch, attempt_id}, 5_000
    assert_receive {^barrier, :adapter, adapter}, 5_000

    assert [[true, "idle"]] =
             SQL.query!(
               Repo,
               "SELECT xact_start IS NULL, state FROM pg_stat_activity WHERE pid = $1",
               [backend]
             ).rows

    {caller, attempt_id, adapter, barrier}
  end

  defp lock_attempt(id) do
    SQL.query(Repo, "SELECT id FROM inference_runs WHERE id = $1 FOR UPDATE", [uuid(id)])
  end

  defp rows(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT i.ordinal, i.state, i.dispatched_at IS NOT NULL, r.state, r.reserved_nano_usd,
             r.actual_nano_usd, i.input_tokens, i.output_tokens
      FROM inference_runs i JOIN usage_reservations r ON r.inference_run_id = i.id
      WHERE i.purpose = 'generate' AND i.turn_ref = $1 ORDER BY i.ordinal
      """,
      [uuid(ctx.turn_ref)]
    ).rows
  end

  defp ledger(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT l.entry_key, l.amount_nano_usd, l.corrects_id, r.day_window, r.month_window
      FROM usage_ledger_entries l JOIN usage_reservations r ON l.reservation_id = r.id
      JOIN inference_runs i ON i.id = r.inference_run_id WHERE i.turn_ref = $1 ORDER BY i.ordinal, l.id
      """,
      [uuid(ctx.turn_ref)]
    ).rows
  end

  defp ledger_identity(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT l.id, l.entry_key, l.amount_nano_usd, l.corrects_id
      FROM usage_ledger_entries l JOIN inference_runs i ON i.id = l.inference_run_id
      WHERE i.turn_ref = $1 ORDER BY l.id
      """,
      [uuid(ctx.turn_ref)]
    ).rows
  end

  defp origin_windows do
    SQL.query!(Repo, """
    SELECT kind, window_start, settled_nano_usd FROM spend_windows
    WHERE (kind = 'day' AND window_start = '2031-01-31') OR (kind = 'month' AND window_start = '2031-01-01')
    ORDER BY kind
    """).rows
  end

  defp successor(ctx) do
    assert {:ok, next} =
             RunProcessing.with_run(ctx.run_id, fn _config, _session, run, now ->
               assert {:ok, _} = RunProcessing.finish(run, :supersede, now, :late_input)
               id = Ash.UUIDv7.generate()

               assert %{num_rows: 1} =
                        SQL.query!(
                          Repo,
                          """
                          INSERT INTO support_runs (id, session_id, assistant_revision_id, parent_run_id, turn_ref,
                             state, ownership_epoch, assistant_epoch, binding_epoch, control_epoch,
                             claim_generation, attempt_count, watermark, regroup_count, batch_cutoff_at,
                             deadline_at, lease_expires_at, started_at, correlation_id, inserted_at, updated_at)
                          SELECT $2, session_id, assistant_revision_id, id, turn_ref,
                             'running', ownership_epoch, assistant_epoch, binding_epoch, control_epoch,
                             1, 1, watermark, 1, batch_cutoff_at, deadline_at, $4, $3,
                             correlation_id, $3, $3
                          FROM support_runs WHERE id = $1
                          """,
                          [
                            uuid(ctx.run_id),
                            uuid(id),
                            DateTime.to_naive(now),
                            DateTime.to_naive(run.lease_expires_at)
                          ]
                        )

               {:ok, id}
             end)

    %{ctx | run_id: next}
  end

  defp clean(turn_ref) do
    id = uuid(turn_ref)

    Repo.transact(fn ->
      SQL.query!(
        Repo,
        """
        WITH charges AS (
          SELECT r.day_window, r.month_window, sum(l.amount_nano_usd)::bigint AS total
          FROM usage_reservations r JOIN inference_runs i ON i.id = r.inference_run_id
          JOIN usage_ledger_entries l ON l.reservation_id = r.id
          WHERE i.turn_ref = $1 GROUP BY r.day_window, r.month_window
        ), windows AS (
          SELECT 'day' AS kind, day_window AS origin, sum(total)::bigint AS amount FROM charges GROUP BY day_window
          UNION ALL
          SELECT 'month', month_window, sum(total)::bigint FROM charges GROUP BY month_window
        )
        UPDATE spend_windows s SET settled_nano_usd = settled_nano_usd - w.amount
        FROM windows w WHERE s.kind = w.kind AND s.window_start = w.origin AND s.scope = 'global'
        """,
        [id]
      )

      SQL.query!(
        Repo,
        """
        DELETE FROM audit_events WHERE inhibit_attempt_id IN (
          SELECT id FROM inference_runs WHERE turn_ref = $1
        ) OR settlement_target_id IN (
          SELECT l.id FROM usage_ledger_entries l JOIN inference_runs i ON i.id = l.inference_run_id
          WHERE i.turn_ref = $1
        )
        """,
        [id]
      )

      SQL.query!(
        Repo,
        "DELETE FROM usage_ledger_entries WHERE inference_run_id IN (SELECT id FROM inference_runs WHERE turn_ref = $1) AND corrects_id IS NOT NULL",
        [id]
      )

      SQL.query!(
        Repo,
        "DELETE FROM usage_ledger_entries WHERE inference_run_id IN (SELECT id FROM inference_runs WHERE turn_ref = $1)",
        [id]
      )

      SQL.query!(
        Repo,
        "DELETE FROM usage_reservations WHERE inference_run_id IN (SELECT id FROM inference_runs WHERE turn_ref = $1)",
        [id]
      )

      SQL.query!(
        Repo,
        "DELETE FROM oban_jobs WHERE args->>'generation_id' IN (SELECT id::text FROM inference_runs WHERE turn_ref = $1)",
        [id]
      )

      SQL.query!(Repo, "DELETE FROM inference_runs WHERE turn_ref = $1", [id])

      SQL.query!(
        Repo,
        "UPDATE automation_controls SET generation_inhibited = FALSE, generation_inhibit_occurrence = NULL, generation_inhibit_budget = NULL"
      )

      {:ok, :cleaned}
    end)
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
