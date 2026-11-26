defmodule VoelgoedAiWeb.StaffKnowledgeLiveTest do
  use ExUnit.Case, async: false

  @endpoint VoelgoedAiWeb.Endpoint

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias VoelgoedAi.{Accounts, StaffFixtures}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, KnowledgeCollection}
  import VoelgoedAi.StaffKnowledgeFixture, only: [read_page: 2]

  setup :setup_knowledge

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

    assert {:ok, _} = Accounts.set_roles(ctx.admin, ctx.editor.id, [:support_operator])

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

  test "role revocation stops a connected refresh even when scope is unchanged", ctx do
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
    ids = request_index(ctx, approved, :retry_publication)

    for id <- ids do
      assert :ok =
               Oban.Testing.perform_job(
                 VoelgoedAi.Knowledge.Workers.IndexArticle,
                 %{"embedding_id" => id},
                 repo: VoelgoedAi.Repo
               )
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

  defp revision_path(revision),
    do: "/staff/knowledge/articles/#{revision.article_id}/revisions/#{revision.id}"
end
