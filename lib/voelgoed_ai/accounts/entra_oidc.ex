defmodule VoelgoedAi.Accounts.EntraOIDC do
  @moduledoc "Keeps the production OIDC flow on the verified single-tenant transport."
  @behaviour Assent.Strategy

  alias VoelgoedAi.Accounts.{EntraConfig, EntraHTTPAdapter, EntraPendingStates}

  @impl true
  def authorize_url(config) do
    with {:ok, config} <- transport(config),
         {:ok, %{session_params: %{state: state}} = redirect} <-
           Assent.Strategy.OIDC.authorize_url(config),
         :ok <- EntraPendingStates.remember(state) do
      {:ok, redirect}
    end
  end

  @impl true
  def callback(config, %{"code" => code, "state" => state} = params)
      when is_binary(code) and byte_size(code) in 1..4096 and
             is_binary(state) and byte_size(state) in 1..256 do
    with {:ok, config} <- transport(config),
         %{state: saved, nonce: nonce, code_verifier: verifier} <- config[:session_params],
         true <- is_binary(saved) and is_binary(nonce) and is_binary(verifier),
         true <- Plug.Crypto.secure_compare(state, saved) and EntraPendingStates.consume(saved) do
      Assent.Strategy.OIDC.callback(config, Map.take(params, ["code", "state", "error"]))
    else
      _ -> {:error, :invalid_callback}
    end
  rescue
    # Limit handling to parser errors at the dependency boundary. An
    # unexpected test-fixture call or assertion must still fail its test.
    _ in [
      ArgumentError,
      BadMapError,
      FunctionClauseError,
      KeyError,
      MatchError,
      Protocol.UndefinedError
    ] ->
      {:error, :invalid_callback}
  end

  def callback(_, _), do: {:error, :invalid_callback}

  defp transport(config) do
    with {:ok, registration} <- EntraConfig.enabled(),
         true <-
           config[:base_url] == registration.issuer and
             config[:client_id] == registration.client_id do
      {:ok, Keyword.put(config, :http_adapter, {EntraHTTPAdapter, registration})}
    else
      _ -> {:error, :invalid_registration}
    end
  end

  @doc "Decode bounded provider JSON and reject duplicate members before library parsing."
  def decode_json(body) do
    with {:ok, parsed} <- Jason.decode(body, objects: :ordered_objects) do
      {:ok, unique_members(parsed, 0)}
    end
  catch
    :invalid_json_members -> {:error, :invalid_json_members}
  end

  defp unique_members(_, depth) when depth > 32, do: throw(:invalid_json_members)

  defp unique_members(%Jason.OrderedObject{values: members}, depth) do
    Enum.reduce(members, %{}, fn {key, value}, acc ->
      if Map.has_key?(acc, key), do: throw(:invalid_json_members)
      Map.put(acc, key, unique_members(value, depth + 1))
    end)
  end

  defp unique_members(list, depth) when is_list(list),
    do: Enum.map(list, &unique_members(&1, depth + 1))

  defp unique_members(value, _), do: value
end

defmodule VoelgoedAi.Accounts.EntraOIDC.Claims do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  alias VoelgoedAi.Accounts.{EntraConfig, StaffAccess}
  alias VoelgoedAi.Accounts.EntraOIDC.Response
  alias VoelgoedAi.Accounts.StaffAccess.Scope

  @impl true
  def prepare(query, _, %{actor: %Scope{action: :sign_in_with_entra, target: binding}}) do
    # The native callback verifies the token before invoking this preparation.
    # Recover the protocol claims trimmed by Assent and cross-check the
    # identity it returned before selecting the row.
    with true <- get_in(query.context, [:private, :ash_authentication?]),
         {:ok, %{issuer: issuer, tenant_id: tenant, client_id: client} = registration} <-
           EntraConfig.enabled(),
         true <- binding == StaffAccess.registration_binding(registration),
         %{"sub" => subject, "tid" => ^tenant} <- Ash.Query.get_argument(query, :user_info),
         %{"id_token" => token} <- Ash.Query.get_argument(query, :oauth_tokens),
         {:ok, %{"iss" => ^issuer, "sub" => ^subject, "tid" => ^tenant} = claims} <-
           Response.claims(token),
         true <- EntraConfig.valid_subject?(subject) and valid_times?(claims) do
      Ash.Query.filter(
        query,
        identity_issuer == ^issuer and identity_subject == ^subject and tenant_id == ^tenant and
          identity_client_id == ^client and status in [:invited, :active]
      )
    else
      _ -> deny(query)
    end
  end

  # Let the action policy deny untrusted actors before any query executes.
  def prepare(query, _, _), do: query

  defp deny(query) do
    Ash.Query.add_error(
      query,
      Ash.Error.Query.InvalidArgument.exception(field: :user_info, message: "Invalid identity")
    )
  end

  defp valid_times?(%{"exp" => expiry, "iat" => issued_at} = claims) do
    now = System.system_time(:second)
    not_before = Map.get(claims, "nbf", now)

    is_integer(expiry) and expiry > now and is_integer(issued_at) and issued_at <= now and
      is_integer(not_before) and not_before <= now
  end
end

defmodule VoelgoedAi.Accounts.EntraOIDC.Response do
  @moduledoc false

  alias VoelgoedAi.Accounts.{EntraConfig, EntraOIDC}

  # Preserve the F08 shape checks and size limits. These checks inspect untrusted shapes only.
  # Assent still verifies the signature and OIDC bindings.
  @max_token_bytes 32_768
  @max_text_bytes 4_096

  def valid_tokens?(%{"id_token" => token, "access_token" => access_token} = tokens) do
    valid_id_token?(token) and compact_token?(access_token) and
      optional?(tokens, "token_type", &text?/1) and
      optional?(tokens, "refresh_token", &compact_token?/1) and
      optional?(tokens, "expires_in", &is_integer/1) and
      optional?(tokens, "scope", &text?/1)
  end

  def valid_tokens?(_), do: false

  def valid_jwks?(%{"keys" => [_ | _] = keys}) when length(keys) <= 32 do
    Enum.all?(keys, &valid_key?/1) and
      keys |> Enum.map(& &1["kid"]) |> Enum.uniq() |> length() == length(keys)
  end

  def valid_jwks?(_), do: false

  def claims(token) when is_binary(token) and byte_size(token) <= @max_token_bytes do
    case :binary.split(token, ".", [:global]) do
      [_header, payload, _signature] -> decode_json(payload)
      _ -> {:error, :invalid_token}
    end
  end

  def claims(_), do: {:error, :invalid_token}

  defp valid_id_token?(token) when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with [header, claims, signature] <- :binary.split(token, ".", [:global]),
         true <- base64url?(signature),
         {:ok, header} <- decode_json(header),
         true <- valid_header?(header),
         {:ok, claims} <- decode_json(claims) do
      valid_claims?(claims)
    else
      _ -> false
    end
  end

  defp valid_id_token?(_), do: false

  defp decode_json(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         do: EntraOIDC.decode_json(json)
  end

  defp valid_header?(%{"alg" => "RS256", "kid" => kid} = header) do
    Enum.all?(Map.keys(header), &(&1 in ~w(alg kid typ cty b64 x5t x5t#S256))) and
      text?(kid) and optional?(header, "typ", &text?/1) and
      optional?(header, "cty", &text?/1) and
      optional?(header, "b64", &(&1 === true)) and
      optional?(header, "x5t", &text?/1) and optional?(header, "x5t#S256", &text?/1)
  end

  defp valid_header?(_), do: false

  defp valid_claims?(
         %{
           "iss" => issuer,
           "sub" => subject,
           "aud" => audience,
           "exp" => expiry,
           "iat" => issued_at,
           "nonce" => nonce,
           "tid" => tenant
         } = claims
       ) do
    text?(issuer) and EntraConfig.valid_subject?(subject) and valid_audience?(audience) and
      is_integer(expiry) and is_integer(issued_at) and text?(nonce) and text?(tenant) and
      optional?(claims, "azp", &text?/1) and optional?(claims, "nbf", &is_integer/1)
  end

  defp valid_claims?(_), do: false

  defp valid_audience?([_ | _] = audience), do: Enum.all?(audience, &text?/1)
  defp valid_audience?(audience), do: text?(audience)

  # Entra publishes 2048-bit RSA keys with exponent 65537 ("AQAB"). Accept
  # 2048-4096 bit moduli so weak or oversized keys never reach Assent.
  defp valid_key?(%{"kty" => "RSA", "kid" => kid, "n" => modulus, "e" => "AQAB"} = key) do
    text?(kid) and rsa_modulus?(modulus) and
      optional?(key, "use", &text?/1) and optional?(key, "alg", &text?/1) and
      not Enum.any?(~w(d p q dp dq qi oth k), &Map.has_key?(key, &1))
  end

  defp valid_key?(_), do: false

  defp base64url?(value) do
    text?(value) and match?({:ok, <<_, _::binary>>}, Base.url_decode64(value, padding: false))
  end

  defp rsa_modulus?(value) do
    text?(value) and
      case Base.url_decode64(value, padding: false) do
        {:ok, <<1::1, _::bitstring>> = bytes} -> byte_size(bytes) in 256..512
        _ -> false
      end
  end

  # Access and refresh tokens are opaque here but can be JWTs that grow with
  # claims, so they share the compact-token bound rather than the text bound.
  defp compact_token?(value),
    do: is_binary(value) and byte_size(value) in 1..@max_token_bytes

  defp text?(value), do: is_binary(value) and byte_size(value) in 1..@max_text_bytes

  defp optional?(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} -> valid?.(value)
      :error -> true
    end
  end
end
