defmodule VoelgoedAi.Feasibility.EntraSubject do
  @moduledoc false

  # OIDC Core §2 limits subjects to 255 ASCII characters. The local spike
  # also rejects controls and boundary spaces while preserving accepted bytes.
  @pattern ~r/\A[!-~](?:[ -~]{0,253}[!-~])?\z/

  def pattern, do: @pattern
  def valid?(subject), do: is_binary(subject) and Regex.match?(@pattern, subject)
end

defmodule VoelgoedAi.Feasibility.EntraOIDCResponse do
  @moduledoc false

  alias VoelgoedAi.Feasibility.EntraSubject

  # Local fixture limits. These checks inspect untrusted shapes only.
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

  def valid_jwks?(%{"keys" => [_ | _] = keys}), do: Enum.all?(keys, &valid_key?/1)
  def valid_jwks?(_), do: false

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
    with {:ok, json} <- Base.url_decode64(segment, padding: false), do: Jason.decode(json)
  end

  defp valid_header?(%{"alg" => "RS256", "kid" => kid} = header) do
    text?(kid) and optional?(header, "typ", &text?/1) and
      optional?(header, "cty", &text?/1) and
      optional?(header, "b64", &(&1 === true)) and
      not Map.has_key?(header, "crit")
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
    text?(issuer) and EntraSubject.valid?(subject) and valid_audience?(audience) and
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
      not Map.has_key?(key, "d")
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

defmodule VoelgoedAi.Feasibility.EntraOIDCCallback do
  @moduledoc false
  @behaviour Assent.Strategy
  require Logger

  @impl true
  defdelegate authorize_url(config), to: Assent.Strategy.OIDC

  @impl true
  def callback(config, params) do
    decode(fn -> Assent.Strategy.OIDC.callback(config, params) end)
  end

  def peek_claims(token) do
    decode(fn -> {:ok, JOSE.JWT.peek_payload(token).fields} end)
  end

  # Keep both dependency calls separate from policy and activation code.
  # Fixture assertions raised inside the Req stub must still fail the test
  # instead of looking like an ordinary denial.
  defp decode(dependency_call) do
    dependency_call.()
  rescue
    error in ExUnit.AssertionError ->
      reraise error, __STACKTRACE__

    _ ->
      Logger.warning("entra_oidc_callback_exception")
      {:error, :entra_oidc_callback_exception}
  end
end
