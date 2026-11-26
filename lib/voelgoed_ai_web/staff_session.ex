defmodule VoelgoedAiWeb.StaffSession do
  @moduledoc "Encrypted staff and in-progress OIDC sessions scoped to the staff routes."

  import Plug.Conn
  alias VoelgoedAi.Accounts.{EntraConfig, StaffAccess}
  alias VoelgoedAi.Accounts.StaffAccess.Session

  @cookie "_vgas_staff"
  @cookie_opts [path: "/staff", secure: true, http_only: true, same_site: "Lax"]

  @session_options @cookie_opts ++
                     [
                       store: :cookie,
                       key: @cookie,
                       signing_salt: "vgas-staff-sign-v1",
                       encryption_salt: "vgas-staff-encrypt-v1",
                       max_age: 600
                     ]

  def options, do: @session_options
  def init(_opts), do: Plug.Session.init(@session_options)

  def call(conn, session_opts) do
    conn =
      conn
      |> put_default_cache_control()
      |> put_resp_header("referrer-policy", "no-referrer")

    case EntraConfig.enabled() do
      {:ok, registration} when conn.scheme == :https ->
        conn
        |> put_private(:staff_registration, registration)
        |> Plug.Session.call(session_opts)
        |> fetch_session()

      _ ->
        record_denial(:staff_auth_unavailable)

        conn
        |> delete_resp_cookie(@cookie, @cookie_opts)
        |> send_resp(401, "Staff access denied")
        |> halt()
    end
  end

  defp put_default_cache_control(conn) do
    if get_resp_header(conn, "cache-control") == ["private, no-store"],
      do: conn,
      else: put_resp_header(conn, "cache-control", "no-store")
  end

  def begin_sign_in(conn) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_session(:staff_flow, {flow_binding(conn), System.system_time(:second) + 600})
  end

  def pending?(conn) do
    case get_session(conn, :staff_flow) do
      {saved_binding, expiry} when is_integer(expiry) ->
        saved_binding == flow_binding(conn) and expiry > System.system_time(:second)

      _ ->
        false
    end
  end

  def put(conn, %Session{} = session) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_session(:staff, {session.id, session.generation, session.expiry, session.binding})
  end

  def actor(conn), do: conn |> get_session() |> decode()

  def decode(session) when is_map(session) do
    case session["staff"] do
      {id, generation, expiry, binding}
      when is_binary(id) and is_integer(generation) and generation >= 0 and is_integer(expiry) and
             is_binary(binding) ->
        %Session{id: id, generation: generation, expiry: expiry, binding: binding}

      _ ->
        nil
    end
  end

  def decode(_), do: nil

  @doc "Check the effective transport origin against the configured Entra callback origin."
  def knowledge_origin?(%{scheme: scheme, host: host, port: port})
      when scheme in [:https, "https"] do
    with {:ok, _} <- EntraConfig.enabled(),
         callback when is_binary(callback) <-
           Application.get_env(:voelgoed_ai, :entra, [])[:redirect_uri],
         %URI{host: ^host, port: ^port} <- URI.parse(callback) do
      true
    else
      _ -> false
    end
  end

  def knowledge_origin?(_), do: false

  def knowledge_access(session) do
    StaffAccess.with_current(session, nil, fn staff ->
      if Enum.any?([:admin, :knowledge_editor, :knowledge_reviewer], &(&1 in staff.roles)),
        do: {:ok, :authorized},
        else: {:error, :denied}
    end)
  end

  def knowledge_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; style-src 'self'; " <>
        "connect-src 'self'#{socket_origin(conn)}; object-src 'none'; " <>
        "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    )
  end

  defp socket_origin(conn) do
    if knowledge_origin?(conn), do: " wss://#{conn.host}", else: ""
  end

  def require_knowledge_origin(conn, _opts) do
    if knowledge_origin?(conn), do: conn, else: conn |> deny_knowledge() |> halt()
  end

  def deny_knowledge(conn, _params \\ %{}), do: send_resp(conn, 401, "Staff access denied")

  def flow_binding(conn), do: StaffAccess.registration_binding(conn.private.staff_registration)

  def drop(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> delete_resp_cookie(@cookie, @cookie_opts)
  end

  def protect_csrf(conn, _) do
    Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init(with: :exception))
  rescue
    _ in Plug.CSRFProtection.InvalidCSRFTokenError ->
      record_denial(:invalid_csrf)
      conn |> send_resp(403, "Staff access denied") |> halt()
  end

  def record_denial(reason)
      when reason in [:staff_auth_unavailable, :invalid_csrf, :invalid_session, :sign_in_denied] do
    :telemetry.execute([:voelgoed_ai, :staff_auth, :denied], %{count: 1}, %{
      reason: reason,
      correlation_id: Ash.UUIDv7.generate()
    })
  end
end
