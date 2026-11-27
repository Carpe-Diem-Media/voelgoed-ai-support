defmodule VoelgoedAiWeb.StaffKnowledgeFormsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest, only: [get: 2]

  @endpoint VoelgoedAiWeb.Endpoint
  import Plug.Conn, only: [put_private: 3]
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.StaffKnowledgeFixture, only: [read_page: 2]
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo, StaffFixtures}
  alias VoelgoedAi.Intelligence.Embedding
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision}
  alias VoelgoedAi.Knowledge.Workers.FinalizePublication

  setup :setup_knowledge

  test "a draft needs a source reference before it can be submitted for review", ctx do
    args = put_in(draft_args(ctx, collection(ctx)), [:content, "source_references"], [])
    assert {:ok, %{revision: draft}} = invoke(Article, :create_draft, args, ctx.editor)
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft)))

    refute has_element?(view, "#submit-review")

    assert has_element?(
             view,
             "#review-notice",
             "Add a source reference before submitting for review."
           )

    reply =
      render_submit(view, "submit_review", %{
        "form_token" => form_token(view, "#withdraw"),
        "confirm" => "true"
      })

    assert reply =~ "Reload"
    version = draft.edit_version

    assert {:ok, %{status: :draft, edit_version: ^version}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)
  end

  test "review uses the displayed draft snapshot and ignores a forged target", ctx do
    collection = collection(ctx)
    draft = draft_revision(ctx, collection)
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft)))
    submit = form(view, "#submit-review", %{"confirm" => "true"})

    changed =
      put_in(payload(), ["localized_content", Access.at(0), "title"], "New synthetic title")

    assert {:ok, newer} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(draft), :content, changed),
               ctx.editor
             )

    before = decision_state(draft.id)

    assert render_submit(submit, %{
             "id" => Ash.UUIDv7.generate(),
             "expected_version" => newer.edit_version,
             "expected_hash" => newer.content_hash
           }) =~ "Reload"

    assert {:ok, %{status: :draft}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)

    assert decision_state(draft.id) == before
  end

  test "a contributor with both roles cannot approve through the staff workspace", ctx do
    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.editor.id, [:knowledge_editor, :knowledge_reviewer])

    assert {:ok, actor} = StaffFixtures.authenticate(ctx.editor.id)
    ctx = %{ctx | editor: actor, reviewer: actor}
    reviewed = review(ctx, draft_revision(ctx, collection(ctx)))

    assert {:ok, %{action_hints: %{approve: true}, self_approval_required: true}} =
             invoke(ArticleRevision, :read_revision, %{id: reviewed.id}, actor)

    assert {:ok, view, _} = live(connected_page(actor, path(reviewed)))
    refute has_element?(view, "#approve")

    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#request-changes [name=form_token]")
      |> LazyHTML.attribute("value")

    before = decision_state(reviewed.id)

    render_submit(view, "approve", %{
      "form_token" => token,
      "source_verified" => "true",
      "self_approval" => "true"
    })

    assert {:ok, %{status: :in_review, self_approval_required: true}} =
             invoke(ArticleRevision, :read_revision, %{id: reviewed.id}, actor)

    assert decision_state(reviewed.id) == before
  end

  test "a decision from before a refresh cannot submit the refreshed draft", ctx do
    draft = draft_revision(ctx, collection(ctx))
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft)))
    old_token = form_token(view, "#submit-review")

    render_click(view, "refresh")
    refute form_token(view, "#submit-review") == old_token

    reply =
      render_submit(view, "submit_review", %{"form_token" => old_token, "confirm" => "true"})

    assert {:ok, %{status: :draft}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)

    assert reply =~ "Reload"
  end

  @tag :embedding_index
  test "an independent reviewer approves once and explicitly requests publication", ctx do
    reviewed = review(ctx, draft_revision(ctx, collection(ctx)))
    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(reviewed)))

    assert render_submit(form(view, "#approve", %{"source_verified" => "true"})) =~ "Approved"
    render_submit(view, "approve", %{"source_verified" => "true"})

    assert render_submit(form(view, "#request-publish", %{"confirm" => "true"})) =~ "Publishing"

    assert {:ok, %{status: :publishing, publication_generation: 1}} =
             invoke(ArticleRevision, :read_revision, %{id: reviewed.id}, ctx.reviewer)
  end

  test "draft validation associates errors and editing preserves exact answer text", ctx do
    row = collection(ctx)
    draft = draft_revision(ctx, row)
    edit = path(draft) <> "/edit"
    assert {:ok, view, _} = live(connected_page(ctx.editor, edit))

    assert render_change(
             form(view, "#draft-form", %{"draft" => %{"effective_from" => "invalid"}})
           ) =~
             "ISO 8601 date with offset"

    assert has_element?(
             view,
             "#effective_from[aria-invalid=true][aria-describedby=effective_from-error]"
           )

    assert has_element?(view, "#draft-feedback a[href='#effective_from']")

    exact = "\n  Synthetic edited answer.\r\nSecond line.  "

    fields = %{
      "draft" => %{"effective_from" => "2026-01-01T00:00:00Z", "en-ZA-approved_answer" => exact}
    }

    assert {:error, {:redirect, %{to: destination}}} =
             render_submit(form(view, "#draft-form", fields))

    assert destination == path(draft)

    assert {:ok, %{content: content, edit_version: 2}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)

    assert Enum.find(content["localized_content"], &(&1["locale"] == "en-ZA"))["approved_answer"] ==
             exact
  end

  test "a forged draft form token cannot save an edit", ctx do
    draft = draft_revision(ctx, collection(ctx))
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft) <> "/edit"))
    fields = %{"draft" => %{"en-ZA-approved_answer" => "Synthetic unsaved answer."}}

    assert render_submit(form(view, "#draft-form", fields), %{"form_token" => "forged"}) =~
             "Reload before saving this draft."

    %{content: content, content_hash: hash, edit_version: version} = draft

    assert {:ok,
            %{status: :draft, content: ^content, content_hash: ^hash, edit_version: ^version}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.editor)
  end

  test "the page cannot write after session generation changes", ctx do
    draft = draft_revision(ctx, collection(ctx))
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft)))
    assert {:ok, _} = Accounts.set_roles(ctx.admin, ctx.editor.id, [:support_operator])

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_submit(form(view, "#submit-review", %{"confirm" => "true"}))

    assert {:ok, %{status: :draft}} =
             invoke(ArticleRevision, :read_revision, %{id: draft.id}, ctx.reviewer)
  end

  @tag :embedding_index
  test "publication keeps the current pointer shown to the reviewer", ctx do
    {_collection, approved} = approved(ctx)
    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(approved)))

    # Simulate a reviewer confirming a formerly displayed pointer. The action
    # must compare the server-side snapshot against the real current pointer.
    stale_pointer = Ash.UUIDv7.generate()

    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.page.article.current_revision_id, stale_pointer)
    end)

    before = decision_state(approved.id)

    assert render_submit(form(view, "#request-publish", %{"confirm" => "true"})) =~ "Reload"

    assert {:ok, %{status: :approved, publication_generation: 0}} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)

    assert decision_state(approved.id) == before
  end

  @tag :embedding_index
  test "an approved revision in an internal collection has no publication controls or notice",
       ctx do
    fixture(%{})
    approved = approve_content(ctx, collection(ctx, "", :internal), payload())
    assert {:ok, _} = Embedding.publication_deadline(approved.content)
    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(approved)))

    refute has_element?(view, "#request-publish")
    refute has_element?(view, "#publication-notice")
  end

  @tag :embedding_index
  test "an approved escalation-only revision has no publication controls or notice", ctx do
    fixture(%{})
    approved = approve_content(ctx, Map.put(payload(), "response_mode", "escalate_only"))
    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(approved)))

    refute has_element?(view, "#request-publish")
    refute has_element?(view, "#publication-notice")
  end

  test "a sensitive revision stays in review with no approval or publication control", ctx do
    args = put_in(draft_args(ctx, collection(ctx)), [:content, "sensitive"], true)
    assert {:ok, %{revision: draft}} = invoke(Article, :create_draft, args, ctx.editor)
    reviewed = review(ctx, draft)

    assert {:error, _} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(reviewed)))
    refute has_element?(view, "#approve")
    refute has_element?(view, "#request-publish")
    refute has_element?(view, "#publication-notice")

    assert {:ok, %{status: :in_review}} =
             invoke(ArticleRevision, :read_revision, %{id: reviewed.id}, ctx.reviewer)
  end

  @tag :embedding_index
  test "an approved revision cannot be published before it is effective", ctx do
    fixture(%{clock: fn -> ~U[2026-11-26 00:00:00Z] end})
    approved = approve_content(ctx, Map.put(payload(), "effective_from", "2099-01-01T00:00:00Z"))
    assert {:ok, view, html} = live(connected_page(ctx.reviewer, path(approved)))

    refute has_element?(view, "#request-publish")
    assert html =~ "This revision takes effect on 01 Jan 2099, 00:00 UTC."

    assert {:ok, %{status: :approved, publication_generation: 0}} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)
  end

  @tag :embedding_index
  test "a failed publication cannot be retried when the revision expires", ctx do
    now = DateTime.utc_now()
    expires = DateTime.add(now, 60, :second)
    fixture(%{clock: fn -> now end})

    revision =
      approve_content(ctx, Map.put(payload(), "expires_at", DateTime.to_iso8601(expires)))

    request_index(ctx, revision)

    fixture(%{clock: fn -> expires end})
    assert :ok = finalize(revision)
    assert {:ok, view, html} = live(connected_page(ctx.reviewer, path(revision)))

    refute has_element?(view, "#retry-publication")
    assert html =~ "This revision has expired."

    assert {:ok, %{status: :publish_failed, publication_generation: 1}} =
             invoke(ArticleRevision, :read_revision, %{id: revision.id}, ctx.reviewer)
  end

  @tag :embedding_index
  test "an approved revision cannot be published with the embedding gate closed", ctx do
    {_collection, approved} = approved(ctx)
    fixture(%{enabled: false})
    assert {:ok, view, html} = live(connected_page(ctx.reviewer, path(approved)))

    refute has_element?(view, "#request-publish")
    assert html =~ "Publishing is unavailable."
  end

  @tag :embedding_index
  test "a current published revision cannot be reindexed with the embedding gate closed", ctx do
    {_collection, approved} = approved(ctx)

    for id <- request_index(ctx, approved) do
      assert :ok = Embedding.index(id)
    end

    assert :ok = finalize(approved)
    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(approved)))
    assert has_element?(view, "#request-reindex")

    fixture(%{enabled: false})
    render_click(view, "refresh")
    refute has_element?(view, "#request-reindex")

    assert {:ok, %{status: :published, publication_generation: 1}} =
             invoke(ArticleRevision, :read_revision, %{id: approved.id}, ctx.reviewer)
  end

  test "edit and withdraw controls require an intact draft snapshot", ctx do
    draft = draft_revision(ctx, collection(ctx))
    assert {:ok, view, _} = live(connected_page(ctx.editor, path(draft)))
    edit_link = "a[href='#{path(draft)}/edit']"

    assert has_element?(view, edit_link, "Edit draft")
    assert has_element?(view, "#withdraw")

    store_effective_date(draft, "2026-02-01T00:00:00Z")
    render_click(view, "refresh")

    refute has_element?(view, edit_link)
    refute has_element?(view, "#withdraw")
  end

  @tag :embedding_index
  test "an approved revision with a non-string date mounts with publication unavailable", ctx do
    {_collection, approved} = approved(ctx)
    store_effective_date(approved, 42)

    assert {:ok, view, _} = live(connected_page(ctx.reviewer, path(approved)))
    assert has_element?(view, ".metadata > div", ~r/^Effective from\s*—$/)
    assert has_element?(view, "#publication-notice[role=status]", "Publishing is unavailable.")
    refute has_element?(view, "#request-publish")
  end

  defp store_effective_date(revision, value) do
    content = Map.put(revision.content, "effective_from", value)

    assert %{num_rows: 1} =
             SQL.query!(Repo, "UPDATE article_revisions SET content = $1 WHERE id = $2", [
               content,
               Ecto.UUID.dump!(revision.id)
             ])
  end

  defp decision_state(revision_id) do
    SQL.query!(
      Repo,
      """
      SELECT r.status, r.edit_version, r.content_hash, r.review_hash, r.publication_generation,
             (SELECT count(*) FROM audit_events WHERE article_revision_target_id = r.id),
             (SELECT count(*) FROM oban_jobs)
      FROM article_revisions r WHERE r.id = $1
      """,
      [Ecto.UUID.dump!(revision_id)]
    ).rows
  end

  defp approve_content(ctx, content), do: approve_content(ctx, collection(ctx), content)

  defp approve_content(ctx, collection, content) do
    assert {:ok, %{revision: draft}} =
             invoke(
               Article,
               :create_draft,
               %{draft_args(ctx, collection) | content: content},
               ctx.editor
             )

    assert {:ok, approved} =
             invoke(ArticleRevision, :approve, attest(snapshot(review(ctx, draft))), ctx.reviewer)

    approved
  end

  defp finalize(revision) do
    FinalizePublication.perform(%Oban.Job{
      args: %{"revision_id" => revision.id, "generation" => 1}
    })
  end

  defp form_token(view, selector) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector <> " [name=form_token]")
      |> LazyHTML.attribute("value")

    token
  end

  defp connected_page(actor, path) do
    session = %{"staff" => {actor.id, actor.generation, actor.expiry, actor.binding}}
    actor |> read_page(path) |> put_private(:live_view_connect_info, %{session: session})
  end

  defp path(revision),
    do: "/staff/knowledge/articles/#{revision.article_id}/revisions/#{revision.id}"
end
