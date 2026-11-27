defmodule VoelgoedAi.Intelligence.EmbeddingTransport do
  @moduledoc false

  alias VoelgoedAi.Intelligence.Embedding
  alias VoelgoedAi.Intelligence.EmbeddingProfile, as: Profile
  alias VoelgoedAi.Intelligence.GenerationTransport

  @base_url "https://api.openai.com/v1"
  @fixture_key "synthetic-embedding-fixture"
  @model "text-embedding-3-small"

  def invoke(ref, input, timeout, mode) do
    if Embedding.authorize_transport(ref), do: request(input, timeout, mode), else: :unknown
  end

  defp request(input, timeout, mode) do
    owner = self()
    ref = make_ref()
    {key, wire} = wire(mode)

    result =
      ReqLLM.embed("openai:" <> @model, input,
        api_key: key,
        base_url: @base_url,
        dimensions: Profile.dimensions(),
        return_usage: true,
        telemetry: [payloads: :none],
        total_timeout: timeout,
        req_http_options: [
          adapter: &capture(&1, wire, owner, ref),
          redirect: false,
          retry: false,
          max_retries: 0,
          receive_timeout: timeout,
          finch: [pool_timeout: timeout],
          connect_options: [timeout: timeout, protocols: [:http1]]
        ]
      )

    receive do
      {^ref, {:ok, request_id, tokens}} -> {:usage, request_id, tokens, vector(result)}
    after
      0 -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp vector({:ok, %{embedding: vector}}), do: Profile.vector(vector)
  defp vector(_), do: {:error, :invalid_vector}

  defp capture(request, wire, owner, ref) do
    case wire.(request) do
      {request, %Req.Response{status: 200} = response} ->
        send(owner, {ref, evidence(response)})
        {request, response}

      pair ->
        pair
    end
  end

  defp evidence(%Req.Response{body: body} = response) do
    with [request_id] <- Req.Response.get_header(response, "x-request-id"),
         true <- is_binary(request_id) and byte_size(request_id) in 1..128,
         true <- Regex.match?(~r/\Areq_[A-Za-z0-9_-]+\z/, request_id),
         {:ok,
          %{"model" => @model, "usage" => %{"prompt_tokens" => tokens, "total_tokens" => tokens}}} <-
           decode(body),
         true <- is_integer(tokens) and tokens in 1..9_223_372_036_854_775_807 do
      {:ok, request_id, tokens}
    else
      _ -> :unknown
    end
  end

  defp decode(body) when is_map(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: :error

  def fixture_wire(request) do
    body = %{
      "object" => "list",
      "model" => @model,
      "data" => [
        %{"object" => "embedding", "index" => 0, "embedding" => [1.0 | List.duplicate(0.0, 1535)]}
      ],
      "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
    }

    {request,
     Req.Response.new(
       status: 200,
       headers: [{"x-request-id", "req_" <> Ash.UUIDv7.generate()}],
       body: body
     )}
  end

  # Query inputs can contain public customer text. The pinned ReqLLM
  # exception metadata can include it even when payload telemetry is off.
  defp wire({:query_fixture, fun}), do: {@fixture_key, &private_query(&1, fun)}
  defp wire({:fixture, fun}), do: {@fixture_key, fun}

  # Reserved for the separately approved provider gate. Embedding never
  # selects this adapter in B1, even when OPENAI_API_KEY is present.
  defp wire({:candidate, key}), do: {key, &Req.Finch.run/1}

  defp private_query(request, wire) do
    request = GenerationTransport.protect_errors(request)

    case wire.(request) do
      {request, %Req.Response{status: status}} when status != 200 ->
        {request,
         ReqLLM.Error.API.Request.exception(reason: "embedding HTTP failure", status: status)}

      pair ->
        pair
    end
  rescue
    _ ->
      {GenerationTransport.protect_errors(request),
       ReqLLM.Error.API.Request.exception(reason: "embedding request failed")}
  end
end
