defmodule VoelgoedAiWeb.StaffKnowledgeLiveTest do
  use ExUnit.Case, async: false

  @endpoint VoelgoedAiWeb.Endpoint

  import ExUnit.CaptureLog, only: [with_log: 2]
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias VoelgoedAi.{Accounts, StaffFixtures}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, KnowledgeCollection}

  import VoelgoedAi.StaffKnowledgeFixture,
    only: [
      browser_credentials: 1,
      origin: 0,
      read_page: 2,
      start_listener: 1,
      upgrade: 4,
      channel_socket: 1,
      https_status: 2,
      tls_message: 5,
      with_tls_socket: 3
    ]

  setup :setup_knowledge

  test "a joined TLS tab and copied cookie outlive sign-out until admin revocation", ctx do
    row = collection(ctx)
    path = "/staff/knowledge"
    page = read_page(ctx.editor, path)
    {cookie, csrf} = browser_credentials(page)
    selector = page.resp_body |> LazyHTML.from_document() |> LazyHTML.query("[data-phx-session]")
    [id] = LazyHTML.attribute(selector, "id")
    [session] = LazyHTML.attribute(selector, "data-phx-session")
    [static] = LazyHTML.attribute(selector, "data-phx-static")
    topic = "lv:" <> id
    route = "/staff/knowledge/collections/#{row.id}"
    private_input = "synthetic-private-event-probe"
    start_listener(:https)

    {_, logs} =
      with_log([level: :debug, metadata: :all], fn ->
        with_tls_socket(cookie, csrf, fn socket ->
          join =
            tls_message(socket, "1", topic, "phx_join", %{
              "url" => origin() <> path,
              "params" => %{"_mounts" => 0, "_csrf_token" => csrf, "probe" => private_input},
              "session" => session,
              "static" => static
            })

          assert reply_has_key?(join, "rendered"), "TLS join did not render"

          patch = tls_message(socket, "2", topic, "live_patch", %{"url" => origin() <> route})
          assert reply_has_key?(patch, "diff"), "TLS patch did not render"

          signed_out =
            VoelgoedAi.StaffEntraFixture.request(:post, "/staff/sign-out", page, [
              {"x-csrf-token", csrf}
            ])

          assert signed_out.status == 204
          assert signed_out.resp_cookies["_vgas_staff"].max_age == 0
          assert upgrade(:https, nil, csrf, origin()) == 403
          assert https_status(route, [{"Cookie", "_vgas_staff=" <> cookie}]) == 200

          event = %{
            "type" => "click",
            "event" => "refresh",
            "value" => %{"probe" => private_input}
          }

          assert reply_has_key?(tls_message(socket, "3", topic, "event", event), "diff"),
                 "copied session unexpectedly revoked at sign-out"

          assert {:ok, _} = Accounts.disable(ctx.admin, ctx.editor.id)

          denied = tls_message(socket, "4", topic, "event", event)
          assert reply_has_key?(denied, "redirect"), "revoked connected tab did not redirect"

          assert String.contains?(Jason.encode!(denied), "/staff/knowledge/denied"),
                 "wrong denial redirect"

          refute String.contains?(Jason.encode!(denied), [
                   private_input,
                   cookie,
                   csrf,
                   session,
                   static
                 ]),
                 "denial reply disclosed private data"

          assert upgrade(:https, cookie, csrf, origin()) == 403
          assert https_status(route, [{"Cookie", "_vgas_staff=" <> cookie}]) == 302

          result = invoke(Article, :create_draft, draft_args(ctx, row), ctx.editor)
          assert match?({:error, _}, result), "stale actor action was accepted"
          fresh = read_page(ctx.reviewer, route)
          assert fresh.status == 200

          assert {:ok, %{items: []}} =
                   invoke(Article, :list_articles, %{collection_id: row.id}, ctx.reviewer)

          assert {:ok, _} =
                   Accounts.reactivate(ctx.admin, ctx.editor.id, ctx.invited, [:knowledge_editor])

          assert upgrade(:https, cookie, csrf, origin()) == 403
          assert {:ok, fresh_editor} = StaffFixtures.authenticate(ctx.editor.id)
          fresh_page = read_page(fresh_editor, route)
          assert fresh_page.status == 200
          {fresh_cookie, fresh_csrf} = browser_credentials(fresh_page)
          assert upgrade(:https, fresh_cookie, fresh_csrf, origin()) == 101
        end)
      end)

    refute String.contains?(logs, [private_input, cookie, csrf, session, static]),
           "staff TLS capture disclosed private data"
  end

  defp reply_has_key?([_, _, _, "phx_reply", %{"status" => "ok", "response" => response}], key),
    do: Map.has_key?(response, key)

  defp reply_has_key?(_, _), do: false

  test "collections and articles are projected only for the permitted roles", ctx do
    hidden = collection(ctx, "-other")
    allowed = collection(ctx)
    revision = draft_revision(ctx, allowed)

    assert {:ok, %{items: [%{id: id}], next_after_id: nil}} =
             invoke(KnowledgeCollection, :list_collections, %{limit: 1}, ctx.editor)

    assert id == allowed.id

    assert {:ok, %{items: [%{id: first}, %{id: second}]}} =
             invoke(KnowledgeCollection, :list_collections, %{}, ctx.admin)

    assert [first, second] == Enum.sort([hidden.id, allowed.id])

    assert {:error, _} =
             invoke(Article, :list_articles, %{collection_id: allowed.id}, ctx.admin)

    assert {:ok, %{items: [%{id: article_id}]}} =
             invoke(Article, :list_articles, %{collection_id: allowed.id}, ctx.reviewer)

    assert article_id == revision.article_id

    assert {:ok, %{items: [summary]}} =
             invoke(ArticleRevision, :list_revisions, %{article_id: article_id}, ctx.editor)

    refute Map.has_key?(summary, :content)
    refute Map.has_key?(summary, :created_by_id)
    assert {:error, _} = invoke(KnowledgeCollection, :list_collections, %{limit: 51}, ctx.admin)
  end

  test "revision reads expose status and viewer hints without contributor IDs", ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)

    assert {:ok, own} = invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.editor)
    assert own.self_approval_required
    assert own.index_status["af-ZA"].active == :not_indexed
    assert own.index_status["en-ZA"].pending == :not_indexed
    refute Map.has_key?(own, :created_by_id)

    assert {:ok, other} =
             invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.reviewer)

    refute other.self_approval_required
  end

  test "static and connected views require a current scoped session", ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)
    path = revision_path(revision)

    assert read_page(ctx.editor, path).resp_body =~ "Revision 1"

    assert {:ok, view, html} = live(connected_page(ctx.editor, path))

    assert html =~ "Refresh status"
    unchanged = render_click(view, "refresh", %{"id" => Ash.UUIDv7.generate()})
    assert is_binary(unchanged)
    assert unchanged =~ "Revision 1"

    Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope)

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_click(view, "refresh", %{})
  end

  test "an authenticated page token does not replace fresh transport authorization", ctx do
    page = connected_page(ctx.editor, "/staff/knowledge")
    assert page.status == 200

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             live(put_private(page, :live_view_connect_info, %{session: %{}}))

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.editor.id, [:knowledge_editor, :support_operator])

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} = live(page)

    # Exercise the mount gate itself. The page's read action also rejects the
    # stale actor, so a rendered denial alone cannot detect a missing mount check.
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        connect_info: %{session: %{"staff" => staff_tuple(ctx.editor)}}
      }
    }

    assert {:halt, %{redirected: {:redirect, %{to: "/staff/knowledge/denied"}}}} =
             VoelgoedAiWeb.KnowledgeLive.Auth.on_mount(:default, %{}, %{}, socket)
  end

  test "an idle connected view closes when the cookie deadline passes", ctx do
    short = %{ctx.editor | expiry: System.system_time(:second) + 3}
    assert {:ok, view, _} = live(connected_page(short, "/staff/knowledge"))
    ref = Process.monitor(view.pid)

    assert_redirect(view, "/staff/knowledge/denied", 4_000)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
  end

  test "staff transport and LiveView lifecycle keep credentials and editorial content out of logs",
       ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)
    start_listener(:https)

    original_level = Logger.level()
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok = Logger.configure(level: :debug)

    # with_log uses the same capture as capture_log and returns the pages so
    # the assertions can check the actual credentials issued during the flow.
    {pages, log} =
      with_log([level: :debug], fn ->
        index = connected_page(ctx.editor, "/staff/knowledge")
        {cookie, csrf} = browser_credentials(index)
        assert upgrade(:https, cookie, csrf, origin()) == 101
        assert upgrade(:https, cookie, nil, origin()) == 403

        assert https_status("/staff/unmatched", [
                 {"Cookie", "_vgas_staff=" <> cookie},
                 {"X-CSRF-Token", csrf}
               ]) == 404

        assert {:error, %{reason: :invalid_token}} =
                 Phoenix.Channel.Server.join(
                   channel_socket(index),
                   Phoenix.LiveView.UploadChannel,
                   %Phoenix.Socket.Message{
                     topic: "lvu:synthetic-upload",
                     event: "phx_join",
                     ref: "1",
                     payload: %{"token" => "invalid", "draft" => "synthetic-upload-payload"}
                   },
                   []
                 )

        assert {:ok, index_view, _} = live(index)
        collection_path = "/staff/knowledge/collections/#{row.id}"
        assert has_element?(index_view, ~s(a[href="#{collection_path}"]))
        collection_page = connected_page(ctx.editor, collection_path)
        assert {:ok, collection_view, _} = live(collection_page)

        article_path = "/staff/knowledge/articles/#{revision.article_id}"
        assert has_element?(collection_view, ~s(a[href="#{article_path}"]))
        article_page = connected_page(ctx.editor, article_path)
        assert {:ok, article_view, _} = live(article_page)

        path = revision_path(revision)
        assert has_element?(article_view, ~s(a[href="#{path}"]))
        revision_page = connected_page(ctx.editor, path)
        assert {:ok, view, _} = live(revision_page)
        assert has_element?(view, ".answer", "Synthetic answer.")
        assert is_binary(render_click(view, "refresh", %{}))

        Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope)

        assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
                 render_click(view, "refresh", %{})

        assert read_page(ctx.editor, "/staff/knowledge/denied").status == 401
        scope(ctx, row)

        short = %{ctx.editor | expiry: System.system_time(:second) + 3}
        expiry_page = connected_page(short, path)
        assert {:ok, expiring_view, _} = live(expiry_page)
        ref = Process.monitor(expiring_view.pid)
        assert_redirect(expiring_view, "/staff/knowledge/denied", 4_000)
        assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

        [index, collection_page, article_page, revision_page, expiry_page]
      end)

    for page <- pages do
      {cookie, csrf} = browser_credentials(page)
      root = page.resp_body |> LazyHTML.from_document() |> LazyHTML.query("[data-phx-session]")
      [session] = LazyHTML.attribute(root, "data-phx-session")
      [static] = LazyHTML.attribute(root, "data-phx-static")

      assert_absent(log, "staff session cookie", [cookie])
      assert_absent(log, "staff CSRF token", [csrf])
      assert_absent(log, "signed LiveView tokens", [session, static])
    end

    answers = Enum.map(payload()["localized_content"], & &1["approved_answer"])
    assert_absent(log, "editorial content", answers)

    assert_absent(log, "staff identifiers", [
      ctx.admin.id,
      ctx.editor.id,
      ctx.reviewer.id,
      ctx.invited.subject,
      ctx.other.subject,
      ctx.editor.binding
    ])

    assert_absent(log, "staff HTTP or WebSocket transport log", [
      "GET /staff/",
      "CONNECTED TO VoelgoedAiWeb.StaffLiveSocket",
      "REFUSED CONNECTION TO VoelgoedAiWeb.StaffLiveSocket",
      "synthetic-upload-payload"
    ])

    assert_absent(log, "staff LiveView lifecycle log", [
      "MOUNT VoelgoedAiWeb.KnowledgeLive.",
      "HANDLE PARAMS in VoelgoedAiWeb.KnowledgeLive.",
      ~s(HANDLE EVENT "refresh" in VoelgoedAiWeb.KnowledgeLive.),
      "Replied in "
    ])

    assert_absent(log, "staff router dispatch log", ["Processing with "])
  end

  test "a revision URL must name its actual article and disclose no hidden content", ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)

    assert {:ok, %{article: another}} =
             invoke(
               Article,
               :create_draft,
               %{draft_args(ctx, row) | slug: "other-faq", article_ref: "VG-KB-OTHER"},
               ctx.editor
             )

    mismatched =
      read_page(ctx.editor, "/staff/knowledge/articles/#{another.id}/revisions/#{revision.id}")

    missing =
      read_page(
        ctx.editor,
        "/staff/knowledge/articles/#{another.id}/revisions/#{Ash.UUIDv7.generate()}"
      )

    assert mismatched.status == 302
    assert get_resp_header(mismatched, "location") == get_resp_header(missing, "location")
    assert mismatched.resp_body == missing.resp_body
    refute mismatched.resp_body =~ "Synthetic answer"
  end

  test "a non-creator who edits the draft is still a contributor", ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.reviewer.id, [
               :knowledge_editor,
               :knowledge_reviewer
             ])

    assert {:ok, reviewer} = StaffFixtures.authenticate(ctx.reviewer.id)
    scope(%{ctx | editor: reviewer}, row)

    args =
      Map.put(
        snapshot(revision),
        :content,
        put_in(payload(), ["localized_content", Access.at(0), "title"], "Edited synthetic FAQ")
      )

    assert {:ok, updated} = invoke(ArticleRevision, :edit_draft, args, reviewer)
    assert {:ok, read} = invoke(ArticleRevision, :read_revision, %{id: updated.id}, reviewer)
    assert read.self_approval_required
    refute Map.has_key?(read, :contributor_ids)
  end

  test "collections show an empty state and admins see only metadata", ctx do
    row = collection(ctx)

    assert read_page(ctx.editor, "/staff/knowledge/collections/#{row.id}").resp_body =~
             "This page has no articles"

    revision = draft_revision(ctx, row)
    admin = read_page(ctx.admin, "/staff/knowledge/collections/#{row.id}")
    assert admin.status == 200
    assert admin.resp_body =~ "Synthetic FAQs"
    refute admin.resp_body =~ revision.article_id
    refute admin.resp_body =~ "synthetic-faq"

    denied = read_page(ctx.admin, revision_path(revision))
    assert denied.status == 302
    assert get_resp_header(denied, "location") == ["/staff/knowledge/denied"]
  end

  test "a role change invalidates the connected session generation even when scope is unchanged",
       ctx do
    row = collection(ctx)
    revision = draft_revision(ctx, row)
    assert {:ok, view, _} = live(connected_page(ctx.editor, revision_path(revision)))

    assert {:ok, _} = Accounts.set_roles(ctx.admin, ctx.editor.id, [:support_operator])

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_click(view, "refresh", %{})
  end

  @tag :requires_pgvector
  @tag :embedding_index
  test "index status distinguishes absent, pending and active locales", ctx do
    {_collection, approved} = approved(ctx)
    request_index(ctx, approved)

    assert {:ok, queued} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)

    assert %{active: :not_indexed, pending: :pending} = queued.index_status["af-ZA"]

    fixture(%{clock: fn -> DateTime.add(DateTime.utc_now(), 3600, :second) end})
    finish_index(approved.id, 1)

    assert {:ok, failed} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)

    assert %{active: :not_indexed, pending: :failed} = failed.index_status["af-ZA"]
    assert failed.publication_reason == :deadline

    fixture(%{})
    assert {:ok, failed_view, html} = live(connected_page(ctx.reviewer, revision_path(failed)))
    assert html =~ "Publish failed"
    assert html =~ "Deadline"

    assert render_submit(form(failed_view, "#retry-publication", %{"confirm" => "true"})) =~
             "Publishing"

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        VoelgoedAi.Repo,
        "SELECT id::text FROM article_embeddings WHERE revision_id = $1 AND generation = 2 ORDER BY locale",
        [Ecto.UUID.dump!(approved.id)]
      )

    ids = List.flatten(rows)
    assert length(ids) == 2

    for id <- ids do
      assert :ok =
               Oban.Testing.perform_job(
                 VoelgoedAi.Knowledge.Workers.IndexArticle,
                 %{"embedding_id" => id},
                 repo: VoelgoedAi.Repo
               )

      assert [["ready", 1536]] = vector_rows(id), "Retry embedding did not reach ready"
    end

    finish_index(approved.id, 2)

    assert {:ok, ready} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)

    assert %{active: :active, pending: :not_indexed} = ready.index_status["en-ZA"]

    single = put_in(payload(), ["localized_content"], [hd(payload()["localized_content"])])

    assert {:ok, revision} =
             invoke(
               ArticleRevision,
               :create_draft,
               %{article_id: approved.article_id, content: single},
               ctx.editor
             )

    assert {:ok, one_locale} =
             invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.editor)

    assert %{active: :absent, pending: :absent} = one_locale.index_status["af-ZA"]
  end

  test "keyset pages have a cap and repeatable order", ctx do
    row = collection(ctx)
    args = draft_args(ctx, row)

    ids =
      for n <- 1..51 do
        args = %{
          args
          | slug: "synthetic-#{n}",
            article_ref: args.article_ref <> Integer.to_string(n)
        }

        assert {:ok, %{article: %{id: id}}} = invoke(Article, :create_draft, args, ctx.editor)
        id
      end
      |> Enum.sort()

    assert {:ok, page} = invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)
    assert Enum.map(page.items, & &1.id) == Enum.take(ids, 50)

    assert {:ok, last} =
             invoke(
               Article,
               :list_articles,
               %{collection_id: row.id, after_id: page.next_after_id},
               ctx.editor
             )

    assert Enum.map(last.items, & &1.id) == [List.last(ids)]
    assert last.next_after_id == nil
  end

  defp finish_index(id, generation) do
    assert :ok =
             Oban.Testing.perform_job(
               VoelgoedAi.Knowledge.Workers.FinalizePublication,
               %{"revision_id" => id, "generation" => generation},
               repo: VoelgoedAi.Repo
             )
  end

  defp connected_page(actor, path) do
    actor
    |> read_page(path)
    |> put_private(:live_view_connect_info, %{session: %{"staff" => staff_tuple(actor)}})
  end

  defp staff_tuple(session), do: {session.id, session.generation, session.expiry, session.binding}

  defp assert_absent(log, label, values) do
    # Keep capture contents and credentials out of ExUnit failure output.
    assert Enum.all?(values, &(is_binary(&1) and &1 != "")), "Missing #{label} fixture"
    refute String.contains?(log, values), "Captured logs included #{label}"
  end

  defp revision_path(revision),
    do: "/staff/knowledge/articles/#{revision.article_id}/revisions/#{revision.id}"
end
