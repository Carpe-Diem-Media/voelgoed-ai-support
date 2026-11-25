defmodule VoelgoedAi.AshAiFeasibilityTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.Feasibility.Inference

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
