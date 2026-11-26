defmodule VoelgoedAiWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :voelgoed_ai

  alias VoelgoedAiWeb.KnowledgeLive.CrashLog

  socket("/staff/live", VoelgoedAiWeb.StaffLiveSocket,
    websocket: [
      check_origin: :conn,
      check_csrf: true,
      transport_log: false,
      log: false,
      connect_info: [:uri, session: {VoelgoedAiWeb.StaffSession, :options, []}]
    ],
    longpoll: false
  )

  plug(:staff_asset_gate)

  plug(Plug.Static,
    at: "/staff/assets/phoenix",
    from: :phoenix,
    only: ~w(phoenix.min.js),
    headers: [{"x-content-type-options", "nosniff"}]
  )

  plug(Plug.Static,
    at: "/staff/assets/live_view",
    from: :phoenix_live_view,
    only: ~w(phoenix_live_view.min.js),
    headers: [{"x-content-type-options", "nosniff"}]
  )

  plug(Plug.Static,
    at: "/staff/assets",
    from: {:voelgoed_ai, "priv/static/staff"},
    only: ~w(knowledge.js knowledge.css),
    headers: [{"x-content-type-options", "nosniff"}]
  )

  plug(:staff_asset_not_found)

  plug(Plug.RequestId)

  plug(Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :request_log_level, []}
  )

  plug(VoelgoedAiWeb.ChatwootWebhook)
  plug(VoelgoedAiWeb.Router)

  def call(%{path_info: ["staff" | _]} = conn, opts) do
    CrashLog.with_staff_http(fn ->
      # Phoenix dispatches sockets before the application's plugs. Reject an
      # unavailable origin before it can reach cookie decryption.
      case conn do
        %{path_info: ["staff", "live" | _]} ->
          conn = VoelgoedAiWeb.StaffSession.knowledge_headers(conn, opts)

          if VoelgoedAiWeb.StaffSession.knowledge_origin?(conn),
            do: super(conn, opts),
            else: conn |> Plug.Conn.send_resp(403, "") |> Plug.Conn.halt()

        _ ->
          super(conn, opts)
      end
    end)
  end

  def call(conn, opts) do
    CrashLog.clear_staff_http()

    # The router URI-decodes segments before matching, so "/%73taff/..." would
    # reach the staff routes while every raw-path check here and in CrashLog
    # misses it. Refuse those requests before any plug or log sees them.
    if encoded_staff_path?(conn),
      do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt(),
      else: super(conn, opts)
  end

  # URI.decode/1 leaves malformed escapes intact, so they cannot equal "staff".
  defp encoded_staff_path?(%{path_info: [segment | _]}),
    do: String.contains?(segment, "%") and URI.decode(segment) == "staff"

  defp encoded_staff_path?(_conn), do: false

  defp staff_asset_gate(%{path_info: ["staff", "assets" | _]} = conn, opts) do
    conn
    |> VoelgoedAiWeb.StaffSession.knowledge_headers(opts)
    |> VoelgoedAiWeb.StaffSession.require_knowledge_origin(opts)
  end

  defp staff_asset_gate(conn, _opts), do: conn

  defp staff_asset_not_found(%{path_info: ["staff", "assets" | _]} = conn, _opts) do
    conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()
  end

  defp staff_asset_not_found(conn, _opts), do: conn

  def request_log_level(%{path_info: ["staff" | _]}), do: false
  def request_log_level(%{path_info: ["webhooks", "chatwoot" | _]}), do: false
  def request_log_level(_), do: :info
end
