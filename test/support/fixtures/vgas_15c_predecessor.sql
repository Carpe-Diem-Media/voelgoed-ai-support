-- Synthetic rows for a disposable database migrated to the exact PR C base.
BEGIN;

INSERT INTO staff_users (
  identity_issuer, identity_subject, tenant_id, identity_client_id, roles
) VALUES (
  'https://issuer.example.test/v2.0', 'vgas15c-predecessor',
  '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
  ARRAY['admin']
) RETURNING id AS staff_id \gset

INSERT INTO assistants (slug, display_name, audience, disabled_at)
VALUES ('vgas15c-fixture', 'Synthetic predecessor', 'public', '2031-01-01')
RETURNING id AS assistant_id \gset

INSERT INTO assistant_revisions (
  assistant_id, revision_number, workflow_version, template_version, locale, response_policy, created_by_id
) VALUES (:'assistant_id', 1, 'fixture', 'fixture', 'en', 'fixed_reply', :'staff_id')
RETURNING id AS assistant_revision_id \gset

INSERT INTO inbox_bindings (
  assistant_id, installation_ref, external_account_id, external_inbox_id, credential_ref, handoff_team_id
) VALUES (:'assistant_id', 'synthetic', 1, 2, 'synthetic-fixture', 1)
RETURNING id AS binding_id \gset

INSERT INTO support_sessions (
  binding_id, installation_ref, external_account_id, external_inbox_id, conversation_id, contact_id, correlation_id
) VALUES (:'binding_id', 'synthetic', 1, 2, 3, 4, uuidv7())
RETURNING id AS session_id \gset

INSERT INTO support_runs (
  session_id, assistant_revision_id, turn_ref, ownership_epoch, assistant_epoch, binding_epoch, control_epoch,
  deadline_at, batch_cutoff_at, correlation_id, state, decision, finished_at, claim_generation
) VALUES (
  :'session_id', :'assistant_revision_id', uuidv7(), 0, 0, 0, 0,
  '2031-01-02', '2031-01-01', uuidv7(), 'completed', 'fixed_reply', '2031-01-01', 1
) RETURNING id AS completed_id \gset

INSERT INTO support_runs (
  session_id, assistant_revision_id, turn_ref, ownership_epoch, assistant_epoch, binding_epoch, control_epoch,
  deadline_at, batch_cutoff_at, correlation_id
) VALUES (:'session_id', :'assistant_revision_id', uuidv7(), 0, 0, 0, 0, '2031-01-02', '2031-01-01', uuidv7())
RETURNING id AS active_id \gset

INSERT INTO outbound_deliveries (
  session_id, run_id, purpose, visibility, operation_ref, correlation_id, template_version, template_hash,
  ownership_epoch, assistant_epoch, binding_epoch, control_epoch, deadline_at
) VALUES (
  :'session_id', :'completed_id', 'public_reply', 'public', uuidv7(), uuidv7(), 'fixture',
  repeat('f', 64), 0, 0, 0, 0, '2031-01-02'
);

INSERT INTO outbound_deliveries (
  session_id, purpose, visibility, operation_ref, correlation_id, ownership_epoch, assistant_epoch,
  binding_epoch, control_epoch, deadline_at, state, uncertainty_reason, attempt_count, dispatch_authorized_at
) VALUES (
  :'session_id', 'handoff_status', 'operational', uuidv7(), uuidv7(), 0, 0, 0, 0,
  '2031-01-02', 'unknown', 'ambiguous_write', 1, '2031-01-01'
);

INSERT INTO knowledge_collections (slug, name, audience) VALUES ('vgas15c-fixture', 'Synthetic FAQ', 'public')
RETURNING id AS collection_id \gset

INSERT INTO articles (collection_id, article_ref, slug, owner_id)
VALUES (:'collection_id', 'synthetic-faq', 'synthetic-faq', :'staff_id') RETURNING id AS article_id \gset

INSERT INTO article_revisions (
  article_id, revision_number, status, content, content_hash, review_hash, created_by_id, contributor_ids,
  approved_by_id, approved_at, publication_generation, publication_requested_by_id, publication_collection_epoch,
  publication_deadline_at, publication_profile_id, active_index_generation, active_index_profile_id,
  index_epoch, published_at
) VALUES (
  :'article_id', 1, 'published', '{}', repeat('a', 64), repeat('a', 64), :'staff_id', ARRAY[:'staff_id'::uuid],
  :'staff_id', '2031-01-01', 1, :'staff_id', 0, '2031-01-02', 'synthetic-profile',
  1, 'synthetic-profile', 1, '2031-01-01'
) RETURNING id AS revision_id \gset

UPDATE articles SET current_revision_id = :'revision_id' WHERE id = :'article_id';

INSERT INTO article_revisions (
  article_id, revision_number, status, content, content_hash, review_hash, created_by_id, contributor_ids,
  approved_by_id, approved_at
) VALUES (
  :'article_id', 2, 'revoked', '{}', repeat('b', 64), repeat('b', 64), :'staff_id',
  ARRAY[:'staff_id'::uuid], :'staff_id', '2031-01-01'
);

INSERT INTO article_embeddings (revision_id, generation, locale, profile_id, content_hash, deadline_at)
VALUES (:'revision_id', 1, 'en-ZA', 'synthetic-profile', repeat('a', 64), '2031-01-02')
RETURNING id AS article_embedding_id \gset

INSERT INTO inference_runs (
  article_embedding_id, provider, model_id, profile_id, ordinal, deadline_at, state, dispatch_fence,
  dispatched_at, started_at, finished_at, provider_request_id, input_tokens, correlation_id
) VALUES (
  :'article_embedding_id', 'openai', 'text-embedding-3-small', 'synthetic-profile', 1, '2031-01-02',
  'succeeded', uuidv7(), '2031-01-01', '2031-01-01', '2031-01-01', 'req_synthetic', 3, uuidv7()
) RETURNING id AS settled_attempt \gset

INSERT INTO inference_runs (
  support_run_id, assistant_revision_id, claim_generation, purpose, provider, model_id, profile_id,
  ordinal, deadline_at, state, dispatch_fence, dispatched_at, started_at, finished_at, correlation_id
) VALUES (
  :'active_id', :'assistant_revision_id', 1, 'query_embedding', 'openai', 'text-embedding-3-small',
  'synthetic-profile', 1, '2031-01-02', 'unknown', uuidv7(), '2031-01-01', '2031-01-01', '2031-01-01', uuidv7()
) RETURNING id AS held_attempt \gset

INSERT INTO usage_reservations (
  inference_run_id, price_version, rate_nano_usd, token_unit, max_input_tokens, reserved_nano_usd,
  day_window, month_window, state, actual_nano_usd, settled_at
) VALUES
  (:'settled_attempt', 'synthetic', 5, 2, 32768, 81920, '2031-01-01', '2031-01-01', 'settled', 8, '2031-01-01'),
  (:'held_attempt', 'synthetic', 5, 2, 32768, 81920, '2031-01-01', '2031-01-01', 'unknown', NULL, NULL);

INSERT INTO spend_windows (kind, window_start, settled_nano_usd)
VALUES ('day', '2031-01-01', 8), ('month', '2031-01-01', 8);

INSERT INTO usage_ledger_entries (
  reservation_id, inference_run_id, price_version, rate_nano_usd, token_unit, max_input_tokens, entry_kind,
  entry_key, provider, model_id, input_tokens, amount_nano_usd, reason_code, correlation_id
)
SELECT r.id, i.id, r.price_version, r.rate_nano_usd, r.token_unit, r.max_input_tokens, 'settlement',
  'settlement', i.provider, i.model_id, i.input_tokens, 8, 'trusted_usage', i.correlation_id
FROM usage_reservations r JOIN inference_runs i ON i.id = r.inference_run_id WHERE i.id = :'settled_attempt';

COMMIT;
