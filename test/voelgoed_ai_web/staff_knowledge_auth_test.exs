defmodule VoelgoedAiWeb.StaffKnowledgeAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import VoelgoedAi.StaffKnowledgeFixture

  alias VoelgoedAi.StaffEntraFixture

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

  defp allowed_logger?({logger, event}, event, callback) do
    case event do
      [:phoenix, :socket_connected] ->
        logger == Phoenix.Logger and callback == (&Phoenix.Logger.phoenix_socket_connected/4)

      [:phoenix, type, lifecycle, suffix] ->
        logger == Phoenix.LiveView.Logger and
          {type, lifecycle, suffix, callback} in [
            {:live_view, :mount, :start, &Phoenix.LiveView.Logger.lv_mount_start/4},
            {:live_view, :mount, :stop, &Phoenix.LiveView.Logger.lv_mount_stop/4},
            {:live_view, :handle_params, :start,
             &Phoenix.LiveView.Logger.lv_handle_params_start/4},
            {:live_view, :handle_params, :stop, &Phoenix.LiveView.Logger.lv_handle_params_stop/4},
            {:live_view, :handle_event, :start, &Phoenix.LiveView.Logger.lv_handle_event_start/4},
            {:live_view, :handle_event, :stop, &Phoenix.LiveView.Logger.lv_handle_event_stop/4},
            {:live_component, :handle_event, :start,
             &Phoenix.LiveView.Logger.lc_handle_event_start/4},
            {:live_component, :handle_event, :stop,
             &Phoenix.LiveView.Logger.lc_handle_event_stop/4}
          ]

      _ ->
        false
    end
  end

  defp allowed_logger?(_id, _event, _callback), do: false
end
