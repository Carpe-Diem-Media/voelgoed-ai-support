defmodule VoelgoedAi.Feasibility.Inference do
  @moduledoc """
  Exercises admission, request options and reconciliation with synthetic
  transport functions. Prices are fixed synthetic nano-USD per token.
  """
  alias VoelgoedAi.Feasibility.Reservations

  @max_input_bytes 4096
  @max_output_tokens 500
  @timeout 5000
  @generation %{model: "openai:gpt-6-luna", input_rate: 1, output_rate: 10}
  @embedding %{model: "openai:text-embedding-3-small", input_rate: 2, output_rate: 0}

  def run(ledger, id, day, operation, input, transport)
      when is_binary(input) and is_function(transport, 1) do
    with {:ok, request, price, ceiling} <- prepare(operation, input),
         :ok <- Reservations.reserve(ledger, id, day, ceiling) do
      transport
      |> invoke(request)
      |> reconcile(ledger, id, operation, price)
    end
  end

  def cast_proposal(%{"decision" => "handoff"} = proposal) when map_size(proposal) == 1,
    do: {:ok, :handoff}

  def cast_proposal(%{"decision" => "clarify"} = proposal) when map_size(proposal) == 1,
    do: {:ok, :clarify}

  def cast_proposal(_), do: {:error, :invalid_proposal}

  def generation_options do
    [
      max_completion_tokens: @max_output_tokens,
      reasoning_effort: :none,
      openai_structured_output_mode: :json_schema,
      provider_options: [store: false],
      max_retries: 0
    ] ++ transport_options()
  end

  defp transport_options do
    [
      total_timeout: @timeout,
      # ReqLLM's retry step replaces `retry: false` and reads only `max_retries`.
      req_http_options: [receive_timeout: @timeout, retry: false, max_retries: 0]
    ]
  end

  defp prepare(_operation, input) when byte_size(input) > @max_input_bytes,
    do: {:error, :input_limit}

  defp prepare(:generation, input) do
    request = %{model: @generation.model, input: input, options: generation_options()}

    ceiling =
      @max_input_bytes * @generation.input_rate + @max_output_tokens * @generation.output_rate

    {:ok, request, @generation, ceiling}
  end

  defp prepare(:embedding, input) do
    options = [dimensions: 1536, return_usage: true] ++ transport_options()
    request = %{model: @embedding.model, input: input, options: options}
    {:ok, request, @embedding, @max_input_bytes * @embedding.input_rate}
  end

  defp invoke(transport, request) do
    transport.(request)
  rescue
    _error -> {:error, :ambiguous}
  catch
    :exit, _reason -> {:error, :ambiguous}
  end

  defp reconcile({:error, :not_sent}, ledger, id, _operation, _price) do
    :ok = Reservations.finish(ledger, id, :release)
    {:error, :not_sent}
  end

  defp reconcile({:ok, response}, ledger, id, operation, price) do
    with %{request_id: request_id, usage: usage}
         when is_binary(request_id) and byte_size(request_id) > 0 <-
           response,
         {:ok, actual} <- cost(usage, price) do
      :ok = Reservations.finish(ledger, id, {:settle, actual, request_id})
      validate(operation, response)
    else
      _ -> unknown(ledger, id)
    end
  end

  defp reconcile(_outcome, ledger, id, _operation, _price), do: unknown(ledger, id)

  defp unknown(ledger, id) do
    :ok = Reservations.finish(ledger, id, :unknown)
    {:error, :unknown}
  end

  defp cost(%{input_tokens: input}, %{input_rate: rate, output_rate: 0})
       when is_integer(input) and input >= 0,
       do: {:ok, input * rate}

  defp cost(%{input_tokens: input, output_tokens: output}, price)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: {:ok, input * price.input_rate + output * price.output_rate}

  defp cost(_usage, _price), do: :error

  defp validate(:generation, %{object: %{"result" => proposal} = envelope})
       when map_size(envelope) == 1,
       do: cast_proposal(proposal)

  defp validate(:generation, _), do: {:error, :invalid_proposal}

  defp validate(:embedding, %{object: vector}) when is_list(vector) and length(vector) == 1536 do
    if Enum.all?(vector, &is_float/1), do: {:ok, vector}, else: {:error, :invalid_embedding}
  end

  defp validate(:embedding, _), do: {:error, :invalid_embedding}
end
