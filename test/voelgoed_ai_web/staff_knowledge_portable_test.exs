defmodule VoelgoedAiWeb.StaffKnowledgePortableTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffKnowledgeFixture
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Content, KnowledgeCollection}
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
    assert export(ctx.reviewer, row.id, [draft.article_id, draft.article_id]).status == 400

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
    args = %{draft_args(ctx, row) | article_ref: "allowed-" <> alphabetic_suffix(row.slug)}
    assert {:ok, %{revision: allowed}} = invoke(Article, :create_draft, args, ctx.editor)

    forbidden_collection = export(ctx.reviewer, hidden.id, [draft.article_id])
    unknown_collection = export(ctx.reviewer, Ash.UUIDv7.generate(), [draft.article_id])

    assert forbidden_collection.status == 401
    assert forbidden_collection.resp_body == unknown_collection.resp_body

    for {actor, collection_id, article_ids} <- [
          {ctx.reviewer, row.id, [draft.article_id]},
          {ctx.reviewer, row.id, [allowed.article_id, draft.article_id]},
          {ctx.editor, row.id, [allowed.article_id]}
        ] do
      denied = export(actor, collection_id, article_ids)
      assert denied.status == 401
      assert denied.resp_body == forbidden_collection.resp_body
      assert get_resp_header(denied, "content-disposition") == []
    end

    scope(ctx, hidden)
    withdrawn = export(ctx.reviewer, row.id, [allowed.article_id])
    assert withdrawn.status == 401
    assert withdrawn.resp_body == forbidden_collection.resp_body
    assert get_resp_header(withdrawn, "content-disposition") == []
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

  test "direct preview and apply accept and preserve a bilingual timestamp draft", ctx do
    row = collection(ctx)
    doc = timestamp_document(row)
    bytes = Jason.encode!(doc)
    args = %{id: row.id, document: bytes}

    preview = invoke(KnowledgeCollection, :preview_import, args, ctx.editor)
    assert_empty_collection(ctx, row)

    apply = invoke(KnowledgeCollection, :apply_import, args, ctx.editor)

    outcomes =
      Enum.map([preview, apply], fn result ->
        if match?({:ok, %{articles: [%{outcome: :create}]}}, result),
          do: :accepted,
          else: :rejected
      end)

    assert outcomes == [:accepted, :accepted], "direct timestamp preview and apply"
    assert_timestamp_export(ctx, row, doc)
  end

  test "timestamp upload previews without exposing prose and exports the exact draft", ctx do
    row = collection(ctx)
    doc = timestamp_document(row)
    assert {:ok, view, _} = open_import(ctx, row)
    assert render_upload(upload(view, Jason.encode!(doc)), "draft.json") =~ "Preview file"
    preview = render_submit(form(view, "#import-upload"))
    assert String.contains?(preview, "New article and draft"), "timestamp upload preview"
    refute String.contains?(preview, "2026-01-01 10:00"), "preview disclosed answer text"
    assert_empty_collection(ctx, row)

    assert render_submit(form(view, "#apply-import", %{"confirm" => "true"})) =~
             "Draft import complete."

    assert_timestamp_export(ctx, row, doc)
  end

  test "direct and uploaded batches reject sensitive patterns and mailbox formats atomically",
       ctx do
    row = collection(ctx)
    doc = Jason.decode!(document(row))
    [valid] = doc["articles"]
    marker = "synthetic-rejected-content-probe"
    mailbox = "From: sender@example.test\r\nSubject: #{marker}\r\n\r\nSynthetic message."
    envelope = Map.put(doc, "mailbox_message", %{"body" => marker})
    audit_before = knowledge_audit_count(ctx)

    documents =
      Enum.map(
        [
          email: "nobody@example.test",
          international: "+27 00 000 0000",
          domestic: "000 000 0000",
          identifier: "0000000000000",
          mixed: "2026-01-01 10:00. Contact nobody@example.test."
        ],
        fn {label, answer} ->
          content =
            put_in(
              valid["content"],
              ["localized_content", Access.at(0), "approved_answer"],
              marker <> " " <> answer
            )

          rejected = %{
            valid
            | "article_ref" => "rejected-ref",
              "slug" => "rejected-slug",
              "content" => content,
              "source_content_hash" => Content.hash(content)
          }

          {label, Jason.encode!(%{doc | "articles" => [valid, rejected]})}
        end
      )

    documents =
      documents ++
        [
          {:sensitive_ref,
           Jason.encode!(put_in(doc, ["articles", Access.at(0), "article_ref"], "ref-0000000000"))},
          {:mailbox, mailbox},
          {:email_envelope, Jason.encode!(envelope)}
        ]

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, metadata: :all], fn ->
        for {label, bytes} <- documents do
          for action <- [:preview_import, :apply_import] do
            result =
              invoke(KnowledgeCollection, action, %{id: row.id, document: bytes}, ctx.editor)

            assert match?({:error, _}, result), "direct #{label} #{action} accepted"
            {:error, error} = result
            message = Exception.message(error)

            assert String.contains?(message, "invalid_portable_document"),
                   "direct #{label} #{action} returned the wrong denial"

            refute String.contains?(message, marker), "direct #{label} #{action} disclosed input"
          end

          assert {:ok, view, _} = open_import(ctx, row)
          assert render_upload(upload(view, bytes), "draft.json") =~ "Preview file"
          result = render_submit(form(view, "#import-upload"))
          assert String.contains?(result, "could not be imported"), "upload accepted #{label}"
          refute String.contains?(result, marker), "upload disclosed #{label}"
          refute has_element?(view, "#apply-import")
        end
      end)

    refute String.contains?(log, marker), "rejected content entered logs"
    assert_empty_collection(ctx, row)
    assert knowledge_audit_count(ctx) == audit_before
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

  test "the token from before preview cannot apply the import", ctx do
    row = collection(ctx)
    assert {:ok, view, _} = open_import(ctx, row)
    old_token = token(view, "#import-upload")

    assert render_upload(upload(view, document(row)), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "Import preview"
    refute token(view, "#apply-import") == old_token

    reply =
      render_submit(view, "apply_import", %{"form_token" => old_token, "confirm" => "true"})

    assert {:ok, %{items: []}} =
             invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)

    assert reply =~ "Preview a file"
  end

  test "upload progress for a replacement file clears the previous preview", ctx do
    row = collection(ctx)
    assert {:ok, view, _} = open_import(ctx, row)
    assert render_upload(upload(view, document(row)), "draft.json") =~ "Preview file"
    assert render_submit(form(view, "#import-upload")) =~ "Import preview"

    replacement =
      file_input(view, "#import-upload", :document, [
        %{name: "replacement.json", type: "application/json", content: "{}"}
      ])

    assert render_upload(replacement, "replacement.json", 50) =~ "Uploading 50%"
    refute has_element?(view, "#apply-import")
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

  defp knowledge_audit_count(ctx) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM audit_events WHERE actor_staff_id::text = $1 AND target_kind LIKE 'knowledge_%'",
        [ctx.editor.id]
      )

    count
  end

  defp assert_empty_collection(ctx, row) do
    result = invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)
    assert match?({:ok, %{items: []}}, result), "unexpected imported article"
  end

  defp assert_timestamp_export(ctx, row, doc) do
    result = invoke(Article, :list_articles, %{collection_id: row.id}, ctx.editor)
    assert match?({:ok, %{items: [%{current_revision_id: nil}]}}, result), "draft-only import"
    {:ok, %{items: [%{id: article_id}]}} = result

    revisions = invoke(ArticleRevision, :list_revisions, %{article_id: article_id}, ctx.editor)
    assert match?({:ok, %{items: [%{status: :draft}]}}, revisions), "single draft revision"

    conn = export(ctx.reviewer, row.id, [article_id])
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Jason.decode!(conn.resp_body) === doc, "export differs from canonical content or hash"
  end

  defp timestamp_document(row) do
    doc = Jason.decode!(document(row))
    [entry] = doc["articles"]

    content =
      update_in(entry["content"]["localized_content"], fn locales ->
        Enum.map(locales, fn locale ->
          answer =
            case locale["locale"] do
              "af-ZA" -> "Beskikbaar op (2026-01-01 10:00)."
              "en-ZA" -> "Available on (2026-01-01 10:00)."
            end

          %{locale | "approved_answer" => answer}
        end)
      end)["content"]

    %{
      doc
      | "articles" => [
          %{entry | "content" => content, "source_content_hash" => Content.hash(content)}
        ]
    }
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
