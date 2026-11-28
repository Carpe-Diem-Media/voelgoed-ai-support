defmodule VoelgoedAi.Repo.Migrations.Vgas29Operations do
  @moduledoc """
  Adds emergency fencing, assisted provenance and durable operator attention.
  """

  use Ecto.Migration

  def up do
    alter table(:automation_controls) do
      add(:emergency_latched, :boolean, null: false, default: false)
    end

    alter table(:support_binding_circuits) do
      add(:permanent_epoch, :bigint)
    end

    create table(:support_alert_episodes, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:binding_id, references(:inbox_bindings, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:kind, :text, null: false)
      add(:episode, :text, null: false)
      add(:opened_at, :timestamptz, null: false)
      add(:closed_at, :timestamptz)
    end

    create(unique_index(:support_alert_episodes, [:binding_id, :kind, :episode]))

    create(
      unique_index(:support_alert_episodes, [:binding_id],
        name: :support_alert_episodes_one_open_queue,
        where: "kind = 'queue_overdue' AND closed_at IS NULL"
      )
    )

    create(
      constraint(:support_alert_episodes, :support_alert_episodes_shape,
        check: """
        kind IN ('queue_overdue', 'circuit_open', 'delivery_unknown', 'handoff_failed') AND
        (closed_at IS NULL OR (kind = 'queue_overdue' AND closed_at >= opened_at))
        """
      )
    )

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

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
              AND event IN ('create_draft','enable','disable','rebind','change_mode','retire','recover_circuit'))
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
              AND event IN ('abandon_delivery','request_readback','delivery_unknown','handoff_failed','local_handoff'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event IN ('missed_deadline','hold_reply','release_reply','purge_reply'))
          )

        """
      )
    )

    alter table(:support_runs) do
      add(:assisted_draft, :boolean, null: false, default: false)
    end

    create(
      constraint(:support_runs, :support_runs_assisted_provenance,
        check: """
          NOT assisted_draft OR (state = 'completed' AND decision = 'no_send'
          AND (retention_state = 'purged' OR
            (shadow_disposition = 'no_send' AND evidence_refs IS NOT NULL))) IS TRUE

        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM automation_controls WHERE emergency_latched OR status = 'enabled')
        OR EXISTS (SELECT 1 FROM support_runs WHERE assisted_draft)
        OR EXISTS (SELECT 1 FROM support_alert_episodes)
        OR EXISTS (SELECT 1 FROM support_binding_circuits WHERE permanent_epoch IS NOT NULL)
        OR EXISTS (SELECT 1 FROM audit_events WHERE event IN ('recover_circuit', 'request_readback'))
      THEN
        RAISE EXCEPTION 'VGAS-29 rollback would remove operational safety state';
      END IF;
    END
    $$;
    """)

    drop(table(:support_alert_episodes))

    alter table(:support_binding_circuits) do
      remove(:permanent_epoch)
    end

    alter table(:automation_controls) do
      remove(:emergency_latched)
    end

    drop_if_exists(constraint(:support_runs, :support_runs_assisted_provenance))

    alter table(:support_runs) do
      remove(:assisted_draft)
    end

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

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
  end
end
