defmodule VoelgoedAi.Repo.Migrations.Vgas20FinancialSafeguards do
  @moduledoc """
  Adds closure audit references, inhibit occurrence identifiers and durable overflow evidence.
  Historical charges, attempts and legacy inhibit flags are preserved.
  """

  use Ecto.Migration

  def up do
    alter table(:audit_events) do
      add(
        :settlement_target_id,
        references(:usage_ledger_entries,
          column: :id,
          name: "audit_events_settlement_target_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict,
          on_update: :restrict
        )
      )
    end

    create(
      unique_index(:audit_events, [:settlement_target_id],
        name: "audit_events_settlement_audit_index"
      )
    )

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

    create(
      constraint(:audit_events, :audit_events_exact_target,
        check: """
            num_nonnulls(settlement_target_id, target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id) = 1
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
              AND event IN ('enable_automation','disable_automation','reset_embedding_inhibit','reset_generation_inhibit'))
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

    alter table(:automation_controls) do
      add(:generation_inhibit_occurrence, :uuid)
      add(:embedding_inhibit_occurrence, :uuid)
    end

    alter table(:inference_runs) do
      add(:overflow_evidence, :map)
      add(:overflow_resolved_at, :utc_datetime_usec)
    end

    create(
      constraint(:inference_runs, :inference_runs_overflow_shape,
        check: """
          (overflow_evidence IS NULL AND overflow_resolved_at IS NULL)
        OR (overflow_evidence IS NOT NULL AND dispatched_at IS NOT NULL
          AND (overflow_resolved_at IS NULL AND state IN ('unknown', 'abandoned')
            OR overflow_resolved_at IS NOT NULL AND state IN ('succeeded', 'failed', 'abandoned')))

        """
      )
    )
  end

  def down do
    execute("""
    LOCK TABLE audit_events, automation_controls, inference_runs IN ACCESS EXCLUSIVE MODE;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM audit_events
        WHERE event IN ('close_unknown_inference','reset_embedding_inhibit','reset_generation_inhibit')
      ) OR EXISTS (
        SELECT 1 FROM inference_runs WHERE overflow_evidence IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM automation_controls
        WHERE embedding_inhibit_occurrence IS NOT NULL OR generation_inhibit_occurrence IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'VGAS-20 rollback would remove financial evidence';
      END IF;
    END
    $$;
    """)

    drop_if_exists(constraint(:inference_runs, :inference_runs_overflow_shape))

    alter table(:inference_runs) do
      remove(:overflow_resolved_at)
      remove(:overflow_evidence)
    end

    alter table(:automation_controls) do
      remove(:embedding_inhibit_occurrence)
      remove(:generation_inhibit_occurrence)
    end

    drop_if_exists(constraint(:audit_events, :audit_events_exact_target))

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

    drop(constraint(:audit_events, "audit_events_settlement_target_id_fkey"))

    drop_if_exists(
      unique_index(:audit_events, [:settlement_target_id],
        name: "audit_events_settlement_audit_index"
      )
    )

    alter table(:audit_events) do
      remove(:settlement_target_id)
    end
  end
end
