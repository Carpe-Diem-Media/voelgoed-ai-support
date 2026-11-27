defmodule VoelgoedAi.KnowledgeFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import VoelgoedAi.StaffFixtures, only: [authenticate: 1, bootstrap_admin: 1]
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, KnowledgeCollection}

  def setup_knowledge(tags) do
    ctx = VoelgoedAi.SupportFixtures.setup()
    admin = bootstrap_admin(ctx.admin)
    assert {:ok, editor} = Accounts.provision(admin, ctx.invited, [:knowledge_editor])
    assert {:ok, editor} = authenticate(editor.id)
    assert {:ok, reviewer} = Accounts.provision(admin, ctx.other, [:knowledge_reviewer])
    assert {:ok, reviewer} = authenticate(reviewer.id)

    original_inhibit =
      if tags[:embedding_index] do
        %{rows: [value]} =
          SQL.query!(
            Repo,
            "SELECT embedding_inhibited, embedding_inhibit_occurrence FROM automation_controls"
          )

        value
      end

    ExUnit.Callbacks.on_exit(fn ->
      if tags[:embedding_index] do
        delete_embedding_fixture(editor.id, original_inhibit)
        fixture(%{})
      end

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

      SQL.query!(
        Repo,
        "UPDATE articles SET current_revision_id = NULL WHERE owner_id::text = ANY($1)",
        [
          [editor.id, reviewer.id]
        ]
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

  def fixture(settings),
    do: Application.put_env(:voelgoed_ai, :embedding_fixture, Map.put(settings, :mode, :fixture))

  def approved(ctx) do
    collection = collection(ctx)
    reviewed = review(ctx, draft_revision(ctx, collection))

    assert {:ok, revision} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), ctx.reviewer)

    {collection, revision}
  end

  def request_index(ctx, revision, action \\ :request_publish) do
    args = Map.put(snapshot(revision), :expected_current_revision_id, nil)

    assert {:ok, %{status: :publishing, publication_generation: generation}} =
             invoke(ArticleRevision, action, args, ctx.reviewer)

    assert %{rows: [[first], [second]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM article_embeddings WHERE revision_id = $1 AND generation = $2 ORDER BY locale",
               [Ecto.UUID.dump!(revision.id), generation]
             )

    [first, second]
  end

  def reservation_rows(id) do
    SQL.query!(
      Repo,
      """
      SELECT i.state, i.dispatched_at IS NOT NULL, r.state, r.reserved_nano_usd, r.actual_nano_usd
      FROM inference_runs i JOIN usage_reservations r ON r.inference_run_id = i.id
      WHERE i.article_embedding_id = $1 ORDER BY i.ordinal
      """,
      [Ecto.UUID.dump!(id)]
    ).rows
  end

  def vector_rows(id) do
    SQL.query!(Repo, "SELECT state, vector_dims(vector) FROM article_embeddings WHERE id = $1", [
      Ecto.UUID.dump!(id)
    ]).rows
  end

  defp delete_embedding_fixture(editor_id, original_inhibit) do
    params = [Ecto.UUID.dump!(editor_id)]
    revision = "SELECT id FROM article_revisions WHERE created_by_id = $1"
    embedding = "SELECT id FROM article_embeddings WHERE revision_id IN (#{revision})"
    attempt = "SELECT id FROM inference_runs WHERE article_embedding_id IN (#{embedding})"

    SQL.query!(
      Repo,
      """
      DELETE FROM oban_jobs
      WHERE (args->>'revision_id')::uuid IN (#{revision})
         OR (args->>'rollback_request_id')::uuid IN (
              SELECT id FROM audit_events WHERE article_revision_target_id IN (#{revision})
            )
      """,
      params
    )

    SQL.query!(
      Repo,
      "DELETE FROM audit_events WHERE actor_kind IN ('embedding_worker', 'publisher') AND article_revision_target_id IN (#{revision})",
      params
    )

    SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE (args->>'embedding_id')::uuid IN (#{embedding})",
      params
    )

    delete_accounting_fixture(attempt, params)

    SQL.query!(
      Repo,
      "UPDATE article_embeddings SET last_attempt_id = NULL, attempt_count = 0, state = 'invalidated', vector = NULL WHERE id IN (#{embedding})",
      params
    )

    SQL.query!(Repo, "DELETE FROM inference_runs WHERE id IN (#{attempt})", params)
    SQL.query!(Repo, "DELETE FROM article_embeddings WHERE id IN (#{embedding})", params)

    SQL.query!(
      Repo,
      "UPDATE automation_controls SET embedding_inhibited = $1, embedding_inhibit_occurrence = $2",
      original_inhibit
    )
  end

  def cleanup_query_attempts(run_id) do
    params = [Ecto.UUID.dump!(run_id)]
    attempt = "SELECT id FROM inference_runs WHERE support_run_id = $1"
    delete_accounting_fixture(attempt, params)
    SQL.query!(Repo, "DELETE FROM inference_runs WHERE id IN (#{attempt})", params)
  end

  defp delete_accounting_fixture(attempt, params) do
    SQL.query!(
      Repo,
      """
      DELETE FROM audit_events WHERE settlement_target_id IN (
        SELECT id FROM usage_ledger_entries WHERE inference_run_id IN (#{attempt})
      )
      """,
      params
    )

    SQL.query!(
      Repo,
      """
      WITH charges AS (
        SELECT r.day_window, r.month_window, l.amount_nano_usd
        FROM usage_ledger_entries l JOIN usage_reservations r ON r.id = l.reservation_id
        WHERE l.inference_run_id IN (#{attempt})
      ), deltas AS (
        SELECT 'day' AS kind, day_window AS window_start, sum(amount_nano_usd) AS amount
        FROM charges GROUP BY day_window
        UNION ALL
        SELECT 'month', month_window, sum(amount_nano_usd)
        FROM charges GROUP BY month_window
      )
      UPDATE spend_windows w SET settled_nano_usd = w.settled_nano_usd - d.amount
      FROM deltas d WHERE d.kind = w.kind AND d.window_start = w.window_start
      """,
      params
    )

    SQL.query!(
      Repo,
      "DELETE FROM usage_ledger_entries WHERE corrects_id IS NOT NULL AND inference_run_id IN (#{attempt})",
      params
    )

    SQL.query!(
      Repo,
      "DELETE FROM usage_ledger_entries WHERE inference_run_id IN (#{attempt})",
      params
    )

    SQL.query!(
      Repo,
      "DELETE FROM usage_reservations WHERE inference_run_id IN (#{attempt})",
      params
    )
  end

  def collection(ctx, suffix \\ "", audience \\ :public) do
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

  def scope(ctx, row) do
    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      row.id => %{editors: [ctx.editor.id], reviewers: [ctx.reviewer.id]}
    })
  end

  def draft_args(ctx, row),
    do: %{
      collection_id: row.id,
      article_ref: "VG-KB-" <> alphabetic_suffix(ctx.slug),
      slug: "synthetic-faq",
      content: payload()
    }

  def alphabetic_suffix(slug),
    do: for(<<c <- slug>>, into: "", do: <<if(c in ?0..?9, do: ?q + c - ?0, else: c)>>)

  def draft_revision(ctx, row) do
    assert {:ok, %{revision: rev}} =
             invoke(Article, :create_draft, draft_args(ctx, row), ctx.editor)

    rev
  end

  def review(ctx, rev) do
    assert {:ok, %{status: :in_review} = reviewed} =
             invoke(ArticleRevision, :submit_review, snapshot(rev), ctx.editor)

    reviewed
  end

  def snapshot(rev),
    do: %{id: rev.id, expected_hash: rev.content_hash, expected_version: rev.edit_version}

  def attest(args), do: Map.merge(args, %{source_verified: true, self_approval: false})

  def payload do
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
