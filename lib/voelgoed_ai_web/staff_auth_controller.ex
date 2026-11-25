defmodule VoelgoedAiWeb.StaffAuthController do
  @moduledoc false
  use Phoenix.Controller, formats: []
  use AshAuthentication.Phoenix.Controller

  alias AshAuthentication.{Info, Plug.Dispatcher}
  alias VoelgoedAi.Accounts
  alias VoelgoedAi.Accounts.{EntraOIDC, StaffLifecycle, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.Scope
  alias VoelgoedAiWeb.StaffSession

  def request(conn, _params) do
    conn |> StaffSession.begin_sign_in() |> dispatch(:request)
  end

  def callback(conn, _params) do
    with true <- StaffSession.pending?(conn),
         {:ok, conn} <- callback_params(conn) do
      scope = %Scope{action: :sign_in_with_entra, target: StaffSession.flow_binding(conn)}
      conn |> Ash.PlugHelpers.set_actor(scope) |> dispatch(:callback)
    else
      _ -> failure(conn, {:entra, :callback}, :invalid_flow)
    end
  end

  defp callback_params(conn) do
    {:ok, fetch_query_params(conn, length: 8192)}
  rescue
    _ in Plug.Conn.InvalidQueryError -> {:error, :invalid_query}
  end

  def session(conn, _params) do
    case Accounts.read_self(StaffSession.actor(conn)) do
      {:ok, staff} ->
        json(conn, %{staff: staff, csrf_token: Plug.CSRFProtection.get_csrf_token()})

      {:error, _} ->
        deny(conn, :invalid_session)
    end
  end

  @impl true
  def success(conn, {:entra, :callback} = activity, candidate, _token) do
    case StaffLifecycle.authenticate(candidate, Ash.PlugHelpers.get_actor(conn)) do
      {:ok, session} ->
        conn |> clear_auth_result() |> StaffSession.put(session) |> send_resp(204, "")

      {:error, _} ->
        failure(conn, activity, :rejected_identity)
    end
  end

  @impl true
  def sign_out(conn, _params), do: conn |> StaffSession.drop() |> send_resp(204, "")

  @impl true
  def failure(conn, _activity, _reason), do: deny(conn, :sign_in_denied)

  # The pinned OIDC DSL fixes assent_strategy to Assent.Strategy.OIDC.
  # Substitute the guarded wrapper at one dispatch point for both phases.
  defp dispatch(conn, phase) do
    strategy = %{Info.strategy!(StaffUser, :entra) | assent_strategy: EntraOIDC}
    Dispatcher.call(conn, {phase, strategy, __MODULE__})
  end

  defp deny(conn, reason) do
    StaffSession.record_denial(reason)

    conn
    |> clear_auth_result()
    |> StaffSession.drop()
    |> send_resp(401, "Staff access denied")
  end

  defp clear_auth_result(conn) do
    %{
      conn
      | private: Map.drop(conn.private, [:authentication_result, :failure_args, :success_args])
    }
  end
end
