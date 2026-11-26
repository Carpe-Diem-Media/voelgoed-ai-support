-- Load after vgas001_upgrade_fixture.sql, on the disposable 4e5feb4 schema.
BEGIN;

INSERT INTO assistants (id, slug, display_name, audience, disabled_at)
VALUES ('019ac560-0000-7000-8000-000000000011', 'synthetic-predecessor', 'Synthetic support', 'public', now());

INSERT INTO assistant_revisions (
  id, assistant_id, created_by_id, published_by_id, revision_number, status,
  locale, response_policy, workflow_version, template_version, config_hash, published_at
) VALUES (
  '019ac560-0000-7000-8000-000000000012', '019ac560-0000-7000-8000-000000000011',
  '019ac560-0000-7000-8000-000000000001', '019ac560-0000-7000-8000-000000000001',
  1, 'published', 'af', 'fixed_reply', 'test-v1', 'test-v1', :'legacy_hash', now()
);

UPDATE assistants SET active_revision_id = '019ac560-0000-7000-8000-000000000012'
WHERE id = '019ac560-0000-7000-8000-000000000011';

INSERT INTO inbox_bindings (
  id, assistant_id, installation_ref, external_account_id, external_inbox_id, credential_ref, handoff_team_id
) VALUES (
  '019ac560-0000-7000-8000-000000000013', '019ac560-0000-7000-8000-000000000011',
  'synthetic-predecessor', 1, 2, 'synthetic', 1
);

INSERT INTO support_sessions (
  id, binding_id, installation_ref, external_account_id, external_inbox_id, conversation_id, correlation_id
) VALUES (
  '019ac560-0000-7000-8000-000000000014', '019ac560-0000-7000-8000-000000000013',
  'synthetic-predecessor', 1, 2, 3, '019ac560-0000-7000-8000-000000000020'
);

INSERT INTO support_runs (
  id, session_id, assistant_revision_id, turn_ref, ownership_epoch, assistant_epoch,
  binding_epoch, control_epoch, deadline_at, batch_cutoff_at, state, reason_code, finished_at, correlation_id
) VALUES (
  '019ac560-0000-7000-8000-000000000015', '019ac560-0000-7000-8000-000000000014',
  '019ac560-0000-7000-8000-000000000012', '019ac560-0000-7000-8000-000000000016',
  0, 0, 0, 0, now(), now(), 'failed', 'deadline', now(), '019ac560-0000-7000-8000-000000000020'
);

INSERT INTO audit_events (
  id, actor_kind, actor_staff_id, target_kind, event, reason_code,
  revision_target_id, operational_after, correlation_id
) VALUES (
  '019ac560-0000-7000-8000-000000000017', 'staff',
  '019ac560-0000-7000-8000-000000000001', 'assistant_revision', 'publish', 'local_admin',
  '019ac560-0000-7000-8000-000000000012', '{"status":"published"}',
  '019ac560-0000-7000-8000-000000000020'
);

INSERT INTO audit_events (id, actor_kind, target_kind, event, reason_code, run_target_id, correlation_id)
VALUES (
  '019ac560-0000-7000-8000-000000000018', 'support_worker', 'support_run', 'missed_deadline', 'deadline',
  '019ac560-0000-7000-8000-000000000015', '019ac560-0000-7000-8000-000000000020'
);

COMMIT;
