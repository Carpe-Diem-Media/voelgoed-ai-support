-- Run only against the disposable VGAS-001 predecessor schema in migration CI.
BEGIN;

INSERT INTO staff_users (
  id, identity_issuer, identity_subject, tenant_id, identity_client_id, roles
) VALUES (
  '019ac560-0000-7000-8000-000000000001', 'https://issuer.example.test/v2.0',
  'vgas001-upgrade-fixture', '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222', ARRAY['admin']
);

INSERT INTO audit_events (
  id, target_id, actor_kind, operator_ref, event, reason_code, after_state, correlation_id
) VALUES (
  '019ac560-0000-7000-8000-000000000002', '019ac560-0000-7000-8000-000000000001',
  'bootstrap', 'staff-bootstrap', 'provisioned', 'allowlisted',
  '{"status":"invited","roles":["admin"],"session_generation":0}',
  '019ac560-0000-7000-8000-000000000003'
);

COMMIT;
