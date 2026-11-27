defmodule VoelgoedAi.Repo.Migrations.Vgas28ReplyRetention do
  @moduledoc """
  Classifies existing text-bearing decisions and adds monotone, audited retention.
  Downgrade is safe only before any retention transition has occurred.
  """

  use Ecto.Migration

  def up do
    execute("""
    DROP TRIGGER support_runs_immutable_shadow_completion ON support_runs
    """)

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

    drop_if_exists(constraint(:audit_events, :audit_events_state_shape))

    create(
      constraint(:audit_events, :audit_events_exact_target,
        check: """
            num_nonnulls(settlement_target_id, target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id, knowledge_gap_target_id) = 1
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
              AND event IN ('enable_automation','disable_automation','reset_embedding_inhibit','reset_generation_inhibit','trip_generation_inhibit','trip_embedding_inhibit'))
            OR (target_kind = 'usage_settlement' AND settlement_target_id IS NOT NULL
              AND event = 'close_unknown_inference' AND reason_code = 'local_admin')
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
            OR (target_kind = 'knowledge_gap' AND knowledge_gap_target_id IS NOT NULL
              AND ((event = 'gap_dismissed' AND reason_code IN ('duplicate_issue','out_of_scope','no_change_needed'))
                OR (event IN ('gap_reviewed','gap_deferred','gap_addressed') AND reason_code = 'local_admin')))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event IN ('abandon_delivery','delivery_unknown','handoff_failed','local_handoff'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event IN ('missed_deadline','hold_reply','release_reply','purge_reply'))
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
            AND event NOT IN ('hold_reply','release_reply','purge_reply','gap_reviewed','gap_deferred','gap_dismissed','gap_addressed','delivery_unknown','missed_deadline','handoff_failed','fail_publication','fail_reindex','expire','switch_index','rollback_index','trip_generation_inhibit','trip_embedding_inhibit')
            AND (target_kind <> 'knowledge_revision' OR event NOT IN ('activate','supersede'))
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (target_kind = 'support_run' AND before_state IS NULL AND after_state IS NULL
            AND operational_after->>'retention_occurrence' IS NOT NULL
            AND (CASE event
              WHEN 'hold_reply' THEN actor_kind = 'staff' AND reason_code = 'fixture_hold'
                AND operational_before->>'status' = 'present' AND operational_after->>'status' = 'held'
              WHEN 'release_reply' THEN actor_kind = 'staff' AND reason_code = 'fixture_release'
                AND operational_before->>'status' = 'held'
                AND operational_before->>'retention_occurrence' IS NOT NULL
                AND operational_after->>'status' IN ('present','purged')
              WHEN 'purge_reply' THEN actor_kind = 'support_worker' AND reason_code = 'synthetic_cutoff'
                AND operational_before->>'status' = 'present' AND operational_after->>'status' = 'purged'
              ELSE false END) IS TRUE)
          OR (actor_kind = 'staff' AND target_kind = 'knowledge_gap'
            AND before_state IS NULL AND after_state IS NULL
            AND (CASE event
              WHEN 'gap_reviewed' THEN operational_before->>'status' = 'open' AND operational_after->>'status' = 'in_review'
              WHEN 'gap_deferred' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'open'
              WHEN 'gap_dismissed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'dismissed'
              WHEN 'gap_addressed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'addressed'
              ELSE false END) IS TRUE)
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
              WHEN 'fail_publication' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'publishing' AND operational_after->>'status' = 'publish_failed'
              WHEN 'fail_reindex' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              ELSE false END) IS TRUE)
          OR (target_kind = 'automation_control' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND reason_code IN ('over_reserve','amount_overflow')
            AND ((actor_kind = 'support_worker' AND event = 'trip_generation_inhibit')
              OR (actor_kind = 'embedding_worker' AND event = 'trip_embedding_inhibit')))
          OR (actor_kind = 'support_worker' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND ((event = 'delivery_unknown' AND reason_code IN ('ignored','oversize','admission_limited','human_requested','budget_exhausted','verified_misuse','ai_cooldown','idle_triage','deadline','scope_denied','disabled','human_takeover','resolved','stale_claim','stale_policy','late_input','history_changed','unavailable','ambiguous_write','awaiting_operator','accepted','already_human','explicit_handoff','manual_closure','no_effect','read_exhausted'))
              OR (event = 'missed_deadline' AND reason_code = 'deadline')
              OR (event = 'local_handoff' AND target_kind = 'outbound_delivery' AND
                reason_code IN ('human_requested','admission_limited','budget_exhausted','idle_triage'))
              OR (event = 'handoff_failed' AND reason_code IN ('deadline','read_exhausted','no_effect'))))

        """
      )
    )

    alter table(:support_runs) do
      add(:retention_state, :text)
      add(:retention_occurrence, :uuid)
    end

    execute("""
    UPDATE support_runs
    SET retention_state = 'present'
    WHERE jsonb_typeof(typed_decision->'reply_text') = 'string'
    """)

    create(
      constraint(:support_runs, :support_runs_reply_retention,
        check: """
          (CASE
          WHEN jsonb_typeof(typed_decision->'reply_text') = 'string' THEN
            state = 'completed' AND retention_state IN ('present', 'held')
            AND typed_decision->>'decision' IN ('answer_grounded', 'clarify')
            AND (retention_state <> 'held' OR retention_occurrence IS NOT NULL)
          WHEN retention_state = 'purged' THEN
            state = 'completed' AND retention_occurrence IS NOT NULL
            AND typed_decision->>'decision' IN ('answer_grounded', 'clarify')
            AND NOT (typed_decision ? 'reply_text')
          ELSE retention_state IS NULL AND retention_occurrence IS NULL
            AND typed_decision->>'decision' IS DISTINCT FROM 'answer_grounded'
            AND (typed_decision IS NULL OR typed_decision ? 'reply_text')
        END) IS TRUE

        """
      )
    )

    execute("""
    CREATE FUNCTION guard_support_run_reply_retention() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.retention_state IS NULL AND OLD.state = 'running'
          AND NEW.state = 'completed' AND NEW.retention_state = 'present'
          AND NEW.retention_occurrence IS NULL THEN
        RETURN NEW;
      END IF;

      IF OLD.state = 'completed'
          AND ((OLD.retention_state = 'present' AND NEW.retention_state IN ('held', 'purged'))
            OR (OLD.retention_state = 'held' AND NEW.retention_state IN ('present', 'purged')))
          AND NEW.retention_occurrence IS NOT NULL
          AND OLD.retention_occurrence IS DISTINCT FROM NEW.retention_occurrence
          AND (to_jsonb(OLD) - ARRAY['retention_state','retention_occurrence','typed_decision','updated_at'])
            = (to_jsonb(NEW) - ARRAY['retention_state','retention_occurrence','typed_decision','updated_at'])
          AND NEW.typed_decision = (CASE WHEN NEW.retention_state = 'purged'
            THEN OLD.typed_decision - 'reply_text'
            ELSE OLD.typed_decision END) THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'invalid reply retention transition' USING ERRCODE = 'check_violation';
    END
    $$;
    """)

    execute("""
    CREATE TRIGGER support_runs_reply_retention_transition
      BEFORE UPDATE ON support_runs FOR EACH ROW
      WHEN (OLD.retention_state IS DISTINCT FROM NEW.retention_state
        OR OLD.retention_occurrence IS DISTINCT FROM NEW.retention_occurrence
        OR (OLD.retention_state IS NOT NULL AND OLD.typed_decision IS DISTINCT FROM NEW.typed_decision)
        OR (OLD.retention_state IS NOT NULL AND OLD.finished_at IS DISTINCT FROM NEW.finished_at))
      EXECUTE FUNCTION guard_support_run_reply_retention();
    """)

    execute("""
    CREATE TRIGGER support_runs_immutable_shadow_completion
      BEFORE UPDATE OF typed_decision, shadow_disposition ON support_runs
      FOR EACH ROW
      WHEN (OLD.state <> 'running' AND
        (OLD.typed_decision IS DISTINCT FROM NEW.typed_decision OR
         OLD.shadow_disposition IS DISTINCT FROM NEW.shadow_disposition)
       AND NEW.retention_state IS DISTINCT FROM 'purged')
      EXECUTE FUNCTION guard_support_run_shadow_completion();
    """)
  end

  def down do
    execute("LOCK TABLE support_runs, audit_events IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM support_runs WHERE retention_occurrence IS NOT NULL)
          OR EXISTS (SELECT FROM audit_events WHERE event IN ('hold_reply','release_reply','purge_reply')) THEN
        RAISE EXCEPTION 'cannot roll back recorded reply retention transitions'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$;
    """)

    execute("""
    DROP TRIGGER support_runs_immutable_shadow_completion ON support_runs
    """)

    execute("""
    DROP TRIGGER support_runs_reply_retention_transition ON support_runs
    """)

    execute("""
    DROP FUNCTION guard_support_run_reply_retention()
    """)

    drop_if_exists(constraint(:support_runs, :support_runs_reply_retention))

    alter table(:support_runs) do
      remove(:retention_occurrence)
      remove(:retention_state)
    end

    drop_if_exists(constraint(:audit_events, :audit_events_state_shape))

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

    create(
      constraint(:audit_events, :audit_events_state_shape,
        check: """
            (target_kind = 'staff_user' AND actor_kind IN ('staff','bootstrap') AND after_state IS NOT NULL
            AND operational_before IS NULL AND operational_after IS NULL)
          OR (actor_kind = 'staff' AND before_state IS NULL AND after_state IS NULL AND operational_after IS NOT NULL
            AND event NOT IN ('gap_reviewed','gap_deferred','gap_dismissed','gap_addressed','delivery_unknown','missed_deadline','handoff_failed','fail_publication','fail_reindex','expire','switch_index','rollback_index','trip_generation_inhibit','trip_embedding_inhibit')
            AND (target_kind <> 'knowledge_revision' OR event NOT IN ('activate','supersede'))
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (actor_kind = 'staff' AND target_kind = 'knowledge_gap'
            AND before_state IS NULL AND after_state IS NULL
            AND (CASE event
              WHEN 'gap_reviewed' THEN operational_before->>'status' = 'open' AND operational_after->>'status' = 'in_review'
              WHEN 'gap_deferred' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'open'
              WHEN 'gap_dismissed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'dismissed'
              WHEN 'gap_addressed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'addressed'
              ELSE false END) IS TRUE)
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
              WHEN 'fail_publication' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'publishing' AND operational_after->>'status' = 'publish_failed'
              WHEN 'fail_reindex' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              ELSE false END) IS TRUE)
          OR (target_kind = 'automation_control' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND reason_code IN ('over_reserve','amount_overflow')
            AND ((actor_kind = 'support_worker' AND event = 'trip_generation_inhibit')
              OR (actor_kind = 'embedding_worker' AND event = 'trip_embedding_inhibit')))
          OR (actor_kind = 'support_worker' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND ((event = 'delivery_unknown' AND reason_code IN ('ignored','oversize','admission_limited','human_requested','budget_exhausted','verified_misuse','ai_cooldown','idle_triage','deadline','scope_denied','disabled','human_takeover','resolved','stale_claim','stale_policy','late_input','history_changed','unavailable','ambiguous_write','awaiting_operator','accepted','already_human','explicit_handoff','manual_closure','no_effect','read_exhausted'))
              OR (event = 'missed_deadline' AND reason_code = 'deadline')
              OR (event = 'local_handoff' AND target_kind = 'outbound_delivery' AND
                reason_code IN ('human_requested','admission_limited','budget_exhausted','idle_triage'))
              OR (event = 'handoff_failed' AND reason_code IN ('deadline','read_exhausted','no_effect'))))

        """
      )
    )

    create(
      constraint(:audit_events, :audit_events_exact_target,
        check: """
            num_nonnulls(settlement_target_id, target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id, knowledge_gap_target_id) = 1
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
              AND event IN ('enable_automation','disable_automation','reset_embedding_inhibit','reset_generation_inhibit','trip_generation_inhibit','trip_embedding_inhibit'))
            OR (target_kind = 'usage_settlement' AND settlement_target_id IS NOT NULL
              AND event = 'close_unknown_inference' AND reason_code = 'local_admin')
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
            OR (target_kind = 'knowledge_gap' AND knowledge_gap_target_id IS NOT NULL
              AND ((event = 'gap_dismissed' AND reason_code IN ('duplicate_issue','out_of_scope','no_change_needed'))
                OR (event IN ('gap_reviewed','gap_deferred','gap_addressed') AND reason_code = 'local_admin')))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event IN ('abandon_delivery','delivery_unknown','handoff_failed','local_handoff'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event = 'missed_deadline')
          )

        """
      )
    )

    execute("""
    CREATE TRIGGER support_runs_immutable_shadow_completion
      BEFORE UPDATE OF typed_decision, shadow_disposition ON support_runs
      FOR EACH ROW
      WHEN (OLD.state <> 'running' AND
        (OLD.typed_decision IS DISTINCT FROM NEW.typed_decision OR
         OLD.shadow_disposition IS DISTINCT FROM NEW.shadow_disposition))
      EXECUTE FUNCTION guard_support_run_shadow_completion();
    """)
  end
end
