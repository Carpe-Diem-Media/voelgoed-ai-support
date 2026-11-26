-- Synthetic history for the disposable B1-to-B2a migration rehearsal.
-- Apply .github/scripts/vgas001_upgrade_fixture.sql first.
\set staff '019ac560-0000-7000-8000-000000000001'
\set collection '019ac560-0000-7000-8000-000000000091'
\set article '019ac560-0000-7000-8000-000000000092'
\set revoked '019ac560-0000-7000-8000-000000000093'
\set audit '019ac560-0000-7000-8000-000000000094'
\set ready_revision '019ac560-0000-7000-8000-000000000095'
\set held_revision '019ac560-0000-7000-8000-000000000096'

BEGIN;

\if :audit_only
INSERT INTO knowledge_collections (id, slug, name, audience, status)
VALUES (:'collection', 'synthetic-b1-upgrade', 'Synthetic upgrade', 'public', 'active');

INSERT INTO articles (id, collection_id, owner_id, article_ref, slug)
VALUES (:'article', :'collection', :'staff', 'VG-KB-SYNTHETIC', 'synthetic');

INSERT INTO article_revisions (
  id, article_id, revision_number, status, content, content_hash, review_hash,
  created_by_id, approved_by_id, approved_at, contributor_ids
) VALUES (
  :'revoked', :'article', 1, 'revoked', '{}', repeat('a', 64), repeat('a', 64),
  :'staff', :'staff', now(), ARRAY[:'staff'::uuid]
);

INSERT INTO audit_events (
  id, actor_kind, actor_staff_id, target_kind, event, reason_code,
  article_revision_target_id, operational_before, operational_after, correlation_id
) VALUES (
  :'audit', 'staff', :'staff', 'knowledge_revision', 'revoke', 'obsolete',
  :'revoked', '{"status":"approved"}', '{"status":"revoked"}', uuidv7()
);
\else
INSERT INTO article_revisions (
  id, article_id, revision_number, status, content, content_hash, review_hash,
  created_by_id, approved_by_id, approved_at, contributor_ids, publication_generation,
  publication_requested_by_id, publication_collection_epoch, publication_deadline_at,
  publication_profile_id, publication_reason
)
SELECT id, :'article', revision_number,
       CASE WHEN revision_number = 2 THEN 'publishing' ELSE 'publish_failed' END,
       '{}', repeat('b', 64), repeat('b', 64),
       :'staff', :'staff', now(), ARRAY[:'staff'::uuid], 1, :'staff', 0,
       now() + interval '1 hour', 'synthetic-b1-profile',
       CASE WHEN revision_number = 3 THEN 'transport_unknown' END
FROM (VALUES (:'ready_revision'::uuid, 2), (:'held_revision'::uuid, 3)) AS rows(id, revision_number);

INSERT INTO article_embeddings (revision_id, locale, profile_id, content_hash, generation, deadline_at)
SELECT r.id, l.locale, r.publication_profile_id, r.content_hash, r.publication_generation, r.publication_deadline_at
FROM article_revisions r
CROSS JOIN (VALUES ('en-ZA'), ('af-ZA')) l(locale)
WHERE r.id IN (:'ready_revision', :'held_revision');

INSERT INTO inference_runs (
  article_embedding_id, provider, model_id, profile_id, ordinal, deadline_at, state,
  dispatch_fence, dispatched_at, started_at, finished_at, provider_request_id, input_tokens,
  reason_code, correlation_id
)
SELECT e.id, 'openai', 'text-embedding-3-small', e.profile_id, 1, e.deadline_at,
       CASE WHEN e.revision_id = :'ready_revision' THEN 'succeeded' ELSE 'unknown' END,
       uuidv7(), now(), now(), now(),
       CASE WHEN e.revision_id = :'ready_revision' THEN e.id::text END,
       CASE WHEN e.revision_id = :'ready_revision' THEN 3 END,
       CASE WHEN e.revision_id = :'held_revision' THEN 'transport_unknown' END,
       uuidv7()
FROM article_embeddings e
WHERE e.revision_id IN (:'ready_revision', :'held_revision');

UPDATE article_embeddings e
SET last_attempt_id = i.id, attempt_count = 1,
    state = CASE WHEN i.state = 'succeeded' THEN 'ready' ELSE 'invalidated' END,
    vector = CASE WHEN i.state = 'succeeded' THEN array_fill(1::real, ARRAY[1536])::vector END
FROM inference_runs i WHERE i.article_embedding_id = e.id;

INSERT INTO spend_windows (kind, window_start, settled_nano_usd)
VALUES ('day', DATE '2026-11-26', 16), ('month', DATE '2026-11-01', 16);

INSERT INTO usage_reservations (
  inference_run_id, price_version, rate_nano_usd, token_unit, max_input_tokens,
  reserved_nano_usd, actual_nano_usd, day_window, month_window, state, settled_at, reason_code
)
SELECT i.id, 'synthetic-b1-price', 5, 2, 32768, 81920,
       CASE WHEN i.state = 'succeeded' THEN 8 END, DATE '2026-11-26', DATE '2026-11-01',
       CASE WHEN i.state = 'succeeded' THEN 'settled' ELSE 'unknown' END,
       CASE WHEN i.state = 'succeeded' THEN now() END,
       CASE WHEN i.state = 'unknown' THEN 'transport_unknown' END
FROM inference_runs i;

INSERT INTO usage_ledger_entries (
  reservation_id, inference_run_id, price_version, rate_nano_usd, token_unit,
  max_input_tokens, entry_kind, entry_key, provider, model_id, input_tokens,
  amount_nano_usd, reason_code, correlation_id
)
SELECT u.id, i.id, u.price_version, u.rate_nano_usd, u.token_unit, u.max_input_tokens,
       'settlement', 'settlement', i.provider, i.model_id, i.input_tokens,
       u.actual_nano_usd, 'trusted_usage', i.correlation_id
FROM usage_reservations u JOIN inference_runs i ON i.id = u.inference_run_id
WHERE u.state = 'settled';
\endif

COMMIT;
