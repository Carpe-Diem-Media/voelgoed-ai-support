defmodule VoelgoedAiWeb.StaffKnowledgeCrashLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffKnowledgeFixture

  alias Phoenix.Socket.Message
  alias VoelgoedAiWeb.Endpoint

  @payload "synthetic-crash-event-draft"

  setup :setup_knowledge

  defmodule CrashingScope do
    @moduledoc false
    defstruct [:crash]

    def fetch(%__MODULE__{crash: crash}, _id), do: crash.()
  end

  test "a dead render over TLS keeps the exception and request metadata out of logs", ctx do
    row = collection(ctx)
    start_listener(:https)
    cookie = issue_cookie(ctx.editor).resp_cookies["_vgas_staff"].value
    owner = self()

    for kind <- [:error, :throw] do
      fail_scope(row, fn ->
        send(owner, {:crashing_request, self()})
        sensitive = {ctx.editor.id, ctx.editor.binding, @payload}

        case kind do
          :error -> raise KeyError, key: :missing, term: sensitive
          :throw -> throw(sensitive)
        end
      end)

      log =
        capture_debug(fn ->
          assert https_status("/staff/knowledge?probe=#{@payload}", [
                   {"Cookie", "_vgas_staff=" <> cookie}
                 ]) == 500

          await_http_crash()
        end)

      assert_no_private_data(log, ctx, [{"cookie", cookie}])

      refute String.contains?(log, ["Converted ", "crash_reason=", "conn=", "plug="]),
             "Staff HTTP error log included framework diagnostics"

      assert String.contains?(log, "Staff HTTP request crashed"),
             "Expected a redacted staff HTTP crash notice"
    end
  end

  test "a percent-encoded staff segment over TLS is refused before routing or logging", ctx do
    row = collection(ctx)
    start_listener(:https)
    cookie = issue_cookie(ctx.editor).resp_cookies["_vgas_staff"].value
    owner = self()

    fail_scope(row, fn ->
      send(owner, {:crashing_request, self()})
      throw({ctx.editor.id, ctx.editor.binding, @payload})
    end)

    # The router decodes each of these to "/staff/knowledge"; the raw-path
    # redaction checks would not recognise them.
    for path <- ["/%73taff/knowledge", "/st%61ff/knowledge", "/%73%74%61%66%66/knowledge"] do
      log =
        capture_debug(fn ->
          assert https_status("#{path}?probe=#{@payload}", [
                   {"Cookie", "_vgas_staff=" <> cookie}
                 ]) == 404
        end)

      refute_received {:crashing_request, _}, "#{path} reached the staff route"
      assert_no_private_data(log, ctx, [{"cookie", cookie}])
      refute String.contains?(log, ["taff", "%73", "%61"]), "#{path} was request-logged"
    end
  end

  test "the endpoint clears the staff marker before a public 404 in the same process" do
    log =
      capture_debug(fn ->
        for path <- ["/staff/synthetic-missing", "/synthetic-public-missing"] do
          assert %{status: 404} = Plug.Test.conn(:get, path) |> Endpoint.call(Endpoint.init([]))
          assert_receive {:plug_conn, :sent}
        end
      end)

    assert log =~ "GET /synthetic-public-missing"
    assert log =~ "Converted error Phoenix.Router.NoRouteError"
    refute log =~ "/staff/synthetic-missing"
  end

  test "a non-staff HTTP crash over TLS retains Bandit diagnostics" do
    owner = self()

    start_listener(
      :https,
      {fn
         %{path_info: ["public-crash"]}, _opts ->
           send(owner, {:crashing_request, self()})
           raise "synthetic public crash"

         conn, opts ->
           Endpoint.call(conn, opts)
       end, []}
    )

    log =
      capture_debug(fn ->
        assert https_status("/public-crash", []) == 500
        await_http_crash()
      end)

    assert String.contains?(log, "synthetic public crash")
    refute String.contains?(log, "Staff HTTP request crashed")
  end

  test "a malformed join over TLS is redacted before LiveView labels the channel", ctx do
    assert_private_tls_join(ctx, fn _url -> 123 end, "Staff knowledge channel crashed")
  end

  test "a connected mount crash over TLS keeps the actor and join details out of logs", ctx do
    row = collection(ctx)
    owner = self()

    assert_private_tls_join(
      ctx,
      fn url ->
        # The editorial read runs after Auth.on_mount has stored the staff actor.
        fail_scope(row, fn ->
          send(owner, :connected_editorial_read)
          raise KeyError, key: :missing, term: {ctx.editor, @payload}
        end)

        url
      end,
      "Staff knowledge LiveView crashed"
    )

    assert_received :connected_editorial_read
  end

  test "an unexpected call after mount keeps staff data out of crash logs", ctx do
    assert_private_crash(ctx, fn pid, _topic, _url ->
      assert catch_exit(GenServer.call(pid, {:unexpected_call, @payload}))
    end)
  end

  test "a handle_params raise keeps staff data out of crash logs", ctx do
    assert_private_crash(ctx, fn pid, topic, url ->
      raise_in_hook(pid, :handle_params, fn _, _, _ -> raise "synthetic bad route" end)
      send(pid, %Message{topic: topic, event: "live_patch", payload: %{"url" => url}})
    end)
  end

  test "an event raise keeps the draft payload and staff data out of crash logs", ctx do
    assert_private_crash(ctx, fn pid, topic, _url ->
      raise_in_hook(pid, :handle_event, fn "refresh", %{"draft" => @payload}, _ ->
        raise "synthetic bad event #{@payload}"
      end)

      send(pid, %Message{
        topic: topic,
        event: "event",
        payload: %{"event" => "refresh", "type" => "click", "value" => %{"draft" => @payload}}
      })
    end)
  end

  test "staff forms redact validate and submit failures and unexpected messages", ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)
    article_path = "/staff/knowledge/articles/#{revision.article_id}"
    revision_path = "#{article_path}/revisions/#{revision.id}"
    collection_path = "/staff/knowledge/collections/#{row.id}"

    for {actor, path, event, sentinel} <- [
          {ctx.editor, collection_path <> "/articles/new", "validate_draft",
           "synthetic-create-validate"},
          {ctx.editor, collection_path <> "/articles/new", "save_draft",
           "synthetic-create-submit"},
          {ctx.editor, article_path <> "/revisions/new", "save_draft",
           "synthetic-revision-create"},
          {ctx.editor, revision_path <> "/edit", "validate_draft", "synthetic-edit-validate"},
          {ctx.editor, revision_path <> "/edit", "save_draft", "synthetic-edit-submit"},
          {ctx.editor, revision_path, "submit_review", "synthetic-review-submit"},
          {ctx.admin, "/staff/knowledge", "create_collection", "synthetic-collection-create"},
          {ctx.admin, collection_path, "find_assistant_draft", "synthetic-grant-lookup"},
          {ctx.editor, "/staff/knowledge/import?collection_id=#{row.id}", "preview_import",
           "synthetic-import-preview"}
        ] do
      assert_private_view_crash(ctx, actor, path, "", [{"form draft", sentinel}], fn pid,
                                                                                     topic,
                                                                                     _ ->
        crash_form(pid, topic, event, sentinel)
      end)
    end

    assert_private_view_crash(ctx, ctx.editor, revision_path <> "/edit", "Edit draft", [], fn pid,
                                                                                              _,
                                                                                              _ ->
      raise_in_hook(pid, :handle_info, fn {:unexpected_info, @payload}, _ ->
        raise KeyError, key: :missing, term: @payload
      end)

      send(pid, {:unexpected_info, @payload})
    end)
  end

  test "upload channel crash redacts file bytes and releases the temporary upload", ctx do
    row = collection(ctx)
    path = "/staff/knowledge/import?collection_id=#{row.id}"
    page = read_page(ctx.editor, path)
    {cookie, csrf} = browser_credentials(page)
    {topic, session, static} = join_tokens(page)

    log =
      capture_debug(fn ->
        assert {:ok, _, view_pid} =
                 join_view(page, topic, session, static, origin() <> path, csrf)

        upload_ref = :sys.get_state(view_pid).socket.assigns.uploads.document.ref
        entry_ref = "synthetic-entry"
        file = Jason.encode!(%{text: @payload})

        send(view_pid, %Message{
          topic: topic,
          ref: "preflight",
          event: "allow_upload",
          payload: %{
            "ref" => upload_ref,
            "entries" => [
              %{
                "ref" => entry_ref,
                "size" => byte_size(file),
                "type" => "application/json",
                "name" => "synthetic.json"
              }
            ]
          }
        })

        assert_receive {:socket_push, :text, reply}, 1_000

        assert [
                 _,
                 "preflight",
                 ^topic,
                 "phx_reply",
                 %{"status" => "ok", "response" => %{"entries" => %{^entry_ref => token}}}
               ] =
                 Jason.decode!(IO.iodata_to_binary(reply))

        upload_topic = "lvu:" <> entry_ref

        assert {:ok, _, upload_pid} =
                 Phoenix.Channel.Server.join(
                   channel_socket(page),
                   Phoenix.LiveView.UploadChannel,
                   %Message{
                     topic: upload_topic,
                     event: "phx_join",
                     ref: "upload",
                     payload: %{"token" => token}
                   },
                   []
                 )

        ref = Process.monitor(upload_pid)

        send(upload_pid, %Message{
          topic: upload_topic,
          ref: "chunk",
          event: "chunk",
          payload: {:binary, file}
        })

        assert_receive {:socket_push, :text, _}, 1_000
        disk_path = :sys.get_state(upload_pid).assigns.writer_state.path
        assert File.read!(disk_path) == file

        assert catch_exit(GenServer.call(upload_pid, {:unexpected_upload_call, file}))
        assert_receive {:DOWN, ^ref, :process, ^upload_pid, _}, 1_000
        # Synchronize with Plug.Upload after its owner monitor processes DOWN.
        assert_removed(disk_path, 25)
      end)

    assert_no_private_data(log, ctx, [
      {"cookie", cookie},
      {"CSRF", csrf},
      {"signed page session", session},
      {"signed page state", static}
    ])

    assert String.contains?(log, "Staff knowledge channel crashed")
  end

  test "an export controller crash over TLS redacts its body and credentials", ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)
    {cookie, csrf} = browser_credentials(read_page(ctx.reviewer, "/staff/knowledge"))
    owner = self()
    start_listener(:https)

    fail_scope(row, fn ->
      send(owner, {:crashing_request, self()})
      raise KeyError, key: :missing, term: {ctx.reviewer, @payload}
    end)

    form =
      URI.encode_query([
        {"_csrf_token", csrf},
        {"article_ids[]", draft.article_id},
        {"probe", @payload}
      ])

    log =
      capture_debug(fn ->
        assert https_post_status("/staff/knowledge/collections/#{row.id}/export", cookie, form) ==
                 500

        await_http_crash()
      end)

    assert_no_private_data(log, ctx, [
      {"cookie", cookie},
      {"CSRF", csrf},
      {"reviewer", ctx.reviewer.id}
    ])

    assert String.contains?(log, "Staff HTTP request crashed")
  end

  defp assert_removed(path, 0), do: refute(File.exists?(path))

  defp assert_removed(path, retries) do
    if File.exists?(path) do
      Process.sleep(10)
      assert_removed(path, retries - 1)
    end
  end

  defp crash_form(pid, topic, event, sentinel) do
    raise_in_hook(pid, :handle_event, fn ^event, %{"draft" => %{"title" => ^sentinel}}, _ ->
      raise KeyError, key: :missing, term: sentinel
    end)

    send(pid, %Message{
      topic: topic,
      event: "event",
      payload: %{
        "event" => event,
        "type" => "form",
        "value" => URI.encode_query(%{"draft[title]" => sentinel})
      }
    })
  end

  defp assert_private_tls_join(ctx, crash_url, channel_notice) do
    path = "/staff/knowledge"
    page = read_page(ctx.editor, path)
    assert page.status == 200
    {cookie, csrf} = browser_credentials(page)
    {topic, session, static} = join_tokens(page)
    url = crash_url.(origin() <> path)
    start_listener(:https)

    log =
      capture_debug(fn ->
        reply =
          tls_join(cookie, csrf, topic, %{
            "url" => url,
            "params" => %{"_mounts" => 0, "_csrf_token" => csrf, "draft" => @payload},
            "session" => session,
            "static" => static
          })

        assert match?(
                 [
                   "1",
                   "1",
                   ^topic,
                   "phx_reply",
                   %{"status" => "error", "response" => %{"reason" => "join crashed"}}
                 ],
                 reply
               ),
               "Expected the staff channel to crash during join"
      end)

    assert_no_private_data(log, ctx, [
      {"cookie", cookie},
      {"CSRF", csrf},
      {"signed page session", session},
      {"signed page state", static}
    ])

    assert String.contains?(log, channel_notice), "Expected a redacted staff channel crash notice"

    assert String.contains?(log, "Staff knowledge channel join crashed"),
           "Expected a redacted staff transport join notice"
  end

  defp assert_private_crash(ctx, crash) do
    revision = draft_revision(ctx, collection(ctx))
    path = "/staff/knowledge/articles/#{revision.article_id}/revisions/#{revision.id}"
    extra = Enum.map(payload()["localized_content"], &{"article text", &1["approved_answer"]})
    assert_private_view_crash(ctx, ctx.editor, path, "Synthetic answer.", extra, crash)
  end

  defp assert_private_view_crash(ctx, actor, path, marker, extra, crash) do
    page = read_page(actor, path)
    {cookie, csrf} = browser_credentials(page)
    {topic, session, static} = join_tokens(page)
    url = origin() <> path

    log =
      capture_debug(fn ->
        # Join under the actual staff channel supervisor without a LiveViewTest
        # proxy, which would crash and produce its own unrelated test-only logs.
        assert {:ok, %{rendered: rendered}, pid} =
                 join_view(page, topic, session, static, url, csrf)

        assert inspect(rendered) =~ marker
        ref = Process.monitor(pid)
        crash.(pid, topic, url)
        assert_receive {:DOWN, ^ref, :process, ^pid, {_, [_ | _]}}, 1_000
      end)

    assert_no_private_data(
      log,
      ctx,
      [
        {"cookie", cookie},
        {"CSRF", csrf},
        {"signed page session", session},
        {"signed page state", static},
        {"actor", actor.id},
        {"actor binding", actor.binding}
      ] ++ extra
    )

    assert String.contains?(log, "Staff knowledge LiveView crashed"),
           "Expected a redacted staff LiveView crash notice"
  end

  defp join_view(page, topic, session, static, url, csrf) do
    Phoenix.Channel.Server.join(
      channel_socket(page),
      Phoenix.LiveView.Channel,
      %Message{
        topic: topic,
        event: "phx_join",
        ref: "1",
        payload: %{
          "url" => url,
          "params" => %{"_mounts" => 0, "_csrf_token" => csrf},
          "session" => session,
          "static" => static
        }
      },
      []
    )
  end

  defp join_tokens(page) do
    root = page.resp_body |> LazyHTML.from_document() |> LazyHTML.query("[data-phx-session]")
    [id] = LazyHTML.attribute(root, "id")
    [session] = LazyHTML.attribute(root, "data-phx-session")
    [static] = LazyHTML.attribute(root, "data-phx-static")
    {"lv:" <> id, session, static}
  end

  defp assert_no_private_data(log, ctx, extra) do
    for {label, value} <-
          [
            {"event payload", @payload},
            {"staff ID", ctx.editor.id},
            {"session binding", ctx.editor.binding},
            {"session fragment", "staff_actor"},
            {"last message", "Last message:"},
            {"process state", "State:"}
          ] ++ extra do
      refute String.contains?(log, value), "Crash log included #{label}"
    end
  end

  defp capture_debug(fun) do
    original_level = Logger.level()
    :ok = Logger.configure(level: :debug)

    # The caller's capture must see debug events from the server processes.
    try do
      capture_log([level: :debug, metadata: :all], fun)
    after
      :ok = Logger.configure(level: original_level)
    end
  end

  defp fail_scope(row, crash) do
    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      row.id => %CrashingScope{crash: crash}
    })
  end

  defp await_http_crash do
    # Phoenix can send its response before Bandit logs the exception.
    receive do
      {:crashing_request, pid} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    after
      1_000 -> flunk("The request did not reach the injected crash")
    end
  end

  defp raise_in_hook(pid, stage, callback) do
    :sys.replace_state(pid, fn %{socket: socket} = state ->
      socket =
        case stage do
          :handle_event -> Phoenix.LiveView.detach_hook(socket, :staff_event_access, stage)
          :handle_info -> Phoenix.LiveView.detach_hook(socket, :staff_expiry, stage)
          _ -> socket
        end

      %{state | socket: Phoenix.LiveView.attach_hook(socket, :test_raise, stage, callback)}
    end)
  end
end
