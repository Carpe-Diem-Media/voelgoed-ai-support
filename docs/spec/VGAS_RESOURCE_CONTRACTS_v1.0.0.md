# VGAS — Resource and action contracts

Document: VGAS-RESOURCES | Version: 1.0.0 | Date: 2026-11-25

Status: Implementation baseline. Architectural decisions are locked; physical schema names, framework DSL and exact implementation types are proposed mappings to verify at the relevant slice, not generated code. Authority: VGAS_SPEC_v1.0.0.md and VGAS_IMPLEMENTATION_SPEC_v1.0.0.md (decision IDs below). No additional features authorised. No bulk migration of all resources. If a mapping fails an accepted invariant, record the finding and resolve only that contract.

## 1. Conventions and access

Business IDs: UUIDv7 stored as native PostgreSQL uuid; FK is UUID; required unless marked `?` (nullable). `id` and `inserted_at:utc_datetime_usec` on all persisted business resources, `updated_at:utc_datetime_usec` on mutable records. `text` means bounded string, `enum` means closed typed values, `int` nonnegative integer unless stated; counts/generations use bigint if needed. All time is UTC; effective windows are [start, end). `external_id` is a validated type or lossless canonical representation determined by deployed Chatwoot, never a local PK. `money` is exact integer nano-USD (checked overflow and conservative rounding). Hashes use SHA-256 over a versioned canonical representation. Secrets are references to trusted runtime config, never database cleartext. Embedded records are typed, bounded and validated; avoid arbitrary user-controlled maps. JSON storage is acceptable for typed value objects; DB constraints enforce concurrency-sensitive identities and relationships. Audit includes actor, reason, correlation and target; no raw personal data. Historical references cannot be silently cascade deleted. Retention-driven payload deletion remains possible independently of operational tombstones.

Actors: A=ADMIN, E=KNOWLEDGE_EDITOR, R=KNOWLEDGE_REVIEWER, O=SUPPORT_OPERATOR; W=webhook actor, S=support worker, V=embedding worker, P=publisher worker, Q=reconciliation worker. Operational CLI bootstrap/kill switch uses trusted infrastructure operator, not anonymous HTTP. All system contexts created by trusted application code with installation/account/inbox/session/revision scope as applicable. Staff roles additive, no ADMIN inheritance of editorial roles. Default deny; read actions scoped and field-limited; no blanket bypass. Authorised orchestration can compose narrow actions under applicable system actors, not impersonate staff. AI/customer input is never an actor. Explicitly test direct action calls and revoked access. Framework auth token resources, Oban, budget windows, counters and switch/circuit persistence are supporting infrastructure, not business-resource count.

## 2. Accounts (G005–G006)

### StaffUser — VGAS-001

Fields: `identity_issuer:text`, `identity_subject:text`, `tenant_id:text`, `email:text?`, `display_name:text?`, `roles:array(enum)`, `status:enum`, `last_authenticated_at:utc?`, `disabled_at:utc?`, `retired_at:utc?`. Unique (issuer,subject); validate single configured tenant and issuer/audience/signature/nonce/expiry using verified OIDC strategy. Stable subject binding, never email-based auto-link. Roles allow ADMIN/KNOWLEDGE_EDITOR/KNOWLEDGE_REVIEWER/SUPPORT_OPERATOR. No passwords/public sign-up.

| Action | Actor | Guard, transition and effect |
|---|---|---|
| provision | A or bootstrap CLI | Verified identity allowlist; create INVITED, assign explicit roles, audit |
| authenticate | OIDC callback | Valid identity and local INVITED/ACTIVE; INVITED→ACTIVE, update login timestamp; issue session only if authorised |
| set_roles | A | Active authorised admin; validate role enum; audit; re-evaluate sessions/permissions |
| disable | A | INVITED/ACTIVE→DISABLED; inhibit all privileged access, invalidate or reject existing sessions |
| reactivate | A | DISABLED→ACTIVE after revalidation, no old session revival |
| retire | A | Inhibit access first; DISABLED→RETIRED; retain historical refs |
| read_staff | A; self limited | No unrelated identities or secrets |

RETIRED terminal. OIDC unavailable fails closed; emergency CLI only for operational control, not alternate login. Test wrong tenant, identity substitution, disabled session, role revocation, invite and bootstrap.

## 3. Intelligence (G002, G003, G020–G025)

### Assistant — VGAS-002

Fields: `slug:text`, `display_name:text`, `kind:enum(customer_support initially)`, `audience:enum(public/internal)`, `status:enum`, `active_revision_id:uuid?`, `security_epoch:int`, `disabled_at:utc?`. Unique slug; active revision FK must belong to assistant. Audience ceiling cannot be overridden by grants. No generic assistant execution environment.

Actions: `create` A (initial DISABLED); `activate` A (DISABLED→ACTIVE, valid published config, current credentials and permissions, fresh epoch); `disable` A (ACTIVE→DISABLED, fence unsent/in-flight work); `retire` A (DISABLED→RETIRED after inhibit/drain, terminal); `read_configuration` A/S scoped. In-flight provider/send cannot necessarily be recalled.

### AssistantRevision — VGAS-002, extended in 003–004

Fields: `assistant_id:uuid`, `revision_number:int`, `status:enum`, `provider:text`, `model_id:text`, `workflow_version:text`, `prompt_version:text`, `model_options:embedded`, `locale_policy:embedded`, `response_policy:embedded`, `usage_policy:embedded`, `pricing_ref:text`, `created_by_id:uuid`, `published_by_id:uuid?`, `published_at:utc?`, `config_hash:text?`. Unique (assistant_id,revision_number), one published revision per assistant, atomic compare-current pointer. Model/opts allowlist only; no secret, arbitrary tools or endpoint. Revision number allocated atomically.

Actions: A `create_draft`, `edit_draft` (DRAFT only), `publish` (validate complete supported config, grants, code prompt/workflow and relevant tests; atomically DRAFT→PUBLISHED and old PUBLISHED→SUPERSEDED, update pointer; fence restrictive changes), `discard` DRAFT→DISCARDED (draft abandonment; terminal); read S scoped. Published content immutable, SUPERSEDED/DISCARDED terminal. Rollback is a new reviewed revision. Historical run pins config but current restrictions win. Configuration fields introduced only as used, not placeholders that enable inference before controls.

### AssistantKnowledgeGrant — VGAS-003

Fields: `assistant_revision_id:uuid`, `collection_id:uuid`; unique pair. FK both. A `grant`/`remove_draft_grant` only DRAFT, authorised compatible collection/audience. Freeze on publish. Published grant is immutable relationship, no separate state machine; live restrictions, current grants and collection disable override historic grants. Reads S/V/P only where required by own purpose. Do not give public assistant internal scope. Test accidental internal grant and revocation during run.

### InferenceRun — minimal path before first external indexing in VGAS-003, full 004

Fields: `purpose:enum(query_embedding,article_embedding,interpret,generate,evaluation)`, `support_run_id:uuid?`, `article_revision_id:uuid?`, `assistant_revision_id:uuid?`, `model_id:text`, `provider:text`, `prompt_version:text?`, `profile_id:text?`, `request_id:text?` (trusted provider), `state:enum`, `claim_generation:int`, `deadline_at:utc`, `started_at:utc?`, `finished_at:utc?`, `usage:embedded?`, `reason_code:enum?`, `correlation_id:uuid`. Purpose determines required parent reference; evaluation can use explicit test identity. One attempt id, one reservation, no hidden retries. Usage metadata sourced from transport; ledger authoritative for cost. No raw prompts or reasoning.

| Action | Actor | Guard, transition and effect |
|---|---|---|
| queue | S/V/test harness | Valid purpose, scope, caps; QUEUED |
| claim | S/V | QUEUED→RUNNING with atomic reservation and claim; verify epoch, deadline, profile, finite request bounds before HTTP |
| succeed | S/V | RUNNING→SUCCEEDED on verified transport result/usage, settle reservation; no automatic reply entitlement |
| reject | S/V | RUNNING→REJECTED only definite non-execution, release if no charge proven |
| fail | S/V | RUNNING→FAILED definite failure, settle chargeable usage or hold uncertainty |
| mark_unknown | S/V/Q | RUNNING→UNKNOWN when execution/cost uncertain, retain reservation; no blind retry |
| cancel | S/V | QUEUED→CANCELLED before provider invocation; release only if no charge proven |
| reconcile | Q | UNKNOWN→SUCCEEDED/FAILED/REJECTED on evidence, reconcile money |
| abandon | Q with authorised decision | UNKNOWN→ABANDONED with conservative accounting and audit |

Terminal SUCCEEDED/REJECTED/FAILED/CANCELLED/ABANDONED. Retries new attempt ID, same parent limits, no stale completion delivery. No network within DB transaction. Tests: actual metadata, reasoning tokens, timeouts, retries, duplicate settlements.

## 4. Knowledge (G003, G014–G019)

### KnowledgeCollection — VGAS-003

Fields: `slug:text`, `name:text`, `audience:enum(public/internal)`, `status:enum`, `security_epoch:int`. Unique slug. One owning collection per article. R/A appropriate scoped roles for configuration (collection administration A, editorial actions R/E). `create` A (disabled initially), `enable` A (DISABLED→ACTIVE valid scope), `disable` A (ACTIVE→DISABLED; immediate ineligibility/fence), `retire` A (DISABLED→RETIRED terminal). Changes reducing visibility invalidate unsent work; no in-place privilege widening without authorisation. E/R read permitted collection; S search only eligible public projection.

### Article — VGAS-003

Fields: `article_ref:text`, `collection_id:uuid`, `slug:text`, `owner_id:uuid`, `current_revision_id:uuid?`, `status:enum(ACTIVE,ARCHIVED)`, `archived_at:utc?`. Unique article_ref and (collection,slug); active pointer belongs to article. Reference safely allocated; no gapless guarantee. E `create` ACTIVE in authorised collection; R `archive` ACTIVE→ARCHIVED (revoke active revision, cancel pending publication, suppress delivery); ARCHIVED terminal; no silent collection move. Read current eligible projection S; editor/reviewer read within granted scope. Restore as new article unless amended.

### ArticleRevision — VGAS-003

Fields: `article_id:uuid`, `revision_number:int`, `status:enum`, `category:enum/text allowlist`, `applicability:embedded`, `primary_locale:enum(af-ZA,en-ZA)`, `localized_content:array(embedded)`, `source_references:array(embedded)`, `response_mode:enum(EXACT,GROUNDED,ESCALATE_ONLY)`, `effective_from:utc`, `expires_at:utc?`, `review_due_at:utc?`, `created_by_id:uuid`, `approved_by_id:uuid?`, `approved_at:utc?`, `published_at:utc?`, `content_hash:text?`, `expected_previous_revision_id:uuid?`, `publication_generation:int`, `publication_reason:text?`. Unique (article,revision_number); at most one current PUBLISHED per article; active pointer and state consistent. Expires > effective; time-sensitive offers require expiry. Locale embedded: locale, title, alternative_questions, approved_answer, ordered steps, escalation_conditions. Source embedded: source kind/ref/version/date (where known), separate approved public link. Internal reference never included in model projection; no PII. Applicability typed product/event/service refs. Required approval and hash before publication. Only draft editable; language variants tied to same snapshot. Exact requested approved locale or offer approved locale/handoff; grounded cross-language low-risk only.

| Action | Actor | Guard, transition and effect |
|---|---|---|
| create_draft / edit_draft | E | Active article, DRAFT only; monotonic version, validate input |
| submit_review | E | DRAFT→IN_REVIEW; complete fields, freeze hash snapshot |
| request_changes | R | IN_REVIEW→DRAFT; invalidate review |
| approve | R | IN_REVIEW→APPROVED; verify exact snapshot/source; explicit audited self-approval low risk only; sensitive policy needs independent review or no automatic answer pending operational policy |
| request_publish | R | APPROVED→PUBLISHING; effective time, scope and approval valid; durable indexing job transactionally |
| publish_ready | P | PUBLISHING→PUBLISHED only all approved variant vectors ready, same hash/profile/generation and expected current pointer; atomically supersede prior revision and activate new; cannot grant approval |
| fail_publication | P | PUBLISHING→PUBLISH_FAILED on exhausted safe retries; previous only if independently eligible |
| retry_publication | R | PUBLISH_FAILED→PUBLISHING same approved content and new generation/valid scope, enqueue |
| revoke | R | APPROVED/PUBLISHING/PUBLISH_FAILED/PUBLISHED→REVOKED; immediately remove eligibility, fence stale jobs and clear current pointer if applicable |
| expire | P/scheduled actor | PUBLISHED→EXPIRED at expiry; eligibility clock check independent of job; clear pointer |
| withdraw | E/R | DRAFT/IN_REVIEW→WITHDRAWN authorised abandonment |
| supersede | P | PUBLISHED→SUPERSEDED only atomic successful replacement |

Terminal SUPERSEDED/EXPIRED/REVOKED/WITHDRAWN; restore new revision. Future-dated approval remains APPROVED until effective time (manual publish initially). Never silently fall back to expired or revoked revision. Archive revokes active/pending work.

### Derived embedding data — conditional ArticleEmbedding, not required separate table

Per revision/locale/profile/hash/generation: `vector:vector?`, `state:enum`, `attempt_count:int`, `generation:int`, `profile_id:text`, `content_hash:text`, `error_code:text?`. Profile includes provider, model, dimensions, metric, serialization version. Candidate af/en vector slots on revision or separate resource after feasibility; choose smallest safe shape. V `queue` MISSING→QUEUED (approved only, idempotency), `claim` QUEUED→RUNNING (reservation), `record_ready` RUNNING→READY (dimension, finite values, hash/profile/generation match), `fail` RUNNING→FAILED, `retry` FAILED→QUEUED (bounded), `invalidate` non-invalidated→INVALIDATED (stale or revoked, terminal generation). Reindex new generation; no mixed profile queries; profile cutover only after eval. Embedding READY not publication. Initial 1536 cosine, exact search, one active profile; verify. No calls on draft edits. Every external embedding call budgeted.

### KnowledgeGap — VGAS-005

Fields: `assistant_id:uuid`, `support_run_id:uuid`, `sanitized_question:text?`, `category:text?`, `reason:enum(missing,insufficient,conflicting)`, `occurrence_count:int` (initial 1; grouping optional), `status:enum`, `resolved_article_id:uuid?`, `reviewed_by_id:uuid?`, `resolution_reason:text?`, `reviewed_at:utc?`. Unique originating run (or stable occurrence key); no raw transcripts. S `register` OPEN only for legitimate knowledge gap; E/R/O authorised review OPEN→IN_REVIEW; `defer` IN_REVIEW→OPEN; R `address` IN_REVIEW→ADDRESSED only verified eligible published article; authorised reviewer/operator `dismiss` IN_REVIEW→DISMISSED reason required. ADDRESSED/DISMISSED terminal; recurrence new linked record. No abuse or unsupported account-specific lookups unless genuine policy gap. Apply retention.

### Knowledge actions (not extra persisted resources)

`search_published(scope, bounded_query, profile)` authorises S scope and filters both lexical and vector branches by live grants + pinned revision, active article/current revision/collection, public ceiling, applicability, validity and profile before evidence leaves DB. Return bounded evidence manifest with revision ID, hash, locale, mode, approved projection, links; scores internal. Exact cosine + simple FTS, RRF; optional trigram after tests. `validate_evidence` rechecks current eligibility at decision and send; membership not proof of semantic truth. `export_articles` authorised R/A, no secrets/PII; versioned portable format. Import creates drafts only. No runtime access to raw documents.

## 5. Support (G004, G008–G013)

### InboxBinding — VGAS-002

Fields: `installation_ref:text`, `external_account_id:external_id`, `external_inbox_id:external_id`, `assistant_id:uuid`, `status:enum`, `operating_mode:enum(SHADOW,ASSISTED,AUTOMATIC)`, `credential_ref:text`, `handoff_config:embedded`, `security_epoch:int`. Unique installation/account/inbox. Endpoint/credential server controlled; external IDs verified, one installation/account initially.

A `create_draft` DRAFT; `enable` DRAFT/DISABLED→ENABLED only verified credentials, association, active assistant and routing (automatic also release gate); `disable` ENABLED→DISABLED fence unsent jobs; `rebind` DISABLED only, drain/fence, new epoch and verify before enable; `change_mode` authorised, no automatic before approval, invalidate incompatible outstanding work; `retire` DISABLED→RETIRED terminal. Read W/S/Q only scoped configuration, no raw secret. No unknown binding inference. Shadow/assisted human-routed, not stranded pending.

### SupportSession — VGAS-002

Fields: `binding_id:uuid`, `installation_ref:text`, `external_account_id:external_id`, `external_conversation_id:external_id`, `external_contact_id:external_id?`, `session_generation:int`, `state:enum`, `ownership_epoch:int`, `observed_external_state:embedded?`, `last_verified_at:utc?`, `closed_at:utc?`, `close_reason:text?`. Unique qualified conversation + generation; at most one nonterminal session per qualified conversation. Binding qualified identity consistent. Preserve sticky human control across closed/reopened sessions.

| Action | Actor | Guard, transition and effect |
|---|---|---|
| register | S/W | Verified scope; create UNVERIFIED with monotonic generation |
| activate_bot | S | UNVERIFIED→BOT_ACTIVE after live eligibility, enabled config, no sticky human history; fresh epoch |
| observe_human_takeover | S/Q | UNVERIFIED/BOT_ACTIVE→HUMAN_ACTIVE on confirmed external human control; fence work |
| request_handoff | S/O | BOT_ACTIVE→HANDOFF_PENDING; increment epoch, atomically persist status intent and invalidate work |
| confirm_handoff | Q/S | HANDOFF_PENDING→HUMAN_ACTIVE verified remote state; audit |
| return_to_bot | O | HUMAN_ACTIVE→BOT_ACTIVE only explicit authorisation and fresh verified external eligibility, new epoch; no stale replay |
| close | S/Q/O | Any nonterminal→CLOSED on verified resolution or authorised termination; fence and retain reason |

CLOSED terminal; reopening creates new session, no implied bot permission. Unknown ownership denies automated action. Chatwoot status/assignment is externally authoritative. No processing/rate states on session. Human resolution only V1. Test new/reopened, assignment, pending status alone, failure and concurrent takeover.

### InboundEvent — VGAS-002

Fields: `installation_ref:text`, `external_account_id:external_id`, `external_inbox_id:external_id?`, `external_conversation_id:external_id?`, `external_message_id:external_id?`, `event_type:text`, `stable_event_key:text?`, `session_id:uuid?`, `received_at:utc`, `occurred_at:utc?`, `state:enum`, `reason_code:text?`, `payload_hash:text?`, `minimal_payload:embedded?`, `correlation_id:uuid`. Stable message-event unique qualified identity installation/account/type/message; nonmessage events use documented stable event ID or current-state reconciliation. No timestamp/hash-only universal dedupe. Raw body signature before decoding, trusted instance, replay/body limits; invalid auth not stored as event. W `register` ACCEPTED; `dispatch` ACCEPTED→DISPATCHED plus Oban insert atomically; `ignore`/`quarantine` ACCEPTED→IGNORED/QUARANTINED with reason. All outcomes terminal except ACCEPTED; duplicates acknowledged after durable commit; failed commit returns retryable response. Ignore outgoing/private/system for inference, human outbound and status/assignment reconcile. Job args internal IDs. Test duplicates, invalid HMAC, rollback, out-of-order, missed event and event coverage.

### SupportRun — VGAS-002, decision fields extended 004

Fields: `session_id:uuid`, `assistant_revision_id:uuid`, `parent_run_id:uuid?`, `turn_ref:uuid`, `input_message_refs:array(external_id)`, `context_watermark:embedded?`, `ownership_epoch:int`, `claim_generation:int`, `lease_expires_at:utc?`, `state:enum`, `attempt_count:int`, `deadline_at:utc`, `started_at:utc?`, `finished_at:utc?`, `decision:embedded?`, `evidence_refs:array(embedded)`, `reason_code:text?`, `correlation_id:uuid`. Durable membership/coverage mapping (supporting table if needed) links source messages to at most one active batch, no lost late messages. Atomic claim/fence one active run per qualified conversation including blocked outstanding delivery; no new public turn while UNKNOWN. Parent turn deadline and limits inherited. Ordering from verified history not receipt time or UUID.

S `queue` QUEUED after eligibility, dedupe and admission; `claim` QUEUED→RUNNING atomic lease/epoch, quotas and any required reservation; `complete` RUNNING→COMPLETED validated decision + durable reply/handoff intent (or recorded no-send shadow/assisted result); `schedule_retry` RUNNING→RETRY_WAIT only safe, within parent deadline/budget; `requeue` RETRY_WAIT→QUEUED verified; `supersede` active→SUPERSEDED stale context, successor covers unanswered messages within bound; `cancel` active→CANCELLED permission change, no unsent reply; `fail` active→FAILED exhausted/permanent, durable handoff/recovery or alert. Q recovers expired leases with fencing; never duplicate side effect. Terminal COMPLETED/SUPERSEDED/CANCELLED/FAILED. Completed ≠ sent/resolved. Test batch debounce/hard cap, stale successor, concurrent workers, restart, deadline, wrong epoch.

### OutboundDelivery — VGAS-002

Fields: `session_id:uuid`, `run_id:uuid?`, `intent_kind:enum(public_reply,handoff_notice,handoff_status)`, `purpose:text`, `destination:embedded`, `visibility:enum`, `payload:embedded?`, `payload_hash:text`, `correlation_token:text`, `state:enum`, `ownership_epoch:int`, `claim_generation:int`, `attempt_count:int`, `external_message_id:external_id?`, `last_reconciliation:embedded?`, `started_at:utc?`, `confirmed_at:utc?`, `reason_code:text?`. Stable unique operation key: run + purpose or session/ownership epoch/purpose for operational handoff; one public reply/run, notice separate. Delivery payload immutable before controlled retention purge. Destination derived from trusted binding/session. Only S delivery worker executes. Q reconciles, O authorised manual closure.

| Action | Actor | Guard, transition and effect |
|---|---|---|
| prepare | S | PENDING; atomically with run completion or handoff, valid destination/purpose |
| claim | S | PENDING→SENDING atomic claim; check live status/epoch, binding, assistant, mode, current evidence and deadline; status intent has separate guards |
| confirm_sent | S/Q | SENDING→SENT on verified remote acceptance (message ID for message; confirmed status for handoff) |
| mark_unknown | S/Q | SENDING→UNKNOWN on timeout/crash/ambiguous remote outcome; block automated turn, alert |
| safe_retry | S/Q | SENDING→PENDING only proven no remote effect, bounded retry |
| fail | S/Q | PENDING/SENDING→FAILED definitive failure only |
| cancel | S | PENDING or claimed but proven unsent→CANCELLED invalid eligibility; uncertain sends UNKNOWN instead |
| reconcile | Q | UNKNOWN→SENT on positive qualified correlation; UNKNOWN→FAILED only definitive no-effect evidence and abandonment |
| abandon | O/Q with authorised decision | UNKNOWN→ABANDONED, record remaining uncertainty, no blind resend |

Terminal SENT/FAILED/CANCELLED/ABANDONED. SENT means Chatwoot acceptance/status confirmation, not downstream receipt. No auto HTTP retries on non-idempotent writes. Verify real correlation metadata and read API; matching text alone not proof. If no reliable remote conditional send/idempotency, document residual race; assisted mode unless explicit risk approval. Handoff status explicitly `open` only if still eligible; never reopen resolved or overwrite human assignment. If already human-owned treat as success. No notice after detected human takeover, notice failure never blocks handoff.

## 6. Governance (G026–G031)

### UsageReservation — minimal before first paid application inference (003 or earlier); harden 005

Fields: `inference_run_id:uuid`, `reserved_amount:money`, `price_snapshot:embedded`, `day_window:date`, `month_window:date`, `assistant_id:uuid?`, `state:enum`, `settled_at:utc?`, `reason_code:text?`, `actual_amount:money?`. Unique inference attempt. Atomic ordered locking of budget windows; settled + outstanding, including unresolved cross-window risk, must fit cap. Estimate uncached input and max billable output incl reasoning without double count; require finite provider limits. S/V `reserve` RESERVED before external call; `settle` RESERVED/UNKNOWN→SETTLED trusted actual, append ledger atomically; `release` RESERVED/UNKNOWN→RELEASED only proven no charge; `mark_unknown` RESERVED→UNKNOWN ambiguous; Q `conservatively_settle` UNKNOWN→CONSERVATIVELY_SETTLED reserved ceiling on authorised policy/operator decision. Terminal SETTLED/RELEASED/CONSERVATIVELY_SETTLED. Late correction linked ledger entry, not mutation. No TTL release after possible send. Actual over reservation recorded, alert/block if cap exhausted. Test concurrent overspend, rollover, rounding and duplicate settlement.

### UsageLedger — before paid application inference

Fields: `reservation_id:uuid`, `inference_run_id:uuid`, `entry_kind:enum(settlement,correction)`, `entry_key:text`, `provider:text`, `model_id:text`, `usage:embedded?`, `price_snapshot:embedded`, `amount:money` (signed correction allowed, validated), `reason_code:text`, `correlation_id:uuid`. Unique settlement per reservation, unique correction key. S/V/Q authorised append via accounting action; A read aggregate and Q reconcile details. Immutable fact, no state machine/update/delete outside approved retention. Corrections reference original and retain audit, no double counting.

### AuditEvent — introduced with first consequential actions (001 onward)

Fields: `actor_kind:enum`, `actor_ref:text`, `action:text`, `target_kind:text`, `target_ref:text`, `reason_code:text`, `safe_metadata:embedded?`, `correlation_id:uuid`, `occurred_at:utc`. Append-only, scoped reads by role; no raw prompts, secrets or transcripts. Atomic with consequential transition where practical; use redacted incident metadata for rejected requests. Retention per approved schedule, no generic mutable audit API.

## 7. Typed value objects and supporting persistence

- SupportDecision: schema_version, decision enum answer_exact/answer_grounded/clarify/decline/handoff/greeting, locale af-ZA/en-ZA, reason_code allowlist, evidence_revision_ids bounded array, reply_text nullable. Exact one eligible EXACT variant, render server-side; grounded nonempty GROUNDED evidence and bounded supported reply; clarify one relevant question, max two proposed; decline/greeting/handoff fixed templates. Unknown fields, unsupported enums, links, sensitive claims, false evidence reject. Model cannot choose target, permissions, prices or ownership. Manifest from actual retrieval. G023 governs.
- Rate counters keyed by trusted scope/window, atomic check/increment all applicable counters, duplicate admissions idempotent; message and turn counts separate; cleanup expired windows. Cooldown NORMAL→COOLDOWN on distinct verified misuse threshold, →NORMAL on expiry/manual reset. Recurring, no terminal per counter; audit facts immutable. No inference needed for explicit human request. G026/G028.
- Global control ENABLED→DISABLED with epoch/fence; DISABLED→ENABLED only explicit authorised health/credential/budget checks, no stale replay. Runtime emergency override dominates. No terminal global state; assistant/binding retirement terminal. Circuit CLOSED→OPEN after configured transient failures; OPEN→HALF_OPEN after cooldown with single probe; HALF_OPEN→CLOSED success or OPEN failure. Auth/config failure inhibits affected integration and alerts. No auto-clear administrative disable. G013/G031.
- Transient payload PRESENT→PURGED if no active dependency/hold and retention permits; PRESENT→HELD under approved legal hold; HELD→PRESENT/PURGED on authorised release. PURGED terminal in application. Preserve minimal dedupe/recovery refs; restore reapply revocation/deletion. G029.
- Oban jobs framework-owned, job args internal IDs; job lifecycle does not replace domain state. Explicit database constraints for active session, current revision, claims, delivery and reservations; no open-ended locks across HTTP.

## 8. Transaction and concurrency contracts

| Transaction | Atomic write boundary | Required tests |
|---|---|---|
| T01 ingress | stable event identity + terminal dispatch outcome + Oban insert | duplicate, rollback no lost ack |
| T02 run claim/admission | current local permission + epoch + claim + applicable atomic counters | concurrent claim, quota boundary |
| T03 inference | attempt claim + reservation + budget windows before external request | parallel budget, timeout, hidden retries |
| T04 run completion | decision + evidence refs + unique outbound intent/enqueue; no-send mode explicit | rollback, stale completion |
| T05 handoff | session inhibit/epoch + invalidate unsent work + durable status intent | takeover, failed handoff |
| T06 delivery | atomic claim; separate confirmed/unknown write after HTTP, fence before remote call | ambiguous POST, crash, duplicate |
| T07 publish | ready matching generation/hash + expected current pointer + activation/supersession | parallel publish, revoked/expired/stale worker |
| T08 settlement | reservation transition + unique ledger append + budget window change | duplicate settlement, rollover, late correction |

External HTTP outside transaction. Lock ordering documented per slice. Use current Ash supported APIs and DB constraints; AshStateMachine does not guarantee atomic cross-resource transitions by itself. Verify concurrent races with real PostgreSQL, not only sandbox test doubles. The remote Chatwoot send race is explicitly unresolved; local fencing is not atomic remote control.

## 9. Slice boundaries / open technical mapping

17 business candidates: Accounts 1, Intelligence 4, Knowledge 4, Support 5, Governance 3. Conditional embedding storage plus framework/supporting persistence excluded. No generic CRUD exposure. Field sizes and precision, embedded vs supporting table for message membership/vector slots, UUIDv7 generator, provider API limits, actual Chatwoot ID types/correlation, Entra token/session implementation and exact DSL are resolved before the relevant slice from current documented evidence. Staff/collection role mappings not explicitly differentiated in grilling are proposed least-privilege mappings above; verify with business owners rather than create a generic RBAC engine. Numerical defaults and production permissions remain provisional. No additional authority to deploy.
