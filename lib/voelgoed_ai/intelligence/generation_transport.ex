defmodule VoelgoedAi.Intelligence.GenerationTransport do
  @moduledoc false

  alias VoelgoedAi.Intelligence.SupportProposal
  alias VoelgoedAi.Support.ChatwootAdapter

  @model "gpt-6-luna"
  @max_body_bytes 65_536
  @max_request_bytes 32_768
  @max_count 9_223_372_036_854_775_807

  # ReqLLM runs timed HTTP in a task. The closure carries the committed
  # attempt's authority and its own single-entry latch across that boundary.
  def options(attempt, {owner, ref}, wire, timeout, cutoff) do
    latch = :atomics.new(1, [])
    key = {ref, attempt.id, attempt.dispatch_fence}
    expires = System.monotonic_time(:millisecond) + timeout

    [
      redirect: false,
      retry: false,
      max_retries: 0,
      adapter: fn request ->
        with true <- valid_request?(request),
             remaining when remaining > 0 <- remaining(expires, cutoff),
             :ok <- :atomics.compare_exchange(latch, 1, 0, 1) do
          request = Req.merge(request, timeouts(remaining))
          started = System.monotonic_time(:microsecond)
          {request, response} = wire.(request)
          elapsed = System.monotonic_time(:microsecond) - started
          send(owner, {key, evidence(response, elapsed)})
          {request, bounded_response(response)}
        else
          _ -> {request, %Req.TransportError{reason: :closed}}
        end
      end
    ] ++ timeouts(timeout)
  end

  defp remaining(expires, cutoff) do
    min(
      expires - System.monotonic_time(:millisecond),
      DateTime.diff(cutoff, ChatwootAdapter.now(), :millisecond)
    )
  end

  defp timeouts(timeout) do
    [
      receive_timeout: timeout,
      finch: [pool_timeout: timeout],
      connect_options: [timeout: timeout, protocols: [:http1]]
    ]
  end

  defp bounded_response(%Req.Response{body: bytes})
       when is_binary(bytes) and byte_size(bytes) > @max_body_bytes,
       do: %Req.TransportError{reason: :closed}

  defp bounded_response(response), do: response

  def take(attempt, ref) do
    key = {ref, attempt.id, attempt.dispatch_fence}

    receive do
      {^key, evidence} -> evidence
    after
      0 -> :unknown
    end
  end

  defp valid_request?(%Req.Request{
         method: :post,
         url: %{
           scheme: "https",
           host: "api.openai.com",
           port: 443,
           path: "/v1/responses",
           query: nil
         },
         body: body
       })
       when is_binary(body) or is_list(body) do
    with true <- IO.iodata_length(body) <= @max_request_bytes,
         {:ok,
          %{
            "model" => @model,
            "input" => [
              %{"role" => "system", "content" => [%{"type" => "input_text", "text" => system}]},
              %{"role" => "user", "content" => [%{"type" => "input_text", "text" => data}]}
            ],
            "store" => false,
            "max_output_tokens" => limit,
            "reasoning" => %{"effort" => "none"},
            "text" => %{
              "format" => %{"type" => "json_schema", "strict" => true, "schema" => schema}
            }
          } = fields} <- body |> IO.iodata_to_binary() |> Jason.decode() do
      is_binary(system) and is_binary(data) and limit == SupportProposal.output_limit() and
        schema == SupportProposal.schema() and
        Map.keys(fields) -- ~w(model input store max_output_tokens reasoning text stream include) ==
          [] and
        Map.get(fields, "stream", false) == false and Map.get(fields, "include", []) == []
    else
      _ -> false
    end
  end

  defp valid_request?(_), do: false

  defp evidence(%Req.Response{status: 200, body: body} = response, elapsed) do
    with [request_id] <- Req.Response.get_header(response, "x-request-id"),
         true <- identifier?(request_id, ~r/\Areq_[a-zA-Z0-9_-]+\z/),
         {:ok, %{"id" => response_id, "model" => @model, "usage" => usage} = fields} <-
           decode(body),
         true <- identifier?(response_id, ~r/\Aresp_[a-zA-Z0-9_-]+\z/),
         {:ok, input, output} <- counters(usage) do
      {:usage,
       %{
         provider_request_id: request_id,
         provider_response_id: response_id,
         input_tokens: input,
         output_tokens: output,
         duration_us: elapsed
       }, raw_proposal?(fields)}
    else
      _ -> :unknown
    end
  end

  defp evidence(_, _), do: :unknown

  defp counters(
         %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => total} = usage
       )
       when is_integer(input) and input in 1..@max_count and
              is_integer(output) and output in 0..@max_count and total === input + output do
    case Map.fetch(usage, "output_tokens_details") do
      :error ->
        {:ok, input, output}

      {:ok, %{"reasoning_tokens" => tokens}} when is_integer(tokens) and tokens in 0..output//1 ->
        {:ok, input, output}

      _ ->
        :error
    end
  end

  defp counters(_), do: :error

  # Ash AI unwraps any map with a "result" key. Inspect the original
  # structured text as well so an extra wrapper cannot evade the exact cast.
  defp raw_proposal?(%{
         "status" => "completed",
         "output" => [
           %{
             "type" => "message",
             "role" => "assistant",
             "status" => "completed",
             "content" => [%{"type" => "output_text", "text" => text}]
           }
         ]
       }) do
    with {:ok, %{"result" => value} = wrapper} when map_size(wrapper) == 1 <- decode(text),
         {:ok, _} <- SupportProposal.cast(value) do
      true
    else
      _ -> false
    end
  end

  defp raw_proposal?(_), do: false

  defp decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_body_bytes,
    do: Jason.decode(bytes)

  defp decode(_), do: :error

  defp identifier?(value, pattern) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(pattern, value)

  defp identifier?(_, _), do: false
end
