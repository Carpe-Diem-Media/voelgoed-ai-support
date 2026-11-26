defmodule VoelgoedAi.Repo.Migrations.Vgas003b2aPublication do
  @moduledoc "Adds the publication and active index lifecycle without activating B1 rows."

  use Ecto.Migration

  def up do
    alter table(:article_revisions) do
      add(:published_at, :utc_datetime_usec)
      add(:publication_expires_at, :utc_datetime_usec)
      add(:active_index_generation, :bigint)
      add(:active_index_profile_id, :text)
      add(:retained_index_generation, :bigint)
      add(:reindex_base_generation, :bigint)
      add(:index_epoch, :bigint, null: false, default: 0)
      add(:index_evaluation, :map)
    end

    drop_if_exists(constraint(:article_revisions, :article_revisions_publication_request))

    drop_if_exists(constraint(:article_revisions, :article_revisions_editorial_lifecycle))

    create(
      constraint(:article_revisions, :article_revisions_active_index,
        check: """
          index_epoch >= 0
        AND ((status = 'published' AND published_at IS NOT NULL AND index_epoch > 0
              AND active_index_generation IS NOT NULL AND active_index_generation > 0
              AND active_index_generation <= publication_generation AND active_index_profile_id IS NOT NULL)
          OR (status <> 'published' AND active_index_generation IS NULL AND active_index_profile_id IS NULL
              AND retained_index_generation IS NULL AND reindex_base_generation IS NULL
              AND publication_expires_at IS NULL AND index_evaluation IS NULL))
        AND (retained_index_generation IS NULL OR (retained_index_generation > 0
          AND retained_index_generation <= publication_generation AND retained_index_generation <> active_index_generation))
        AND (reindex_base_generation IS NULL OR (reindex_base_generation = active_index_generation
          AND publication_generation > active_index_generation AND expected_current_revision_id IS NOT NULL
          AND expected_current_revision_id = id))

        """
      )
    )

    create(
      constraint(:article_revisions, :article_revisions_publication_request,
        check: """
          publication_generation >= 0
        AND ((publication_generation = 0 AND publication_requested_by_id IS NULL
              AND publication_collection_epoch IS NULL AND publication_deadline_at IS NULL AND publication_profile_id IS NULL)
          OR (publication_generation > 0 AND publication_requested_by_id IS NOT NULL
              AND publication_collection_epoch >= 0 AND publication_collection_epoch IS NOT NULL
              AND publication_deadline_at IS NOT NULL AND publication_profile_id IS NOT NULL
              AND status IN ('publishing','publish_failed','revoked','published','superseded','expired')))
        AND (status NOT IN ('publishing','publish_failed') OR publication_generation > 0)
        AND (status <> 'publish_failed' OR publication_reason IS NOT NULL)

        """
      )
    )

    create(
      constraint(:article_revisions, :article_revisions_editorial_lifecycle,
        check: """
          revision_number > 0 AND edit_version > 0 AND content_hash_version = 1
        AND content_hash ~ '^[a-f0-9]{64}$'
        AND (
          (status IN ('draft','withdrawn') AND review_hash IS NULL AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status = 'in_review' AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status IN ('approved','revoked','publishing','publish_failed','published','superseded','expired') AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NOT NULL AND approved_at IS NOT NULL)
        )

        """
      )
    )

    create(
      index(:article_revisions, [:article_id],
        name: "article_revisions_one_published",
        unique: true,
        where: "status = 'published'"
      )
    )

    create(
      index(:article_revisions, [:publication_deadline_at, :id],
        name: "article_revisions_pending_index",
        where: "status = 'publishing' OR reindex_base_generation IS NOT NULL"
      )
    )

    create(
      index(:article_revisions, [:publication_expires_at, :id],
        name: "article_revisions_expiry",
        where: "status = 'published' AND publication_expires_at IS NOT NULL"
      )
    )

    drop_if_exists(constraint(:audit_events, :audit_events_actor_reference))

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

    drop_if_exists(constraint(:audit_events, :audit_events_state_shape))

    create(
      constraint(:audit_events, :audit_events_actor_reference,
        check: """
          (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
        OR (actor_kind IN ('support_worker','embedding_worker','publisher') AND actor_staff_id IS NULL AND operator_ref IS NULL)

        """
      )
    )

    create(
      constraint(:audit_events, :audit_events_exact_target,
        check: """
            num_nonnulls(target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id) = 1
          AND (
            (target_kind = 'staff_user' AND target_id IS NOT NULL
              AND event IN ('provisioned','activated','signed_in','roles_changed','disabled','reactivated','retired')
              AND reason_code IN ('allowlisted','verified_oidc','local_admin','approved_reprovision'))
            OR (target_kind = 'assistant' AND assistant_target_id IS NOT NULL
              AND event IN ('create','activate','disable','retire','switch_revision'))
            OR (target_kind = 'assistant_revision' AND revision_target_id IS NOT NULL
              AND event IN ('create_draft','edit_draft','publish','supersede','discard','grant_collection','remove_collection'))
            OR (target_kind = 'inbox_binding' AND binding_target_id IS NOT NULL
              AND event IN ('create_draft','enable','disable','rebind','change_mode','retire'))
            OR (target_kind = 'automation_control' AND control_target_id IS NOT NULL
              AND event IN ('enable_automation','disable_automation'))
            OR (target_kind = 'knowledge_collection' AND knowledge_collection_target_id IS NOT NULL
              AND event IN ('create','enable','disable','retire') AND reason_code = 'local_admin')
            OR (target_kind = 'knowledge_article' AND article_target_id IS NOT NULL
              AND ((event = 'create_draft' AND reason_code = 'local_editor')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'knowledge_revision' AND article_revision_target_id IS NOT NULL
              AND ((event IN ('create_draft','edit_draft','submit_review') AND reason_code = 'local_editor')
                OR (event = 'request_changes' AND reason_code IN ('source_correction','content_correction'))
                OR (event = 'approve' AND reason_code IN ('source_verified','self_approval_attested'))
                OR (event = 'withdraw' AND reason_code = 'withdrawn_by_staff')
                OR (event IN ('request_publish','retry_publication','request_reindex','request_index_rollback') AND reason_code = 'source_verified')
                OR (event = 'revoke' AND reason_code = 'obsolete')
                OR (event IN ('fail_publication','fail_reindex') AND reason_code IN ('deadline','stale_request','transport_unknown','invalid_vector','admission_denied'))
                OR (event IN ('activate','switch_index') AND reason_code = 'index_ready')
                OR (event = 'supersede' AND reason_code = 'replaced')
                OR (event = 'expire' AND reason_code = 'deadline')
                OR (event = 'rollback_index' AND reason_code = 'evaluated')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event IN ('abandon_delivery','delivery_unknown','handoff_failed'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event = 'missed_deadline')
          )

        """
      )
    )

    create(
      constraint(:audit_events, :audit_events_state_shape,
        check: """
            (target_kind = 'staff_user' AND actor_kind IN ('staff','bootstrap') AND after_state IS NOT NULL
            AND operational_before IS NULL AND operational_after IS NULL)
          OR (actor_kind = 'staff' AND before_state IS NULL AND after_state IS NULL AND operational_after IS NOT NULL
            AND event NOT IN ('delivery_unknown','missed_deadline','handoff_failed','fail_publication','fail_reindex','expire','switch_index','rollback_index')
            AND (target_kind <> 'knowledge_revision' OR event NOT IN ('activate','supersede'))
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (actor_kind = 'embedding_worker' AND target_kind = 'knowledge_revision'
            AND event IN ('fail_publication','fail_reindex') AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NOT NULL AND operational_after IS NOT NULL)
          OR (actor_kind = 'publisher' AND target_kind = 'knowledge_revision'
            AND before_state IS NULL AND after_state IS NULL AND
            (CASE event
              WHEN 'activate' THEN operational_before->>'status' = 'publishing' AND operational_after->>'status' = 'published'
              WHEN 'supersede' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'superseded'
              WHEN 'expire' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'expired'
              WHEN 'switch_index' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              WHEN 'rollback_index' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              ELSE false END) IS TRUE)
          OR (actor_kind = 'support_worker' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND ((event = 'delivery_unknown' AND reason_code IN ('ignored','oversize','admission_limited','deadline','scope_denied','disabled','human_takeover','resolved','stale_claim','stale_policy','late_input','history_changed','unavailable','ambiguous_write','awaiting_operator','accepted','already_human','explicit_handoff','manual_closure','no_effect','read_exhausted'))
              OR (event = 'missed_deadline' AND reason_code = 'deadline')
              OR (event = 'handoff_failed' AND reason_code IN ('deadline','read_exhausted','no_effect'))))

        """
      )
    )
  end

  def down do
    execute("""
    LOCK TABLE article_revisions, audit_events IN ACCESS EXCLUSIVE MODE
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM article_revisions WHERE index_epoch > 0 OR published_at IS NOT NULL
                 OR status IN ('published','superseded','expired')
                 OR reindex_base_generation IS NOT NULL OR index_evaluation IS NOT NULL)
         OR EXISTS (SELECT 1 FROM audit_events WHERE actor_kind = 'publisher'
                    OR event IN ('request_reindex','request_index_rollback','fail_reindex')) THEN
        RAISE EXCEPTION 'VGAS-003 B2a rollback blocked because publication or index maintenance history exists';
      END IF;
    END $$
    """)

    drop_if_exists(constraint(:audit_events, :audit_events_state_shape))

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

    drop_if_exists(constraint(:audit_events, :audit_events_actor_reference))

    create(
      constraint(:audit_events, :audit_events_state_shape,
        check: """
            (target_kind = 'staff_user' AND actor_kind IN ('staff','bootstrap') AND after_state IS NOT NULL
            AND operational_before IS NULL AND operational_after IS NULL)
          OR (actor_kind = 'staff' AND before_state IS NULL AND after_state IS NULL AND operational_after IS NOT NULL
            AND event NOT IN ('delivery_unknown','missed_deadline','handoff_failed','fail_publication')
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (actor_kind = 'embedding_worker' AND target_kind = 'knowledge_revision'
            AND event = 'fail_publication' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NOT NULL AND operational_after IS NOT NULL)
          OR (actor_kind = 'support_worker' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND ((event = 'delivery_unknown' AND reason_code IN ('ignored','oversize','admission_limited','deadline','scope_denied','disabled','human_takeover','resolved','stale_claim','stale_policy','late_input','history_changed','unavailable','ambiguous_write','awaiting_operator','accepted','already_human','explicit_handoff','manual_closure','no_effect','read_exhausted'))
              OR (event = 'missed_deadline' AND reason_code = 'deadline')
              OR (event = 'handoff_failed' AND reason_code IN ('deadline','read_exhausted','no_effect'))))

        """
      )
    )

    create(
      constraint(:audit_events, :audit_events_exact_target,
        check: """
            num_nonnulls(target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id) = 1
          AND (
            (target_kind = 'staff_user' AND target_id IS NOT NULL
              AND event IN ('provisioned','activated','signed_in','roles_changed','disabled','reactivated','retired')
              AND reason_code IN ('allowlisted','verified_oidc','local_admin','approved_reprovision'))
            OR (target_kind = 'assistant' AND assistant_target_id IS NOT NULL
              AND event IN ('create','activate','disable','retire','switch_revision'))
            OR (target_kind = 'assistant_revision' AND revision_target_id IS NOT NULL
              AND event IN ('create_draft','edit_draft','publish','supersede','discard','grant_collection','remove_collection'))
            OR (target_kind = 'inbox_binding' AND binding_target_id IS NOT NULL
              AND event IN ('create_draft','enable','disable','rebind','change_mode','retire'))
            OR (target_kind = 'automation_control' AND control_target_id IS NOT NULL
              AND event IN ('enable_automation','disable_automation'))
            OR (target_kind = 'knowledge_collection' AND knowledge_collection_target_id IS NOT NULL
              AND event IN ('create','enable','disable','retire') AND reason_code = 'local_admin')
            OR (target_kind = 'knowledge_article' AND article_target_id IS NOT NULL
              AND ((event = 'create_draft' AND reason_code = 'local_editor')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'knowledge_revision' AND article_revision_target_id IS NOT NULL
              AND ((event IN ('create_draft','edit_draft','submit_review') AND reason_code = 'local_editor')
                OR (event = 'request_changes' AND reason_code IN ('source_correction','content_correction'))
                OR (event = 'approve' AND reason_code IN ('source_verified','self_approval_attested'))
                OR (event = 'withdraw' AND reason_code = 'withdrawn_by_staff')
                OR (event IN ('request_publish','retry_publication') AND reason_code = 'source_verified')
                OR (event = 'revoke' AND reason_code = 'obsolete')
                OR (event = 'fail_publication' AND reason_code IN ('deadline','stale_request','transport_unknown','invalid_vector','admission_denied'))
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event IN ('abandon_delivery','delivery_unknown','handoff_failed'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event = 'missed_deadline')
          )

        """
      )
    )

    create(
      constraint(:audit_events, :audit_events_actor_reference,
        check: """
          (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
        OR (actor_kind IN ('support_worker','embedding_worker') AND actor_staff_id IS NULL AND operator_ref IS NULL)

        """
      )
    )

    drop_if_exists(
      index(:article_revisions, [:publication_expires_at, :id], name: "article_revisions_expiry")
    )

    drop_if_exists(
      index(:article_revisions, [:publication_deadline_at, :id],
        name: "article_revisions_pending_index"
      )
    )

    drop_if_exists(
      index(:article_revisions, [:article_id], name: "article_revisions_one_published")
    )

    drop_if_exists(constraint(:article_revisions, :article_revisions_editorial_lifecycle))

    drop_if_exists(constraint(:article_revisions, :article_revisions_publication_request))

    drop_if_exists(constraint(:article_revisions, :article_revisions_active_index))

    create(
      constraint(:article_revisions, :article_revisions_editorial_lifecycle,
        check: """
          revision_number > 0 AND edit_version > 0 AND content_hash_version = 1
        AND content_hash ~ '^[a-f0-9]{64}$'
        AND (
          (status IN ('draft','withdrawn') AND review_hash IS NULL AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status = 'in_review' AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status IN ('approved','revoked','publishing','publish_failed') AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NOT NULL AND approved_at IS NOT NULL)
        )

        """
      )
    )

    create(
      constraint(:article_revisions, :article_revisions_publication_request,
        check: """
          publication_generation >= 0
        AND ((publication_generation = 0 AND publication_requested_by_id IS NULL
              AND publication_collection_epoch IS NULL AND publication_deadline_at IS NULL AND publication_profile_id IS NULL)
          OR (publication_generation > 0 AND publication_requested_by_id IS NOT NULL
              AND publication_collection_epoch >= 0 AND publication_collection_epoch IS NOT NULL
              AND publication_deadline_at IS NOT NULL AND publication_profile_id IS NOT NULL
              AND status IN ('publishing','publish_failed','revoked')))
        AND (status NOT IN ('publishing','publish_failed') OR publication_generation > 0)
        AND (status <> 'publish_failed' OR publication_reason IS NOT NULL)

        """
      )
    )

    alter table(:article_revisions) do
      remove(:index_evaluation)
      remove(:index_epoch)
      remove(:reindex_base_generation)
      remove(:retained_index_generation)
      remove(:active_index_profile_id)
      remove(:active_index_generation)
      remove(:publication_expires_at)
      remove(:published_at)
    end
  end
end
