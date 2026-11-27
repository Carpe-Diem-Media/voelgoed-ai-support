-- Load only after migration 20261126053035 on a fresh disposable database.
BEGIN;

INSERT INTO staff_users (
  id, identity_issuer, identity_subject, tenant_id, identity_client_id, roles
)
SELECT id::uuid, 'https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0',
       subject, '11111111-1111-4111-8111-111111111111',
       '22222222-2222-4222-8222-222222222222', roles
FROM (VALUES
  ('019ac561-0000-7000-8000-000000000003', 'vgas22-creator', ARRAY['knowledge_editor']),
  ('019ac561-0000-7000-8000-000000000002', 'vgas22-editor', ARRAY['knowledge_editor', 'knowledge_reviewer']),
  ('019ac561-0000-7000-8000-000000000001', 'vgas22-submitter', ARRAY['knowledge_editor', 'knowledge_reviewer']),
  ('019ac561-0000-7000-8000-000000000004', 'vgas22-unrelated', ARRAY['knowledge_reviewer'])
) AS staff(id, subject, roles);

INSERT INTO knowledge_collections (id, slug, name, audience, status)
VALUES ('019ac561-0000-7000-8000-000000000010', 'vgas22-rehearsal', 'Synthetic FAQs', 'public', 'active');

INSERT INTO articles (id, article_ref, slug, collection_id, owner_id)
VALUES (
  '019ac561-0000-7000-8000-000000000011', 'VG-KB-contributor-proof', 'contributor-proof',
  '019ac561-0000-7000-8000-000000000010', '019ac561-0000-7000-8000-000000000003'
);

-- The hash is for the version 1 canonical snapshot used by Content.hash/1.
WITH snapshot(content, hash) AS (
  VALUES ('{
    "category": "faq",
    "applicability": {},
    "primary_locale": "en-ZA",
    "localized_content": [{
      "locale": "en-ZA",
      "title": "Synthetic FAQ",
      "approved_answer": "Synthetic answer."
    }],
    "source_references": [{"kind": "document", "ref": "synthetic-vgas22"}],
    "response_mode": "exact",
    "effective_from": "2026-01-01T00:00:00Z"
  }'::jsonb, 'bb9077782a7fa2f54db3b1db1bbfac180d0111994d4ca7769a985bdff27a7e29')
)
INSERT INTO article_revisions (
  id, article_id, created_by_id, revision_number, edit_version, status, content, content_hash, review_hash
)
SELECT id::uuid, '019ac561-0000-7000-8000-000000000011', '019ac561-0000-7000-8000-000000000003',
       revision_number, edit_version, status, content, hash,
       CASE WHEN status = 'in_review' THEN hash END
FROM snapshot CROSS JOIN (VALUES
  ('019ac561-0000-7000-8000-000000000021', 1, 4, 'in_review'),
  ('019ac561-0000-7000-8000-000000000022', 2, 3, 'draft')
) AS revisions(id, revision_number, edit_version, status);

INSERT INTO audit_events (
  id, actor_kind, actor_staff_id, target_kind, article_revision_target_id,
  event, reason_code, operational_after, correlation_id
)
SELECT id::uuid, 'staff', actor::uuid, 'knowledge_revision', target::uuid, event, reason,
       jsonb_build_object('edit_version', edit_version, 'status', status),
       '019ac561-0000-7000-8000-000000000040'
FROM (VALUES
  ('019ac561-0000-7000-8000-000000000031', '019ac561-0000-7000-8000-000000000002',
   '019ac561-0000-7000-8000-000000000021', 'edit_draft', 'local_editor', 2, 'draft'),
  ('019ac561-0000-7000-8000-000000000032', '019ac561-0000-7000-8000-000000000002',
   '019ac561-0000-7000-8000-000000000021', 'edit_draft', 'local_editor', 3, 'draft'),
  ('019ac561-0000-7000-8000-000000000033', '019ac561-0000-7000-8000-000000000001',
   '019ac561-0000-7000-8000-000000000021', 'submit_review', 'local_editor', 4, 'in_review'),
  ('019ac561-0000-7000-8000-000000000034', '019ac561-0000-7000-8000-000000000004',
   '019ac561-0000-7000-8000-000000000022', 'request_changes', 'source_correction', 3, 'draft')
) AS events(id, actor, target, event, reason, edit_version, status);

COMMIT;
