defmodule VoelgoedAiWeb.StaffKnowledgeCrashLogTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffKnowledgeFixture

  alias Phoenix.Socket.Message

  @payload "synthetic-crash-event-draft"

  setup :setup_knowledge

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

  defp assert_private_crash(ctx, crash) do
    revision = draft_revision(ctx, collection(ctx))
    path = "/staff/knowledge/articles/#{revision.article_id}/revisions/#{revision.id}"
    page = read_page(ctx.editor, path)
    {cookie, csrf} = browser_credentials(page)
    root = page.resp_body |> LazyHTML.from_document() |> LazyHTML.query("[data-phx-session]")
    [id] = LazyHTML.attribute(root, "id")
    [session] = LazyHTML.attribute(root, "data-phx-session")
    [static] = LazyHTML.attribute(root, "data-phx-static")
    topic = "lv:" <> id
    url = origin() <> path

    original_level = Logger.level()
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok = Logger.configure(level: :debug)

    log =
      capture_log([level: :debug, metadata: :all], fn ->
        # Join under the actual staff channel supervisor without a LiveViewTest
        # proxy, which would crash and produce its own unrelated test-only logs.
        assert {:ok, %{rendered: rendered}, pid} =
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

        assert inspect(rendered) =~ "Synthetic answer."
        ref = Process.monitor(pid)
        crash.(pid, topic, url)
        assert_receive {:DOWN, ^ref, :process, ^pid, {_, [_ | _]}}, 1_000
      end)

    for {label, value} <-
          [
            {"event payload", @payload},
            {"cookie", cookie},
            {"CSRF", csrf},
            {"signed page session", session},
            {"signed page state", static},
            {"staff ID", ctx.editor.id},
            {"session binding", ctx.editor.binding},
            {"session fragment", "staff_actor"},
            {"last message", "Last message:"}
          ] ++ Enum.map(payload()["localized_content"], &{"article text", &1["approved_answer"]}) do
      refute String.contains?(log, value), "Crash log included #{label}"
    end

    assert String.contains?(log, "Staff knowledge LiveView crashed"),
           "Expected a redacted staff LiveView crash notice"
  end

  defp raise_in_hook(pid, stage, callback) do
    :sys.replace_state(pid, fn %{socket: socket} = state ->
      socket =
        if stage == :handle_event do
          Phoenix.LiveView.detach_hook(socket, :staff_event_access, stage)
        else
          socket
        end

      %{state | socket: Phoenix.LiveView.attach_hook(socket, :test_raise, stage, callback)}
    end)
  end
end
