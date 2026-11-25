defmodule VoelgoedAi.Feasibility.EntraProvider do
  @moduledoc false
  import ExUnit.Assertions
  import Plug.Conn

  alias VoelgoedAi.Feasibility.EntraRouter

  @host "entra.example.test"
  @tenant "78d3ded7-c72b-4172-9d1c-c4179aa2d6ab"
  @issuer "https://#{@host}/#{@tenant}/v2.0"
  @client_id "vgas-f08"
  @client_authentication_method "none"
  @redirect "https://support.example.test/staff/entra/callback"
  @authorize "https://#{@host}/authorize"

  def tenant, do: @tenant
  def issuer, do: @issuer
  def client_id, do: @client_id
  def client_authentication_method, do: @client_authentication_method
  def redirect_uri, do: @redirect

  def sign_in(context, subject, opts \\ []) do
    context |> start_sign_in(subject, opts) |> callback()
  end

  def start_sign_in(context, subject, opts \\ []) do
    exchange_count = :atomics.new(1, [])
    code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    metadata = metadata(opts)
    stub(fn conn -> discovery(conn, metadata, :available) end)

    redirect = request(context, "/staff/entra")
    assert redirect.status == 302
    [location] = get_resp_header(redirect, "location")
    url = URI.parse(location)
    assert URI.to_string(%{url | query: nil}) == @authorize

    %{"state" => state, "nonce" => nonce, "code_challenge" => challenge} =
      params = URI.decode_query(url.query)

    assert params["client_id"] == @client_id
    assert params["redirect_uri"] == @redirect
    assert params["scope"] == "openid"
    assert params["response_type"] == "code"
    assert params["code_challenge_method"] == "S256"
    assert state != "" and nonce != ""

    {token, public_key} = credentials(context.key, subject, nonce, opts)
    tokens = %{"id_token" => token, "access_token" => "synthetic-access"}
    tokens = Keyword.get(opts, :tokens, &Function.identity/1).(tokens)
    jwks = Keyword.get(opts, :jwks, &Function.identity/1).(%{"keys" => [public_key]})

    flow = %{
      context: context,
      redirect: redirect,
      params: %{"state" => state, "code" => code},
      exchange_count: exchange_count,
      tokens: tokens,
      jwks: jwks
    }

    stub(fn
      %{method: "POST", host: @host, request_path: "/token"} = conn ->
        attempt = :atomics.add_get(exchange_count, 1, 1)
        {:ok, body, conn} = read_body(conn)

        assert %{
                 "grant_type" => "authorization_code",
                 "code" => ^code,
                 "redirect_uri" => @redirect,
                 "code_verifier" => verifier
               } = URI.decode_query(body)

        assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge

        if opts[:raise_token_response], do: raise("synthetic adapter detail")

        if attempt == 1 and opts[:unavailable] != :token do
          json(conn, tokens)
        else
          send_resp(conn, 400, "")
        end

      %{method: "GET", host: @host, request_path: "/keys"} = conn ->
        if opts[:unavailable] == :keys do
          send_resp(conn, 503, "")
        else
          json(conn, jwks)
        end

      conn ->
        discovery(conn, Keyword.get(opts, :callback_metadata, metadata), opts[:unavailable])
    end)

    flow
  end

  def callback(flow), do: callback(flow, flow.params, flow.redirect)

  def callback(flow, params, cookie_source) do
    request(flow.context, "/staff/entra/callback?" <> URI.encode_query(params), cookie_source)
  end

  def request(context, path, cookie_source \\ nil) do
    conn =
      :get
      |> Plug.Test.conn("https://support.example.test" <> path)
      |> Map.put(:secret_key_base, context.cookie_key)
      |> put_private(:f08_schema, context.schema)

    conn = if cookie_source, do: Plug.Test.recycle_cookies(conn, cookie_source), else: conn
    EntraRouter.call(conn, EntraRouter.init([]))
  end

  def metadata(opts \\ []) do
    %{
      "issuer" => opts[:metadata_issuer] || @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => "https://#{@host}/token",
      "jwks_uri" => "https://#{@host}/keys",
      "token_endpoint_auth_methods_supported" => [@client_authentication_method]
    }
  end

  defp discovery(
         %{
           method: "GET",
           host: @host,
           request_path: "/#{@tenant}/v2.0/.well-known/openid-configuration"
         } =
           conn,
         metadata,
         unavailable
       ) do
    if unavailable == :callback_discovery do
      send_resp(conn, 503, "")
    else
      Req.Test.json(conn, metadata)
    end
  end

  defp discovery(_conn, _metadata, _unavailable), do: flunk("Unexpected fixture HTTP request")

  defp stub(handler), do: Req.Test.stub(__MODULE__, handler)

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp credentials(key, subject, nonce, opts) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => @issuer,
        "tid" => @tenant,
        "sub" => subject,
        "aud" => @client_id,
        "nonce" => nonce,
        "iat" => now,
        "exp" => now + 300,
        "email" => "fixture@example.test",
        "email_verified" => true,
        "oid" => "synthetic-object",
        "roles" => ["ADMIN", "KNOWLEDGE_REVIEWER"],
        "groups" => ["synthetic-group"]
      }
      |> Map.merge(opts[:claims] || %{})
      |> Map.drop(opts[:omit] || [])

    signing_key = opts[:signing_key] || key
    algorithm = opts[:algorithm] || "RS256"
    kid = opts[:kid] || "fixture-key"

    header = %{"alg" => algorithm, "kid" => kid}

    token =
      if opts[:header] || opts[:payload] || algorithm == "none" do
        header = Keyword.get(opts, :header, &Function.identity/1).(header)
        claims = Keyword.get(opts, :payload, &Function.identity/1).(claims)
        compact_fixture_jws(signing_key, algorithm, header, claims)
      else
        {_, token} = signing_key |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
        token
      end

    {_, public_key} = JOSE.JWK.to_public_map(key)
    {token, Map.put(public_key, "kid", "fixture-key")}
  end

  # JOSE's signer builds only well-formed headers. Sign the fixture input
  # directly so a malformed protected header still carries a real signature.
  defp compact_fixture_jws(key, algorithm, header, claims) do
    encoded_header = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    encoded_claims = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    input = encoded_header <> "." <> encoded_claims
    {_, rsa_key} = JOSE.JWK.to_key(key)

    signature = if algorithm == "none", do: "", else: :public_key.sign(input, :sha256, rsa_key)
    input <> "." <> Base.url_encode64(signature, padding: false)
  end
end
