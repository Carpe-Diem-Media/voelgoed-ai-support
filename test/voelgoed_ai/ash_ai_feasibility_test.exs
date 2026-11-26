defmodule VoelgoedAi.AshAiFeasibilityTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.Feasibility.{DurableLedger, Inference, TransportEvidence}
  alias VoelgoedAi.Repo

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(VoelgoedAi.AshAiFeasibilityTest.Probe)
    end
  end

  defmodule Probe do
    use Ash.Resource, domain: Domain
    import AshAi.Actions

    actions do
      action :propose, AshAi.Actions.Result do
        allow_nil?(false)
        constraints(of: :atom, constraints: [one_of: [:handoff, :clarify]])

        argument(:text, :string,
          allow_nil?: false,
          constraints: [max_length: 4096, length_count: :bytes]
        )

        run(
          prompt("openai:gpt-6-luna",
            prompt: {"Choose a support decision.", "<%= @input.arguments.text %>"},
            tools: false,
            transform_flow: &__MODULE__.attach_evidence/2,
            req_llm_opts:
              Keyword.merge(Inference.generation_options(),
                api_key: "synthetic-placeholder",
                req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
              ),
            response_schema: %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["decision"],
              "properties" => %{
                "decision" => %{"type" => "string", "enum" => ["handoff", "clarify"]}
              }
            },
            cast_response: &Inference.cast_proposal/1
          )
        )
      end
    end

    def attach_evidence(flow, _context) do
      case flow.source_context[:feasibility_attempt] do
        nil ->
          flow

        attempt ->
          http_options = TransportEvidence.options(attempt, __MODULE__)

          http_options =
            case flow.source_context[:observe_adapter] do
              nil -> http_options
              observe -> Keyword.update!(http_options, :adapter, &observe.(&1))
            end

          %{flow | req_llm_opts: Keyword.put(flow.req_llm_opts, :req_http_options, http_options)}
      end
    end
  end

  test "native Ash AI action sends the bounded stateless Responses request and exposes usage" do
    Req.Test.expect(Probe, fn conn ->
      assert conn.request_path == "/v1/responses"
      {:ok, json, conn} = Plug.Conn.read_body(conn)

      assert %{
               "model" => "gpt-6-luna",
               "store" => false,
               "max_output_tokens" => 500,
               "reasoning" => %{"effort" => "none"},
               "text" => %{"format" => %{"schema" => %{"additionalProperties" => false}}}
             } = body = Jason.decode!(json)

      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "previous_response_id")
      respond(conn, %{"decision" => "handoff"})
    end)

    assert {:ok, %AshAi.Actions.Result{result: :handoff, usage: usage, model: "gpt-6-luna"}} =
             propose("Synthetic test input")

    assert %{input_tokens: 10, output_tokens: 5} = usage
  end

  test "rejects a response with unknown fields" do
    Req.Test.expect(Probe, &respond(&1, %{"decision" => "handoff", "unknown" => true}))
    assert {:error, _} = propose("Synthetic test input")
  end

  test "rejects an invalid decision" do
    Req.Test.expect(Probe, &respond(&1, %{"decision" => "send"}))
    assert {:error, _} = propose("Synthetic test input")
  end

  test "a retryable HTTP failure reaches the deterministic transport once" do
    owner = self()

    Req.Test.stub(Probe, fn conn ->
      send(owner, :provider_attempt)

      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "synthetic"}})
    end)

    assert {:error, _} = propose("Synthetic test input")
    assert_received :provider_attempt
    refute_received :provider_attempt
  end

  # ReqLLM 1.31 attaches its own retry step after Req's options are merged,
  # overriding `retry: false` (deps/req_llm/lib/req_llm/step/retry.ex). Only
  # `max_retries: 0` in the Req options limits it. Replace the evidence
  # adapter with a bare counter so the result depends on the option set
  # alone, not on how the evidence adapter shapes its return value.
  test "transport options alone limit an embedding to one attempt" do
    owner = self()

    for outcome <- [:status_503, :timeout] do
      counter = fn request ->
        send(owner, {:attempt, outcome})

        case outcome do
          :status_503 -> {request, Req.Response.new(status: 503, body: %{})}
          :timeout -> {request, %Req.TransportError{reason: :timeout}}
        end
      end

      http_options =
        {"unused_table", 1, "text-embedding-3-small"}
        |> TransportEvidence.options(Probe)
        |> Keyword.put(:adapter, counter)

      assert {:error, _} =
               ReqLLM.embed("openai:text-embedding-3-small", "Synthetic text",
                 api_key: "synthetic-placeholder",
                 dimensions: 1536,
                 total_timeout: 20_000,
                 req_http_options: http_options
               )

      assert_received {:attempt, ^outcome}
      refute_received {:attempt, ^outcome}
    end
  end

  test "direct ReqLLM retains the provider response ID and usage" do
    Req.Test.expect(Probe, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req_synthetic")
      |> respond(%{"decision" => "handoff"})
    end)

    opts =
      Keyword.merge(Inference.generation_options(),
        api_key: "synthetic-placeholder",
        req_http_options: [plug: {Req.Test, Probe}, retry: false]
      )

    assert {:ok, response} =
             ReqLLM.generate_object(
               "openai:gpt-6-luna",
               "Synthetic test input",
               %{type: "object", properties: %{result: %{type: "object"}}},
               opts
             )

    assert %{response_id: "resp_synthetic", usage: %{input_tokens: 10, output_tokens: 5}} =
             ReqLLM.Response.call_metadata(response)
  end

  test "embedding fakes verify model, dimensions and normalized usage" do
    vector = List.duplicate(0.25, 1536)

    Req.Test.expect(Probe, fn conn ->
      assert conn.request_path == "/v1/embeddings"
      {:ok, json, conn} = Plug.Conn.read_body(conn)

      assert %{"model" => "text-embedding-3-small", "dimensions" => 1536} =
               Jason.decode!(json)

      Req.Test.json(conn, %{
        "object" => "list",
        "model" => "text-embedding-3-small",
        "data" => [%{"index" => 0, "object" => "embedding", "embedding" => vector}],
        "usage" => %{"prompt_tokens" => 4, "total_tokens" => 4}
      })
    end)

    assert {:ok, %{embedding: ^vector, usage: usage}} =
             ReqLLM.embed("openai:text-embedding-3-small", "Synthetic test input",
               api_key: "synthetic-placeholder",
               dimensions: 1536,
               return_usage: true,
               total_timeout: 5000,
               req_http_options: [plug: {Req.Test, Probe}, retry: false]
             )

    assert %{input_tokens: 4} = usage
  end

  describe "durable transport evidence" do
    setup do
      assert %{rows: [["vgas_test", "vgas_test"]]} =
               Repo.query!("SELECT current_database(), current_user")

      ledger = DurableLedger.create!()
      on_exit(fn -> DurableLedger.drop!(ledger) end)
      %{ledger: ledger}
    end

    test "Ash AI rejects the result after usage and provider IDs are committed", %{ledger: ledger} do
      Req.Test.expect(Probe, fn conn ->
        assert %{state: "dispatching"} = DurableLedger.fetch(ledger, 1)
        refute Repo.in_transaction?()

        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_synthetic")
        |> respond(%{"decision" => "handoff", "unexpected" => "synthetic payload"})
      end)

      assert {:error, _} = run_generation(ledger, 1)

      assert %{
               state: "settled",
               actual: 8750,
               result: "rejected",
               evidence: %{
                 "request_id" => "req_synthetic",
                 "response_id" => "resp_synthetic",
                 "provider_model" => "gpt-6-luna",
                 "status" => 200,
                 "classification" => "http_success",
                 "duration_us" => duration,
                 "usage" => %{"input" => 10, "output" => 5}
               }
             } = record = DurableLedger.fetch(ledger, 1)

      assert duration >= 0
      refute inspect(record) =~ "synthetic payload"
      assert {:error, :duplicate} = run_generation(ledger, 1)
    end

    test "HTTP failure settles only with correlated usage and does not retry", %{ledger: ledger} do
      owner = self()

      for {id, body, expected_state} <- [
            {1, %{"usage" => %{"input_tokens" => 12, "output_tokens" => 0}}, "settled"},
            {2, %{}, "unknown"}
          ] do
        Req.Test.stub(Probe, fn conn ->
          send(owner, {:sent, id})

          conn
          |> Plug.Conn.put_status(503)
          |> Plug.Conn.put_resp_header("x-request-id", "req_failure")
          |> Req.Test.json(body)
        end)

        assert {:error, _} = run_generation(ledger, id)

        assert %{
                 state: ^expected_state,
                 evidence: %{"classification" => "http_failure", "status" => 503}
               } =
                 DurableLedger.fetch(ledger, id)

        assert_received {:sent, ^id}
        refute_received {:sent, ^id}
      end
    end

    test "missing correlation and a possible-send timeout hold reservations", %{ledger: ledger} do
      Req.Test.expect(Probe, fn conn ->
        Req.Test.json(conn, %{
          "model" => "gpt-6-luna",
          "usage" => %{"input_tokens" => 12, "output_tokens" => 0}
        })
      end)

      assert {:error, :unknown} = run_generation(ledger, 1)

      assert %{
               state: "unknown",
               actual: nil,
               evidence: %{"request_id" => nil, "response_id" => nil}
             } =
               DurableLedger.fetch(ledger, 1)

      Req.Test.expect(Probe, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :unknown} = run_generation(ledger, 2)

      assert %{state: "unknown", evidence: %{"classification" => "timeout"}} =
               DurableLedger.fetch(ledger, 2)
    end

    for {fault, outcome, classification} <- [
          {:malformed_json, "unknown", "http_success"},
          {:invalid_result, "settled", "http_success"},
          {:status_503, "unknown", "http_failure"},
          {:timeout, "unknown", "timeout"}
        ] do
      @generation_fault fault
      @generation_outcome outcome
      @generation_classification classification
      test "generation fails once at the fake Responses endpoint for #{fault}", %{ledger: ledger} do
        owner = self()
        fault = @generation_fault
        outcome = @generation_outcome
        classification = @generation_classification
        {:ok, ceiling} = TransportEvidence.ceiling("gpt-6-luna")

        Req.Test.stub(Probe, fn conn ->
          send(owner, :generation_wire)

          generation_failure(conn, fault)
        end)

        observe = fn adapter ->
          fn request ->
            send(owner, {:generation_options, request.options[:max_retries]})
            adapter.(request)
          end
        end

        assert {:error, result} =
                 TransportEvidence.run(
                   ledger,
                   1,
                   ~D[2026-11-30],
                   "gpt-6-luna",
                   limits(),
                   fn attempt -> propose_attempt(attempt, observe) end
                 )

        assert_received :generation_wire
        refute_received :generation_wire
        assert_received {:generation_options, 0}
        refute_received {:generation_options, _}

        assert %{state: ^outcome, ceiling: ^ceiling, actual: actual, evidence: evidence} =
                 DurableLedger.fetch(ledger, 1)

        assert evidence["classification"] == classification

        assert_generation_charge(fault, actual, result, evidence)
      end
    end

    test "a worker killed after the real adapter records evidence is recoverable", %{
      ledger: ledger
    } do
      Req.Test.expect(Probe, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_recovery")
        |> respond(%{"decision" => "handoff"})
      end)

      owner = self()

      worker =
        spawn(fn ->
          receive do
            :start ->
              TransportEvidence.run(
                ledger,
                1,
                ~D[2026-11-30],
                "gpt-6-luna",
                limits(),
                fn attempt ->
                  assert {:ok, %AshAi.Actions.Result{result: :handoff}} = propose_attempt(attempt)
                  send(owner, :evidence_committed)
                  Process.sleep(:infinity)
                end
              )
          end
        end)

      ref = Process.monitor(worker)
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      Req.Test.allow(Probe, self(), worker)
      send(worker, :start)
      assert_receive :evidence_committed, 10_000

      assert %{state: "dispatching", evidence: %{"request_id" => "req_recovery"}} =
               DurableLedger.fetch(ledger, 1)

      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 3000
      assert {:ok, "settled"} = DurableLedger.recover(ledger, 1)
      assert {:ok, "settled"} = DurableLedger.recover(ledger, 1)
      assert %{actual: 8750} = DurableLedger.fetch(ledger, 1)
    end

    test "an unbounded or unpriced request never reaches transport", %{ledger: ledger} do
      assert {:error, :unpriced_model} =
               TransportEvidence.run(ledger, 1, ~D[2026-11-30], "unknown", limits(), fn _ ->
                 flunk("unknown price invoked transport")
               end)

      assert {:error, :not_sent} =
               TransportEvidence.run(
                 ledger,
                 2,
                 ~D[2026-11-30],
                 "text-embedding-3-small",
                 limits(),
                 fn attempt ->
                   ReqLLM.embed("openai:text-embedding-3-small", ["a", "b"],
                     api_key: "synthetic-placeholder",
                     dimensions: 1536,
                     total_timeout: 5000,
                     req_http_options: TransportEvidence.options(attempt, Probe)
                   )
                 end
               )

      assert %{state: "released", evidence: nil} = DurableLedger.fetch(ledger, 2)
    end

    # The evidence adapter returns a request whose adapter is `Req.Plug`, so a
    # ReqLLM retry would bypass the wrapper and its durable claim and reach
    # the fake provider directly. Count hits at the fake provider: each is a
    # request the real provider would have received.
    test "embedding 503 and timeout reach the provider exactly once", %{ledger: ledger} do
      owner = self()

      for {id, outcome} <- [{1, :status_503}, {2, :timeout}] do
        Req.Test.stub(Probe, fn conn ->
          send(owner, {:provider_hit, id})

          case outcome do
            :status_503 ->
              conn
              |> Plug.Conn.put_status(503)
              |> Req.Test.json(%{"error" => %{"message" => "synthetic"}})

            :timeout ->
              Req.Test.transport_error(conn, :timeout)
          end
        end)

        assert {:error, _} =
                 TransportEvidence.run(
                   ledger,
                   id,
                   ~D[2026-11-30],
                   "text-embedding-3-small",
                   limits(),
                   fn attempt ->
                     ReqLLM.embed("openai:text-embedding-3-small", "Synthetic text",
                       api_key: "synthetic-placeholder",
                       dimensions: 1536,
                       total_timeout: 5000,
                       req_http_options: TransportEvidence.options(attempt, Probe)
                     )
                   end
                 )

        assert_received {:provider_hit, ^id}
        refute_received {:provider_hit, ^id}
      end
    end

    test "embeddings retain trusted usage and the transport header", %{ledger: ledger} do
      vector = List.duplicate(0.25, 1536)

      Req.Test.expect(Probe, fn conn ->
        assert %{state: "dispatching"} = DurableLedger.fetch(ledger, 1)

        conn
        |> Plug.Conn.put_resp_header("x-request-id", "req_vector")
        |> Req.Test.json(%{
          "object" => "list",
          "model" => "text-embedding-3-small",
          "data" => [%{"index" => 0, "object" => "embedding", "embedding" => vector}],
          "usage" => %{"prompt_tokens" => 4, "total_tokens" => 4}
        })
      end)

      assert {:ok, %{embedding: ^vector}} =
               TransportEvidence.run(
                 ledger,
                 1,
                 ~D[2026-11-30],
                 "text-embedding-3-small",
                 limits(),
                 fn attempt ->
                   ReqLLM.embed("openai:text-embedding-3-small", "Synthetic text",
                     api_key: "synthetic-placeholder",
                     dimensions: 1536,
                     return_usage: true,
                     total_timeout: 5000,
                     req_http_options: TransportEvidence.options(attempt, Probe)
                   )
                 end
               )

      assert %{
               state: "settled",
               actual: 80,
               evidence: %{"request_id" => "req_vector", "response_id" => nil}
             } =
               DurableLedger.fetch(ledger, 1)
    end
  end

  defp assert_generation_charge(:invalid_result, actual, _result, evidence) do
    assert actual == 8750
    assert evidence["response_id"] == "resp_synthetic"
  end

  defp assert_generation_charge(_fault, actual, result, _evidence) do
    assert result == :unknown
    assert is_nil(actual)
  end

  defp generation_failure(conn, :malformed_json) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, "{")
  end

  defp generation_failure(conn, :invalid_result), do: respond(conn, %{"decision" => "send"})

  defp generation_failure(conn, :status_503) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "0")
    |> Plug.Conn.put_status(503)
    |> Req.Test.json(%{"error" => %{"message" => "fixture"}})
  end

  defp generation_failure(conn, :timeout), do: Req.Test.transport_error(conn, :timeout)

  defp run_generation(ledger, id) do
    TransportEvidence.run(ledger, id, ~D[2026-11-30], "gpt-6-luna", limits(), fn attempt ->
      propose_attempt(attempt)
    end)
  end

  defp propose_attempt(attempt, observe \\ nil) do
    Probe
    |> Ash.ActionInput.for_action(:propose, %{text: "Synthetic request"})
    |> Ash.ActionInput.set_context(%{feasibility_attempt: attempt, observe_adapter: observe})
    |> Ash.run_action()
  end

  defp limits, do: [daily: 2_000_000_000, monthly: 2_000_000_000, concurrent: 4]

  defp propose(text) do
    Probe
    |> Ash.ActionInput.for_action(:propose, %{text: text})
    |> Ash.run_action()
  end

  defp respond(conn, proposal) do
    Req.Test.json(conn, %{
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
            %{"type" => "output_text", "text" => Jason.encode!(%{"result" => proposal})}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    })
  end
end
