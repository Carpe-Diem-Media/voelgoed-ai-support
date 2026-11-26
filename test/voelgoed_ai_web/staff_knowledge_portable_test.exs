defmodule VoelgoedAiWeb.StaffKnowledgePortableTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffKnowledgeFixture
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Content}
  alias VoelgoedAiWeb.Endpoint

  @endpoint Endpoint
  @private_probe "synthetic-portable-payload-probe"

  setup :setup_knowledge

  test "export selects explicit scoped IDs and serves a private JSON attachment", ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)
    conn = export(ctx.reviewer, row.id, [draft.article_id])

    assert conn.status == 200

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment;"
    assert disposition =~ "knowledge-articles.json"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert %{"articles" => [%{"content" => content}]} = Jason.decode!(conn.resp_body)
    assert {:ok, ^content} = Content.parse(payload())

    refute export(ctx.editor, row.id, [draft.article_id]).status == 200
    refute export(ctx.admin, row.id, [draft.article_id]).status == 200
    assert export(ctx.reviewer, row.id, []).status == 400

    assert export(ctx.reviewer, row.id, Enum.map(1..11, fn _ -> Ash.UUIDv7.generate() end)).status ==
             400
  end

  test "export denies both an out-of-scope collection and an article from another collection",
       ctx do
    row = collection(ctx)
    hidden = collection(ctx, "-other")
    scope(ctx, hidden)
    draft = draft_revision(ctx, hidden)
    scope(ctx, row)

    forbidden_collection = export(ctx.reviewer, hidden.id, [draft.article_id])
    unknown_collection = export(ctx.reviewer, Ash.UUIDv7.generate(), [draft.article_id])

    assert forbidden_collection.status == 401
    assert forbidden_collection.resp_body == unknown_collection.resp_body
    assert export(ctx.reviewer, row.id, [draft.article_id]).status == 401
  end

  test "export fails closed on a bad CSRF token and over-limit body without logging inputs",
       ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        assert export(ctx.reviewer, row.id, [draft.article_id], @private_probe).status == 403

        assert export(
                 ctx.reviewer,
                 row.id,
                 [draft.article_id],
                 :valid,
                 String.duplicate(@private_probe, 180)
               ).status == 413
      end)

    refute String.contains?(log, @private_probe)
  end

  test "a file must be previewed before applying and a matching draft replays safely", ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)
    bytes = export(ctx.reviewer, row.id, [draft.article_id]).resp_body
    assert {:ok, view, _} = open_import(ctx, row)

    upload = upload(view, bytes)
    assert render_upload(upload, "draft.json") =~ "Preview file"
    token = token(view, "#import-upload")

    assert render_submit(view, "apply_import", %{"form_token" => token, "confirm" => "true"}) =~
             "Preview a file"

    assert render_submit(form(view, "#import-upload")) =~ "Matching draft"

    assert render_submit(form(view, "#apply-import", %{"confirm" => "true"})) =~
             "Draft import complete."

    assert preview_and_apply(view, bytes) =~ "Matching draft"

    assert {:ok, %{items: [%{id: id, status: :draft}]}} =
             invoke(ArticleRevision, :list_revisions, %{article_id: draft.article_id}, ctx.editor)

    assert id == draft.id
  end

  test "an import creates drafts and rejects imported authority", ctx do
    row = collection(ctx)
    bytes = document(row)

    tampered =
      Jason.decode!(bytes)
      |> put_in(["articles", Access.at(0), "status"], "published")
      |> Jason.encode!()

    assert {:ok, view, _} = open_import(ctx, row)
    assert render_upload(upload(view, tampered), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "could not be imported"
    refute has_element?(view, "#apply-import")

    assert {:ok, %{items: []}} =
             invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)

    assert preview_and_apply(view, bytes) =~ "New article and draft"

    assert {:ok, %{items: [%{id: article_id, current_revision_id: nil}]}} =
             invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)

    assert {:ok, %{items: [%{status: :draft}]}} =
             invoke(ArticleRevision, :list_revisions, %{article_id: article_id}, ctx.editor)
  end

  test "require explicit scoped selection when importing a new revision", ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)
    bytes = export(ctx.reviewer, row.id, [draft.article_id]).resp_body
    review(ctx, draft)
    assert {:ok, view, _} = open_import(ctx, row)

    assert render_upload(upload(view, bytes), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "Existing article ID"

    assert render_submit(form(view, "#import-existing", %{"article_id" => draft.article_id})) =~
             "New draft revision"

    assert render_submit(form(view, "#apply-import", %{"confirm" => "true"})) =~
             "Draft import complete."
  end

  test "upload size and type restrictions share an error and leave no preview", ctx do
    row = collection(ctx)

    for {name, type, bytes} <- [
          {"draft.json", "application/json", String.duplicate(" ", 262_145)},
          {"draft.txt", "text/plain", document(row)}
        ] do
      assert {:ok, view, _} = open_import(ctx, row)

      upload =
        file_input(view, "#import-upload", :document, [%{name: name, type: type, content: bytes}])

      assert {:error, _} = render_upload(upload, name)
      assert render(view) =~ "Choose one JSON file of at most 262,144 bytes."
      refute has_element?(view, "#apply-import")
    end
  end

  test "scope loss after preview prevents apply", ctx do
    row = collection(ctx)
    assert {:ok, view, _} = open_import(ctx, row)
    assert render_upload(upload(view, document(row)), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "Import preview"
    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{})
    assert {:error, _} = invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_submit(form(view, "#apply-import", %{"confirm" => "true"}))

    scope(ctx, row)

    assert {:ok, %{items: []}} =
             invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)
  end

  defp export(actor, id, article_ids, token \\ :valid, extra \\ nil) do
    {cookie, csrf} = browser_credentials(read_page(actor, "/staff/knowledge"))

    params =
      [{"_csrf_token", if(token == :valid, do: csrf, else: token)}] ++
        Enum.map(article_ids, &{"article_ids[]", &1})

    body = URI.encode_query(if(extra, do: [{"probe", extra} | params], else: params))

    Plug.Test.conn(:post, origin() <> "/staff/knowledge/collections/#{id}/export", body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("cookie", "_vgas_staff=" <> cookie)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp open_import(ctx, row) do
    actor = ctx.editor
    session = %{"staff" => {actor.id, actor.generation, actor.expiry, actor.binding}}

    actor
    |> read_page("/staff/knowledge/import?collection_id=#{row.id}")
    |> put_private(:live_view_connect_info, %{session: session})
    |> live()
  end

  defp upload(view, bytes) do
    file_input(view, "#import-upload", :document, [
      %{name: "draft.json", type: "application/json", content: bytes}
    ])
  end

  defp token(view, selector) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector <> " [name=form_token]")
      |> LazyHTML.attribute("value")

    token
  end

  defp preview_and_apply(view, bytes) do
    assert render_upload(upload(view, bytes), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "Import preview"
    render_submit(form(view, "#apply-import", %{"confirm" => "true"}))
  end

  defp document(row) do
    {:ok, content} = Content.parse(payload())

    Jason.encode!(%{
      schema_version: 1,
      collection_slug: row.slug,
      articles: [
        %{
          article_ref: "import-" <> alphabetic_suffix(row.slug),
          slug: "imported-faq",
          source_revision_number: 1,
          source_content_hash: Content.hash(content),
          content: content
        }
      ]
    })
  end
end
