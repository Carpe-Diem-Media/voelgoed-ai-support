defmodule VoelgoedAi.Accounts.EntraHTTPAdapter do
  @moduledoc "Allowlisted HTTPS transport for discovery, token exchange and signing keys."

  @behaviour Assent.HTTPAdapter
  alias Assent.HTTPAdapter.HTTPResponse
  alias VoelgoedAi.Accounts.{EntraConfig, EntraOIDC}
  alias VoelgoedAi.Accounts.EntraOIDC.Response

  @body_limit 131_072
  @fixture_transport Application.compile_env(:voelgoed_ai, :entra_fixture_transport, nil)

  @impl true
  def request(method, url, body, headers, registration) do
    endpoints = endpoints(registration)

    with {:ok, phase} <- permitted_request(method, url, endpoints),
         {:ok, %Req.Response{status: 200, body: raw} = response} <-
           request_once(method, url, body, headers),
         true <- is_binary(raw) and byte_size(raw) <= @body_limit and json_response?(response),
         {:ok, parsed} <- EntraOIDC.decode_json(raw),
         true <- valid_response?(phase, parsed, endpoints) do
      {:ok, %HTTPResponse{status: 200, body: parsed}}
    else
      _ -> {:error, :provider_response_denied}
    end
  end

  defp endpoints(%{issuer: issuer, tenant_id: tenant}) do
    origin = EntraConfig.origin()
    oauth = "#{origin}/#{tenant}/oauth2/v2.0"

    %{
      issuer: issuer,
      discovery: issuer <> "/.well-known/openid-configuration",
      authorize: oauth <> "/authorize",
      token: oauth <> "/token",
      keys: ["#{origin}/#{tenant}/discovery/v2.0/keys", "#{origin}/common/discovery/v2.0/keys"]
    }
  end

  defp permitted_request(:get, url, %{discovery: url}), do: {:ok, :discovery}
  defp permitted_request(:post, url, %{token: url}), do: {:ok, :token}

  defp permitted_request(:get, url, %{keys: keys}) when is_binary(url) do
    if url in keys, do: {:ok, :keys}, else: :error
  end

  defp permitted_request(_, _, _), do: :error

  defp request_once(method, url, body, headers) do
    opts = [
      method: method,
      url: url,
      body: body,
      headers: headers ++ [Assent.HTTPAdapter.user_agent_header()],
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      finch: [
        protocols: [:http1],
        conn_opts: [transport_opts: [timeout: 2_000]],
        pool_timeout: 1_000,
        receive_timeout: 3_000,
        request_timeout: 5_000
      ],
      into: &collect_bounded/2
    ]

    Req.request(fixture_options(opts))
  rescue
    # Finch may raise when checkout hits the pool deadline.
    _ in RuntimeError -> {:error, :provider_transport_failed}
  end

  if @fixture_transport do
    defp fixture_options(opts) do
      case Process.get({__MODULE__, :loopback_port}) do
        port when is_integer(port) and port in 1..65_535 ->
          # Rewrite only after the production endpoint allowlist accepts the request.
          url =
            opts[:url]
            |> URI.parse()
            |> then(&%{&1 | scheme: "http", host: "127.0.0.1", port: port, authority: nil})

          Keyword.put(opts, :url, URI.to_string(url))

        nil ->
          Keyword.put(opts, :plug, @fixture_transport)
      end
    end
  else
    defp fixture_options(opts), do: opts
  end

  defp collect_bounded({:data, data}, {request, response}) do
    if byte_size(response.body) + byte_size(data) <= @body_limit do
      {:cont, {request, %{response | body: response.body <> data}}}
    else
      {:halt, {request, %{response | body: :oversized}}}
    end
  end

  defp json_response?(response) do
    case Req.Response.get_header(response, "content-type") do
      ["application/json" <> rest] -> rest == "" or String.starts_with?(rest, ";")
      _ -> false
    end
  end

  # Validate discovery before Assent uses any of its URLs, on both legs.
  defp valid_response?(
         :discovery,
         %{
           "issuer" => issuer,
           "authorization_endpoint" => authorize,
           "token_endpoint" => token,
           "jwks_uri" => keys,
           "token_endpoint_auth_methods_supported" => methods
         },
         %{issuer: issuer, authorize: authorize, token: token, keys: allowed_keys}
       ) do
    keys in allowed_keys and is_list(methods) and Enum.all?(methods, &is_binary/1) and
      "client_secret_post" in methods
  end

  defp valid_response?(:discovery, _, _), do: false
  defp valid_response?(:token, tokens, _), do: Response.valid_tokens?(tokens)
  defp valid_response?(:keys, jwks, _), do: Response.valid_jwks?(jwks)
end
