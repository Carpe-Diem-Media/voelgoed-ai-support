defmodule VoelgoedAiWeb.StaffKnowledgeAuthTest do
  use ExUnit.Case, async: false

  @endpoint VoelgoedAiWeb.Endpoint

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest, only: [live: 1]
  import Plug.Conn
  import VoelgoedAi.StaffKnowledgeFixture

  alias VoelgoedAi.{Accounts, StaffEntraFixture, StaffFixtures}

  setup do
    VoelgoedAi.StaffFixtures.setup()
  end

  test "only the pinned framework loggers can handle staff socket and LiveView telemetry" do
    # list_handlers/1 matches the whole prefix. This includes mount,
    # handle_params, handle_event, render and component update spans with
    # start/stop/exception suffixes, plus the component destroyed event.
    # New subscribers fail CI until their handling of sensitive metadata is reviewed.
    for prefix <- [
          [:phoenix, :socket_connected],
          [:phoenix, :channel_joined],
          [:phoenix, :channel_handled_in],
          [:phoenix, :endpoint],
          [:phoenix, :router_dispatch],
          [:phoenix, :error_rendered],
          [:phoenix, :live_view],
          [:phoenix, :live_component]
        ],
        handler <- :telemetry.list_handlers(prefix) do
      %{id: id, event_name: event, function: callback} = handler

      assert allowed_logger?(id, event, callback),
             "Unreviewed telemetry handler for #{inspect(event)}"
    end
  end

  test "the TLS upgrade requires current staff, same origin and cookie-backed CSRF", %{
    admin: identity
  } do
    admin = VoelgoedAi.StaffFixtures.bootstrap_admin(identity)
    page = read_page(admin, "/staff/knowledge")
    assert page.status == 200
    {cookie, csrf} = browser_credentials(page)

    start_listener(:https)

    assert upgrade(:https, cookie, csrf, origin()) == 101
    assert upgrade(:https, cookie, csrf, nil) == 101
    assert upgrade(:https, nil, csrf, origin()) == 403
    assert upgrade(:https, cookie <> "x", csrf, origin()) == 403
    assert upgrade(:https, cookie, nil, nil) == 403
    assert upgrade(:https, cookie, "invalid", origin()) == 403

    capture_log(fn ->
      assert upgrade(:https, cookie, csrf, "https://another.example.test") == 403
    end)

    expired = read_page(%{admin | expiry: System.system_time(:second) - 1}, "/staff/knowledge")
    assert expired.status == 302

    expired_cookie =
      refresh_cookie(page, fn conn ->
        put_session(conn, :staff, {admin.id, admin.generation, 0, admin.binding})
      end)

    assert upgrade(:https, expired_cookie, csrf, origin()) == 403

    signed_out =
      StaffEntraFixture.request(:post, "/staff/sign-out", page, [{"x-csrf-token", csrf}])

    assert signed_out.status == 204
    assert signed_out.resp_cookies["_vgas_staff"].max_age == 0
    assert upgrade(:https, nil, csrf, origin()) == 403

    Application.put_env(:voelgoed_ai, :entra, enabled: false)
    assert upgrade(:https, cookie, csrf, origin()) == 403
    assert StaffEntraFixture.request(:get, "/health").status == 200
    denied = StaffEntraFixture.request(:get, "/staff/knowledge")
    assert denied.status == 401
    assert get_resp_header(denied, "cache-control") == ["private, no-store"]
  end

  test "a current support-only session is denied by HTTP, TLS and connected mount", ctx do
    admin = StaffFixtures.bootstrap_admin(ctx.admin)
    assert {:ok, operator} = Accounts.provision(admin, ctx.invited, [:support_operator])
    assert {:ok, session} = StaffFixtures.authenticate(operator.id)
    assert StaffFixtures.resolve(operator.id).roles == [:support_operator]

    denied = read_page(session, "/staff/knowledge")
    assert denied.status == 302
    assert get_resp_header(denied, "location") == ["/staff/knowledge/denied"]

    # Use a CSRF value signed for the same cookie, so transport denial reaches
    # the current-role check. The page token alone conveys no staff identity.
    page = read_page(admin, "/staff/knowledge")
    {_, csrf} = browser_credentials(page)
    staff = {session.id, session.generation, session.expiry, session.binding}
    cookie = refresh_cookie(page, &put_session(&1, :staff, staff))

    start_listener(:https)
    assert upgrade(:https, cookie, csrf, origin()) == 403

    page = put_private(page, :live_view_connect_info, %{session: %{"staff" => staff}})
    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} = live(page)

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{
        connect_info: %{session: %{"staff" => staff}},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }

    assert {:halt, %{redirected: {:redirect, %{to: "/staff/knowledge/denied"}}}} =
             VoelgoedAiWeb.KnowledgeLive.Auth.on_mount(:default, %{}, %{}, socket)
  end

  test "the endpoint rejects the wrong effective port before Phoenix processes the cookie", ctx do
    admin = StaffFixtures.bootstrap_admin(ctx.admin)
    {cookie, csrf} = admin |> read_page("/staff/knowledge") |> browser_credentials()
    start_listener(:https)

    id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               id,
               [:phoenix, :socket_connected],
               &__MODULE__.observe_socket_connect/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(id) end)

    assert upgrade(:https, cookie, csrf, nil) == 101
    assert_receive :staff_socket_connect_attempted

    assert upgrade(:https, cookie, csrf, nil, [{"Host", "staff.example.test:444"}]) == 403
    refute_received :staff_socket_connect_attempted
  end

  test "the socket rejects a same-host Origin with the wrong port on a trusted endpoint", ctx do
    admin = StaffFixtures.bootstrap_admin(ctx.admin)
    {cookie, csrf} = admin |> read_page("/staff/knowledge") |> browser_credentials()
    start_listener(:https)

    assert upgrade(:https, cookie, csrf, origin()) == 101

    capture_log(fn ->
      assert upgrade(:https, cookie, csrf, origin() <> ":444") == 403
    end)
  end

  def observe_socket_connect(_, _, %{user_socket: VoelgoedAiWeb.StaffLiveSocket}, test_pid) do
    send(test_pid, :staff_socket_connect_attempted)
  end

  def observe_socket_connect(_, _, _, _), do: :ok

  test "plaintext upgrade cannot use a valid staff cookie", %{admin: identity} do
    admin = VoelgoedAi.StaffFixtures.bootstrap_admin(identity)
    {cookie, csrf} = admin |> read_page("/staff/knowledge") |> browser_credentials()

    start_listener(:http)
    assert upgrade(:http, cookie, csrf, nil) == 403

    assert upgrade(:http, cookie, csrf, nil, [
             {"X-Forwarded-Proto", "https"},
             {"X-Forwarded-Host", "staff.example.test"},
             {"X-Forwarded-Port", "443"}
           ]) == 403
  end

  test "staff HTML keeps its CSP and serves only the pinned browser files", %{admin: identity} do
    admin = VoelgoedAi.StaffFixtures.bootstrap_admin(identity)
    page = read_page(admin, "/staff/knowledge")

    assert page.status == 200
    assert get_resp_header(page, "cache-control") == ["private, no-store"]
    assert get_resp_header(page, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(page, "x-content-type-options") == ["nosniff"]
    assert [csp] = get_resp_header(page, "content-security-policy")
    assert csp =~ "connect-src 'self' wss://staff.example.test"
    assert csp =~ "script-src 'self'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "form-action 'self'"

    for {name, mime} <- [
          {"phoenix/phoenix.min.js", "javascript"},
          {"live_view/phoenix_live_view.min.js", "javascript"},
          {"knowledge.js", "javascript"},
          {"knowledge.css", "text/css"}
        ] do
      asset = StaffEntraFixture.request(:get, "/staff/assets/#{name}")
      assert asset.status == 200
      assert [content_type] = get_resp_header(asset, "content-type")
      assert content_type =~ mime
    end

    for name <- ["phoenix/phoenix.js", "live_view/phoenix_live_view.js", "unknown.css"] do
      assert StaffEntraFixture.request(:get, "/staff/assets/#{name}").status == 404
    end
  end

  defp allowed_logger?({Phoenix.Logger, event}, event, callback) do
    {event, callback} in [
      {[:phoenix, :socket_connected], &Phoenix.Logger.phoenix_socket_connected/4},
      {[:phoenix, :channel_joined], &Phoenix.Logger.phoenix_channel_joined/4},
      {[:phoenix, :channel_handled_in], &Phoenix.Logger.phoenix_channel_handled_in/4},
      {[:phoenix, :endpoint, :start], &Phoenix.Logger.phoenix_endpoint_start/4},
      {[:phoenix, :endpoint, :stop], &Phoenix.Logger.phoenix_endpoint_stop/4},
      {[:phoenix, :router_dispatch, :start], &Phoenix.Logger.phoenix_router_dispatch_start/4},
      {[:phoenix, :error_rendered], &Phoenix.Logger.phoenix_error_rendered/4}
    ]
  end

  defp allowed_logger?(
         {Phoenix.LiveView.Logger, event},
         [:phoenix, type, lifecycle, suffix] = event,
         callback
       ) do
    {type, lifecycle, suffix, callback} in [
      {:live_view, :mount, :start, &Phoenix.LiveView.Logger.lv_mount_start/4},
      {:live_view, :mount, :stop, &Phoenix.LiveView.Logger.lv_mount_stop/4},
      {:live_view, :handle_params, :start, &Phoenix.LiveView.Logger.lv_handle_params_start/4},
      {:live_view, :handle_params, :stop, &Phoenix.LiveView.Logger.lv_handle_params_stop/4},
      {:live_view, :handle_event, :start, &Phoenix.LiveView.Logger.lv_handle_event_start/4},
      {:live_view, :handle_event, :stop, &Phoenix.LiveView.Logger.lv_handle_event_stop/4},
      {:live_component, :handle_event, :start, &Phoenix.LiveView.Logger.lc_handle_event_start/4},
      {:live_component, :handle_event, :stop, &Phoenix.LiveView.Logger.lc_handle_event_stop/4}
    ]
  end

  defp allowed_logger?(_id, _event, _callback), do: false
end
