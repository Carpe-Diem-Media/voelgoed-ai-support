defmodule VoelgoedAi.Knowledge.EditorialTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.StaffFixtures, only: [authenticate: 1, bootstrap_admin: 1]
  import VoelgoedAi.SupportFixtures, except: [setup: 0]
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo}
  alias VoelgoedAi.Intelligence.AssistantRevision
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Content, KnowledgeCollection}

  setup do
    ctx = VoelgoedAi.SupportFixtures.setup()
    admin = bootstrap_admin(ctx.admin)
    assert {:ok, editor} = Accounts.provision(admin, ctx.invited, [:knowledge_editor])
    assert {:ok, editor} = authenticate(editor.id)
    assert {:ok, reviewer} = Accounts.provision(admin, ctx.other, [:knowledge_reviewer])
    assert {:ok, reviewer} = authenticate(reviewer.id)

    on_exit(fn ->
      SQL.query(
        Repo,
        "DELETE FROM audit_events WHERE actor_staff_id::text = ANY($1) AND target_kind LIKE 'knowledge_%'",
        [[admin.id, editor.id, reviewer.id]]
      )

      SQL.query(
        Repo,
        "DELETE FROM assistant_knowledge_grants WHERE collection_id IN (SELECT id FROM knowledge_collections WHERE slug IN ($1, $1 || '-other'))",
        [ctx.slug]
      )

      SQL.query(Repo, "DELETE FROM article_revisions WHERE created_by_id::text = ANY($1)", [
        [editor.id, reviewer.id]
      ])

      SQL.query(Repo, "DELETE FROM articles WHERE owner_id::text = ANY($1)", [
        [editor.id, reviewer.id]
      ])

      SQL.query(Repo, "DELETE FROM knowledge_collections WHERE slug IN ($1, $1 || '-other')", [
        ctx.slug
      ])

      Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope)
    end)

    Map.merge(ctx, %{admin: admin, editor: editor, reviewer: reviewer})
  end

  test "collection lifecycle requires live ADMIN authority and advances epochs", ctx do
    args = %{slug: ctx.slug, name: "Synthetic FAQs", audience: :public}

    for actor <- [nil, ctx.editor, %{ctx.admin | generation: ctx.admin.generation + 1}] do
      assert {:error, _} = invoke(KnowledgeCollection, :create, args, actor)
    end

    assert {:ok, %{status: :disabled} = row} =
             invoke(KnowledgeCollection, :create, args, ctx.admin)

    for {action, status} <- [enable: :active, disable: :disabled, retire: :retired] do
      assert {:error, _} = invoke(KnowledgeCollection, action, %{id: row.id}, ctx.editor)

      assert {:ok, %{status: ^status}} =
               invoke(KnowledgeCollection, action, %{id: row.id}, ctx.admin)
    end

    assert {:error, _} = invoke(KnowledgeCollection, :enable, %{id: row.id}, ctx.admin)

    assert {:ok, %{security_epoch: 3}} =
             invoke(KnowledgeCollection, :read_collection, %{id: row.id}, ctx.admin)
  end

  test "review guards the exact snapshot and rollback keeps the prior state", ctx do
    collection = collection(ctx)
    revision = draft_revision(ctx, collection)
    submitted = review(ctx, revision)
    args = snapshot(submitted)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :edit_draft,
               Map.put(snapshot(submitted), :content, payload()),
               ctx.editor
             )

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :approve,
               attest(%{args | expected_hash: String.duplicate("0", 64)}),
               ctx.reviewer
             )

    assert {:ok, %{status: :draft} = changed} =
             invoke(
               ArticleRevision,
               :request_changes,
               Map.put(snapshot(submitted), :reason, :source_correction),
               ctx.reviewer
             )

    submitted = review(ctx, changed)
    Process.put({VoelgoedAi.Knowledge.Editorial, :reject_audit}, :approve)

    assert {:error, _} =
             invoke(ArticleRevision, :approve, attest(snapshot(submitted)), ctx.reviewer)

    Process.delete({VoelgoedAi.Knowledge.Editorial, :reject_audit})

    assert {:ok, %{status: :in_review}} =
             invoke(ArticleRevision, :read_revision, %{id: submitted.id}, ctx.reviewer)

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'article_revision_id' = $1", [
        revision.id
      ])
    end)

    jobs = SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows

    assert {:ok, %{status: :approved, approved_by_id: id}} =
             invoke(ArticleRevision, :approve, attest(snapshot(submitted)), ctx.reviewer)

    assert id == ctx.reviewer.id
    assert SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows == jobs
  end

  test "editorial actions deny unrelated, unscoped, stale and direct storage actors", ctx do
    collection = collection(ctx)
    rev = draft_revision(ctx, collection)
    read = %{id: rev.id}

    assert {:ok, second} =
             invoke(
               ArticleRevision,
               :create_draft,
               %{article_id: rev.article_id, content: payload()},
               ctx.editor
             )

    reviewed = review(ctx, second)

    for {resource, action, args, wrong_role} <- [
          {Article, :create_draft, draft_args(ctx, collection), ctx.reviewer},
          {ArticleRevision, :create_draft, %{article_id: rev.article_id, content: payload()},
           ctx.reviewer},
          {ArticleRevision, :edit_draft, Map.put(snapshot(rev), :content, payload()),
           ctx.reviewer},
          {ArticleRevision, :submit_review, snapshot(rev), ctx.reviewer},
          {ArticleRevision, :request_changes,
           Map.put(snapshot(reviewed), :reason, :source_correction), ctx.editor},
          {ArticleRevision, :approve, Map.put(attest(snapshot(reviewed)), :self_approval, true),
           ctx.editor},
          {ArticleRevision, :withdraw, Map.put(snapshot(rev), :reason, :withdrawn_by_staff), nil},
          {Article, :archive, %{id: rev.article_id, reason: :obsolete}, ctx.editor},
          {ArticleRevision, :read_revision, read, nil}
        ] do
      for actor <- [
            nil,
            ctx.admin,
            wrong_role,
            %{ctx.editor | generation: ctx.editor.generation + 1},
            %{ctx.reviewer | generation: ctx.reviewer.generation + 1},
            struct(VoelgoedAi.Support.ActionScope.Processing,
              action: action,
              resource: resource,
              target: rev.id,
              inbox: :fixture
            )
          ] do
        assert {:error, _} = invoke(resource, action, args, actor)
      end

      Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope)

      for actor <- [ctx.editor, ctx.reviewer],
          do: assert({:error, _} = invoke(resource, action, args, actor))

      scope(ctx, collection)
    end

    assert {:error, _} =
             Repo.transact(fn ->
               ArticleRevision
               |> Ash.Query.for_read(:storage_row, read,
                 actor: %VoelgoedAi.Knowledge.Storage{ref: make_ref()}
               )
               |> Ash.read_one()
             end)
  end

  test "the current pointer cannot reference a revision of another article", ctx do
    collection = collection(ctx)
    first = draft_revision(ctx, collection)

    other = %{
      draft_args(ctx, collection)
      | article_ref: "VG-KB-other-" <> alphabetic_suffix(ctx.slug),
        slug: "other-faq"
    }

    assert {:ok, %{article: article}} = invoke(Article, :create_draft, other, ctx.editor)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "articles_current_revision_fkey"}}} =
             SQL.query(Repo, "UPDATE articles SET current_revision_id = $1 WHERE id = $2", [
               Ecto.UUID.dump!(first.id),
               Ecto.UUID.dump!(article.id)
             ])
  end

  test "scoped editors and reviewers can withdraw without granting ADMIN content access", ctx do
    collection = collection(ctx)
    draft = draft_revision(ctx, collection)
    assert {:error, _} = invoke(Article, :read_article, %{id: draft.article_id}, ctx.admin)

    assert {:ok, %{status: :withdrawn}} =
             invoke(
               ArticleRevision,
               :withdraw,
               Map.put(snapshot(draft), :reason, :withdrawn_by_staff),
               ctx.editor
             )

    revision_args = %{article_id: draft.article_id, content: payload()}

    assert {:ok, %{revision_number: 2} = second} =
             invoke(ArticleRevision, :create_draft, revision_args, ctx.editor)

    reviewed = review(ctx, second)

    assert {:ok, %{status: :withdrawn}} =
             invoke(
               ArticleRevision,
               :withdraw,
               Map.put(snapshot(reviewed), :reason, :withdrawn_by_staff),
               ctx.reviewer
             )

    args = %{target_kind: :knowledge_revision, id: reviewed.id}

    assert {:error, _} =
             invoke(VoelgoedAi.Governance.AuditEvent, :knowledge_history, args, ctx.admin)

    assert {:ok, history} =
             invoke(VoelgoedAi.Governance.AuditEvent, :knowledge_history, args, ctx.reviewer)

    assert Enum.map(history, & &1.event) == [:create_draft, :submit_review, :withdraw]
  end

  test "concurrent edits and approvals serialize on real connections", ctx do
    collection = collection(ctx)
    rev = draft_revision(ctx, collection)

    args =
      Map.put(
        snapshot(rev),
        :content,
        put_in(
          payload(),
          ["localized_content", Access.at(0), "approved_answer"],
          "Updated synthetic answer."
        )
      )

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'article_revision_id' = $1", [rev.id])
    end)

    jobs = SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows
    winner = compete(fn -> invoke(ArticleRevision, :edit_draft, args, ctx.editor) end)
    assert SQL.query!(Repo, "SELECT count(*) FROM oban_jobs").rows == jobs
    in_review = review(ctx, winner)

    assert %{status: :approved} =
             compete(fn ->
               invoke(ArticleRevision, :approve, attest(snapshot(in_review)), ctx.reviewer)
             end)
  end

  test "canonical hash sorts locale keys and scope and preserves answer text" do
    assert {:ok, content} = Content.parse(payload())
    hash = Content.hash(content)
    reversed = update_in(payload(), ["localized_content"], &Enum.reverse/1)
    assert {:ok, other} = Content.parse(reversed)
    assert Content.hash(other) == hash
    equivalent_time = %{reversed | "effective_from" => "2026-01-01T02:00:00+02:00"}
    assert {:ok, equivalent} = Content.parse(equivalent_time)
    assert Content.hash(equivalent) == hash
    scope = %{"product" => ["synthetic-z", "synthetic-a"]}
    assert {:ok, scoped} = Content.parse(%{payload() | "applicability" => scope})

    assert {:ok, reversed_scope} =
             Content.parse(%{
               payload()
               | "applicability" => %{"product" => Enum.reverse(scope["product"])}
             })

    assert Content.hash(scoped) == Content.hash(reversed_scope)
    refute Content.hash(scoped) == hash

    assert {:ok, changed} =
             Content.parse(
               put_in(
                 payload(),
                 ["localized_content", Access.at(0), "approved_answer"],
                 "Synthetic answer. "
               )
             )

    refute Content.hash(changed) == hash
  end

  test "self-approval requires the reviewer role and explicit attestation", ctx do
    collection = collection(ctx)
    revision = draft_revision(ctx, collection) |> then(&review(ctx, &1))

    assert {:ok, _} =
             Accounts.set_roles(ctx.admin, ctx.editor.id, [:knowledge_editor, :knowledge_reviewer])

    assert {:error, _} = invoke(ArticleRevision, :approve, attest(snapshot(revision)), ctx.editor)
    assert {:ok, both} = authenticate(ctx.editor.id)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      collection.id => %{editors: [both.id], reviewers: [both.id]}
    })

    assert {:error, _} = invoke(ArticleRevision, :approve, attest(snapshot(revision)), both)
    args = Map.put(attest(snapshot(revision)), :self_approval, true)
    assert {:ok, %{status: :approved}} = invoke(ArticleRevision, :approve, args, both)

    assert %{rows: [["self_approval_attested"]]} =
             SQL.query!(
               Repo,
               """
               SELECT reason_code FROM audit_events
               WHERE article_revision_target_id = $1 AND event = 'approve'
               """,
               [Ecto.UUID.dump!(revision.id)]
             )
  end

  test "sensitive approvals stay pending and archive fences editing", ctx do
    collection = collection(ctx)
    args = put_in(draft_args(ctx, collection), [:content, "sensitive"], true)
    assert {:ok, %{revision: rev}} = invoke(Article, :create_draft, args, ctx.editor)
    reviewed = review(ctx, rev)

    assert {:error, _} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    assert {:ok, %{status: :archived}} =
             invoke(Article, :archive, %{id: rev.article_id, reason: :obsolete}, ctx.reviewer)

    assert {:error, _} =
             invoke(
               ArticleRevision,
               :request_changes,
               Map.put(snapshot(reviewed), :reason, :source_correction),
               ctx.reviewer
             )
  end

  test "grants reject internal scope and freeze at publication", ctx do
    public = collection(ctx)
    internal = collection(ctx, "-other", :internal)
    assistant = create(ctx.admin, ctx.slug)
    allow_fixture(assistant)
    revision = draft(ctx.admin, assistant)
    args = %{id: revision.id, collection_id: public.id}

    assert {:error, _} =
             invoke(
               AssistantRevision,
               :grant_collection,
               %{args | collection_id: internal.id},
               ctx.admin
             )

    for actor <- [
          nil,
          ctx.editor,
          ctx.reviewer,
          %{ctx.admin | generation: ctx.admin.generation + 1}
        ] do
      assert {:error, _} = invoke(AssistantRevision, :grant_collection, args, actor)
      assert {:error, _} = invoke(AssistantRevision, :remove_collection, args, actor)
    end

    assert {:ok, _} = invoke(AssistantRevision, :grant_collection, args, ctx.admin)
    assert {:ok, _} = invoke(AssistantRevision, :remove_collection, args, ctx.admin)
    assert {:ok, _} = invoke(AssistantRevision, :grant_collection, args, ctx.admin)
    assert {:ok, _} = invoke(KnowledgeCollection, :disable, %{id: public.id}, ctx.admin)
    publish_args = %{id: revision.id, expected_active_revision_id: nil}
    assert {:error, _} = invoke(AssistantRevision, :publish, publish_args, ctx.admin)
    assert {:ok, _} = invoke(KnowledgeCollection, :enable, %{id: public.id}, ctx.admin)

    assert {:ok, published} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: nil},
               ctx.admin
             )

    assert published.config_hash_version == 2
    assert published.collection_ids == [public.id]
    next = draft(ctx.admin, assistant)

    assert {:ok, next} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: next.id, expected_active_revision_id: published.id},
               ctx.admin
             )

    assert next.collection_ids == []
    refute next.config_hash == published.config_hash
    assert {:error, _} = invoke(AssistantRevision, :remove_collection, args, ctx.admin)
  end

  test "portable import rejects tampering, PII and collisions and round trips a draft", ctx do
    collection = collection(ctx)
    args = draft_args(ctx, collection)

    entry = %{
      "article_ref" => args.article_ref,
      "slug" => args.slug,
      "source_revision_number" => 1,
      "source_content_hash" => Content.hash(elem(Content.parse(payload()), 1)),
      "content" => payload()
    }

    doc = %{"schema_version" => 1, "collection_slug" => collection.slug, "articles" => [entry]}

    invoke_import = fn action, document ->
      invoke(
        KnowledgeCollection,
        action,
        %{id: collection.id, document: Jason.encode!(document)},
        ctx.editor
      )
    end

    for actor <- [
          nil,
          ctx.admin,
          ctx.reviewer,
          %{ctx.editor | generation: ctx.editor.generation + 1}
        ],
        action <- [:preview_import, :apply_import] do
      assert {:error, _} =
               invoke(
                 KnowledgeCollection,
                 action,
                 %{id: collection.id, document: Jason.encode!(doc)},
                 actor
               )
    end

    for actor <- [
          nil,
          ctx.admin,
          ctx.editor,
          %{ctx.reviewer | generation: ctx.reviewer.generation + 1}
        ] do
      assert {:error, _} =
               invoke(KnowledgeCollection, :export_articles, %{id: collection.id}, actor)
    end

    assert {:ok, %{articles: [%{outcome: :create}]}} = invoke_import.(:preview_import, doc)

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(doc, ["articles", Access.at(0), "status"], "approved")
             )

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(
                 doc,
                 [
                   "articles",
                   Access.at(0),
                   "content",
                   "localized_content",
                   Access.at(0),
                   "approved_answer"
                 ],
                 "Contact customer@example.test"
               )
             )

    canonical = elem(Content.parse(payload()), 1)

    pii =
      put_in(
        canonical,
        ["localized_content", Access.at(0), "approved_answer"],
        "Contact customer@example.test"
      )

    pii_entry = %{entry | "content" => pii, "source_content_hash" => Content.hash(pii)}
    assert {:error, _} = invoke_import.(:apply_import, %{doc | "articles" => [pii_entry]})

    assert {:ok, %{articles: [%{outcome: :create, revision_id: revision_id}]}} =
             invoke_import.(:apply_import, doc)

    assert {:ok, %{articles: [%{outcome: :existing}]}} = invoke_import.(:apply_import, doc)

    assert {:error, _} =
             invoke_import.(
               :apply_import,
               put_in(doc, ["articles", Access.at(0), "slug"], "another-slug")
             )

    assert {:ok, %{document: exported}} =
             invoke(KnowledgeCollection, :export_articles, %{id: collection.id}, ctx.reviewer)

    assert {:error, _} =
             invoke(
               KnowledgeCollection,
               :export_articles,
               %{
                 id: collection.id,
                 article_ids: [Ash.UUIDv7.generate()]
               },
               ctx.reviewer
             )

    assert Jason.decode!(exported) ==
             put_in(doc, ["articles", Access.at(0), "content"], elem(Content.parse(payload()), 1))

    assert {:ok, %{articles: [%{outcome: :existing}]}} =
             invoke_import.(:apply_import, Jason.decode!(exported))

    assert {:ok, original} =
             invoke(ArticleRevision, :read_revision, %{id: revision_id}, ctx.reviewer)

    reviewed = review(ctx, original)

    assert {:ok, %{status: :approved}} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    changed =
      put_in(
        canonical,
        ["localized_content", Access.at(0), "approved_answer"],
        "Nuwe sintetiese antwoord."
      )

    changed_entry = %{
      entry
      | "content" => changed,
        "source_content_hash" => Content.hash(changed)
    }

    changed_doc = %{doc | "articles" => [changed_entry]}
    assert {:error, _} = invoke_import.(:apply_import, changed_doc)

    assert {:ok, %{articles: [%{outcome: :new_revision, revision_id: new_id}]}} =
             invoke(
               KnowledgeCollection,
               :apply_import,
               %{
                 id: collection.id,
                 document: Jason.encode!(changed_doc),
                 new_revision_for: original.article_id
               },
               ctx.editor
             )

    assert {:ok, %{revision_number: 2, status: :draft}} =
             invoke(ArticleRevision, :read_revision, %{id: new_id}, ctx.editor)

    assert {:ok, %{status: :approved, content_hash: hash}} =
             invoke(ArticleRevision, :read_revision, %{id: original.id}, ctx.reviewer)

    assert hash == original.content_hash

    assert {:ok, collection_other} =
             invoke(
               KnowledgeCollection,
               :create,
               %{slug: ctx.slug <> "-other", name: "Synthetic FAQs", audience: :public},
               ctx.admin
             )

    assert {:ok, collection_other} =
             invoke(KnowledgeCollection, :enable, %{id: collection_other.id}, ctx.admin)

    scope(ctx, collection_other)

    assert {:error, _} =
             invoke(
               KnowledgeCollection,
               :apply_import,
               %{
                 id: collection_other.id,
                 document: Jason.encode!(%{doc | "collection_slug" => collection_other.slug})
               },
               ctx.editor
             )
  end

  defp compete(operation) do
    assert {:ok, {winner, task}} =
             Repo.transact(fn ->
               assert {:ok, winner} = operation.()
               task = blocked_task(operation)
               {:ok, {winner, task}}
             end)

    assert {:error, _} = Task.await(task, 5_000)
    winner
  end

  defp collection(ctx, suffix \\ "", audience \\ :public) do
    assert {:ok, row} =
             invoke(
               KnowledgeCollection,
               :create,
               %{slug: ctx.slug <> suffix, name: "Synthetic FAQs", audience: audience},
               ctx.admin
             )

    assert {:ok, row} = invoke(KnowledgeCollection, :enable, %{id: row.id}, ctx.admin)
    if suffix == "", do: scope(ctx, row)
    row
  end

  defp scope(ctx, row) do
    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      row.id => %{editors: [ctx.editor.id], reviewers: [ctx.reviewer.id]}
    })
  end

  defp draft_args(ctx, row),
    do: %{
      collection_id: row.id,
      article_ref: "VG-KB-" <> alphabetic_suffix(ctx.slug),
      slug: "synthetic-faq",
      content: payload()
    }

  defp alphabetic_suffix(slug),
    do: for(<<c <- slug>>, into: "", do: <<if(c in ?0..?9, do: ?q + c - ?0, else: c)>>)

  defp draft_revision(ctx, row) do
    assert {:ok, %{revision: rev}} =
             invoke(Article, :create_draft, draft_args(ctx, row), ctx.editor)

    rev
  end

  defp review(ctx, rev) do
    assert {:ok, %{status: :in_review} = reviewed} =
             invoke(ArticleRevision, :submit_review, snapshot(rev), ctx.editor)

    reviewed
  end

  defp snapshot(rev),
    do: %{id: rev.id, expected_hash: rev.content_hash, expected_version: rev.edit_version}

  defp attest(args), do: Map.merge(args, %{source_verified: true, self_approval: false})

  defp payload do
    %{
      "category" => "faq",
      "applicability" => %{},
      "primary_locale" => "en-ZA",
      "localized_content" => [
        %{
          "locale" => "en-ZA",
          "title" => "Synthetic FAQ",
          "approved_answer" => "Synthetic answer."
        },
        %{
          "locale" => "af-ZA",
          "title" => "Sintetiese vrae",
          "approved_answer" => "Sintetiese antwoord."
        }
      ],
      "source_references" => [%{"kind" => "document", "ref" => "synthetic-faq-v1"}],
      "response_mode" => "exact",
      "effective_from" => "2026-01-01T00:00:00Z"
    }
  end
end
