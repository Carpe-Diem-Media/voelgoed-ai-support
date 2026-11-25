defmodule VoelgoedAi.Accounts.EntraConfig do
  @moduledoc """
  Validates the trusted registration configuration before staff authentication.
  The registration can be specified before the staff routes are enabled.
  """

  use AshAuthentication.Secret

  @tenant_pattern ~r/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/
  @subject_pattern ~r/\A[!-~](?:[ -~]{0,253}[!-~])?\z/
  @origin "https://login.microsoftonline.com"
  @callback_path "/staff/entra/callback"

  def subject_pattern, do: @subject_pattern
  def valid_subject?(value), do: is_binary(value) and Regex.match?(@subject_pattern, value)
  def uuid_text?(value), do: is_binary(value) and Regex.match?(@tenant_pattern, value)
  def issuer(tenant), do: "#{@origin}/#{tenant}/v2.0"
  def origin, do: @origin
  def callback_path, do: @callback_path

  @doc "Return the configured tenant and confidential client identifiers."
  def registration do
    settings = Application.get_env(:voelgoed_ai, :entra, [])
    tenant = settings[:tenant_id]
    client = settings[:client_id]

    if uuid_text?(tenant) and uuid_text?(client) do
      {:ok, %{tenant_id: tenant, client_id: client, issuer: issuer(tenant)}}
    else
      {:error, :invalid_registration}
    end
  end

  @doc "Require the approved registration and complete configuration before any staff route or session use."
  def enabled do
    settings = Application.get_env(:voelgoed_ai, :entra, [])

    with true <- settings[:enabled] == true,
         {:ok, registration} <- registration(),
         true <- valid_text?(settings[:client_secret], 4096),
         true <- valid_callback?(settings[:redirect_uri]),
         key when is_binary(key) and byte_size(key) >= 64 <-
           VoelgoedAiWeb.Endpoint.config(:secret_key_base) do
      {:ok, registration}
    else
      _ -> {:error, :staff_auth_unavailable}
    end
  end

  @impl true
  def secret_for([:authentication, :strategies, :entra, field], _, _, _)
      when field in [:base_url, :client_id, :client_secret, :redirect_uri] do
    with {:ok, registration} <- enabled() do
      case field do
        :base_url -> {:ok, registration.issuer}
        :client_id -> {:ok, registration.client_id}
        _ -> {:ok, Application.fetch_env!(:voelgoed_ai, :entra)[field]}
      end
    else
      _ -> :error
    end
  end

  def secret_for(_, _, _, _), do: :error

  defp valid_callback?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: 443,
         path: @callback_path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) ->
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/, host)

      _ ->
        false
    end
  end

  defp valid_callback?(_), do: false

  defp valid_text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        String.trim(value) != ""
end
