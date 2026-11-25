defmodule VoelgoedAi.Feasibility.TransportEvidence do
  @moduledoc """
  Captures whitelisted evidence at the Req adapter boundary, before ReqLLM
  parses output. The spike adapter can only call a local Req.Test plug.

  Reserve against the published full context or single-input limit, including
  all message and schema overhead. Use standard OpenAI list-price upper rates
  in integer nano-USD. These figures are ceiling estimates, not invoices.
  """
  alias VoelgoedAi.Feasibility.DurableLedger
  alias VoelgoedAi.Repo

  @luna "gpt-6-luna"
  @embedding "text-embedding-3-small"
  @rates %{
    @luna => {1_050_000, 500, 500, 750},
    @embedding => {8192, 20, 0, 0}
  }

  def ceiling(model) do
    case Map.fetch(@rates, model) do
      {:ok, {input, input_rate, output, output_rate}} ->
        {:ok, input * input_rate + output * output_rate}

      :error ->
        {:error, :unpriced_model}
    end
  end

  def run(table, id, day, model, limits, call) do
    with false <- Repo.in_transaction?(),
         {:ok, ceiling} <- ceiling(model),
         :ok <- DurableLedger.reserve(table, id, day, model, ceiling, limits) do
      result = invoke(call, {table, id, model})

      case DurableLedger.recover(table, id, result_status(result)) do
        {:ok, "settled"} -> result
        {:ok, "released"} -> {:error, :not_sent}
        {:ok, "unknown"} -> {:error, :unknown}
        {:error, _} = error -> error
      end
    else
      true -> {:error, :open_transaction}
      {:error, _} = error -> error
    end
  end

  defp invoke(call, attempt) do
    call.(attempt)
  rescue
    _error -> {:error, :execution_error}
  end

  defp result_status({:ok, _}), do: "accepted"
  defp result_status({:error, _}), do: "rejected"

  def options({table, id, model}, fake) do
    [
      receive_timeout: 5000,
      retry: false,
      redirect: false,
      adapter: fn request ->
        with :ok <- validate(request, model),
             :ok <- DurableLedger.claim(table, id) do
          started = System.monotonic_time(:microsecond)

          {request, outcome} =
            request
            |> Req.merge(plug: {Req.Test, fake})
            |> Req.Plug.run()

          elapsed = System.monotonic_time(:microsecond) - started
          evidence = evidence(outcome, model, elapsed)

          case DurableLedger.record(table, id, evidence) do
            :ok -> {request, outcome}
            {:error, _} -> transport_error(request, "evidence unavailable")
          end
        else
          {:error, _} -> transport_error(request, "dispatch denied")
        end
      end
    ]
  end

  defp validate(
         %Req.Request{
           method: :post,
           body: body,
           url: %{scheme: "https", host: "api.openai.com", path: path}
         },
         model
       )
       when is_binary(body) or is_list(body) do
    with true <- IO.iodata_length(body) <= 32_768,
         {:ok, wire} <- body |> IO.iodata_to_binary() |> Jason.decode(),
         true <- allowed?(path, model, wire) do
      :ok
    else
      _ -> {:error, :unbounded}
    end
  end

  defp validate(_request, _model), do: {:error, :unbounded}

  defp allowed?(
         "/v1/responses",
         @luna,
         %{
           "model" => @luna,
           "input" => input,
           "store" => false,
           "max_output_tokens" => 500,
           "reasoning" => %{"effort" => "none"},
           "text" => %{"format" => %{"type" => "json_schema", "strict" => true}}
         } = wire
       ) do
    is_list(input) and
      Enum.all?(input, fn
        %{"role" => role, "content" => contents}
        when role in ["system", "developer", "user", "assistant"] and is_list(contents) ->
          Enum.all?(
            contents,
            &match?(%{"type" => "input_text", "text" => text} when is_binary(text), &1)
          )

        _ ->
          false
      end) and
      Map.keys(wire) -- ~w(model input store max_output_tokens reasoning text stream include) ==
        []
  end

  defp allowed?(
         "/v1/embeddings",
         @embedding,
         %{
           "model" => @embedding,
           "dimensions" => 1536,
           "input" => input
         } = wire
       ) do
    single_embedding_input?(input) and
      Map.keys(wire) -- ~w(model dimensions input encoding_format) == []
  end

  defp allowed?(_path, _model, _wire), do: false

  defp single_embedding_input?([input]) when is_binary(input), do: single_embedding_input?(input)
  defp single_embedding_input?(input), do: is_binary(input) and byte_size(input) in 1..8192

  defp evidence(%Req.Response{status: status, body: body} = response, requested, elapsed) do
    fields = decode_fields(body)
    usage = usage(fields["usage"], requested)
    provider_model = identifier(fields["model"])

    request_id =
      response |> Req.Response.get_header("x-request-id") |> List.first() |> identifier()

    response_id = identifier(fields["id"])

    charge =
      if (request_id || response_id) && fields["model"] in [nil, requested],
        do: cost(usage, requested)

    %{
      "request_id" => request_id,
      "response_id" => response_id,
      "provider_model" => provider_model,
      "status" => status,
      "usage" => usage,
      "duration_us" => elapsed,
      "classification" => if(status in 200..299, do: "http_success", else: "http_failure"),
      "charge" => charge
    }
  end

  defp evidence(error, _requested, elapsed) do
    %{
      "duration_us" => elapsed,
      "classification" =>
        if(match?(%Req.TransportError{reason: :timeout}, error),
          do: "timeout",
          else: "transport_error"
        )
    }
  end

  defp decode_fields(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, fields} when is_map(fields) -> fields
      _ -> %{}
    end
  end

  defp decode_fields(fields) when is_map(fields), do: fields
  defp decode_fields(_), do: %{}

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = values, @luna)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    reasoning = get_in(values, ["output_tokens_details", "reasoning_tokens"])

    Map.put(
      %{"input" => input, "output" => output},
      "reasoning",
      if(is_integer(reasoning) and reasoning >= 0, do: reasoning)
    )
  end

  defp usage(%{"prompt_tokens" => input}, @embedding) when is_integer(input) and input >= 0,
    do: %{"input" => input, "output" => 0}

  defp usage(_values, _model), do: nil

  defp cost(nil, _model), do: nil

  defp cost(%{"input" => input, "output" => output} = usage, model) do
    {_, input_rate, _, output_rate} = Map.fetch!(@rates, model)
    billed_output = max(output, usage["reasoning"] || 0)
    input * input_rate + billed_output * output_rate
  end

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..128 do
    if Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, value), do: value
  end

  defp identifier(_), do: nil

  defp transport_error(request, reason), do: {request, RuntimeError.exception(reason)}
end
