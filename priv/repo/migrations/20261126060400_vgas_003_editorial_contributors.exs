defmodule VoelgoedAi.Repo.Migrations.Vgas003EditorialContributors do
  @moduledoc "Records editorial contributors and backfills revisions from the prior schema."

  use Ecto.Migration

  def up do
    alter table(:article_revisions) do
      add(:contributor_ids, {:array, :uuid}, null: false, default: [])
    end

    execute("""
    WITH contributions AS (
      SELECT id AS revision_id, created_by_id AS staff_id FROM article_revisions
      UNION ALL
      SELECT article_revision_target_id, actor_staff_id
      FROM audit_events
      WHERE target_kind = 'knowledge_revision'
        AND event IN ('edit_draft', 'submit_review')
    ), contributors AS (
      SELECT revision_id, array_agg(DISTINCT staff_id ORDER BY staff_id) AS staff_ids
      FROM contributions
      GROUP BY revision_id
    )
    UPDATE article_revisions AS revision
    SET contributor_ids = contributors.staff_ids
    FROM contributors
    WHERE revision.id = contributors.revision_id
    """)
  end

  def down do
    # Dropping this column would restore creator-only approval on existing revisions.
    execute("LOCK TABLE article_revisions IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM article_revisions) THEN
        RAISE EXCEPTION 'VGAS-003 editorial contributor history exists. Restore an approved predecessor backup instead.';
      END IF;
    END $$;
    """)

    alter table(:article_revisions) do
      remove(:contributor_ids)
    end
  end
end
