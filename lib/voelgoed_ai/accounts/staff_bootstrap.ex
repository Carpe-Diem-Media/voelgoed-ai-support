defmodule VoelgoedAi.Accounts.StaffBootstrap do
  @moduledoc """
  Read a first-administrator invitation approved by the Entra registration owner.
  The operator supplies the allowlist evidence over standard input.
  """

  alias VoelgoedAi.Accounts
  alias VoelgoedAi.Accounts.EntraOIDC

  @max_input_bytes 4096

  @doc "Invite the first administrator and return only a bounded outcome."
  def from_stdin do
    case IO.binread(:stdio, @max_input_bytes + 1) do
      input when is_binary(input) -> from_json(input)
      _ -> {:error, :invalid_bootstrap_input}
    end
  end

  @doc false
  def from_json(input) when is_binary(input) and byte_size(input) <= @max_input_bytes do
    with {:ok,
          %{
            "issuer" => issuer,
            "subject" => subject,
            "tenant_id" => tenant,
            "client_id" => client,
            "roles" => ["ADMIN"]
          } = evidence}
         when map_size(evidence) == 5 <- EntraOIDC.decode_json(input) do
      case Accounts.bootstrap(
             %{issuer: issuer, subject: subject, tenant_id: tenant, client_id: client},
             [:admin]
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      _ -> {:error, :invalid_bootstrap_input}
    end
  end

  def from_json(_), do: {:error, :invalid_bootstrap_input}
end
