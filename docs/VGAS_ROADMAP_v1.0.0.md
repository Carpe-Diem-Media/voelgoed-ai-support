# VGAS — Implementation roadmap

Version 1.0.0 | 2026-11-25 | Architecture accepted; no implementation completed.

Authority: VGAS_IMPLEMENTATION_SPEC_v1.0.0.md, VGAS_RESOURCE_CONTRACTS_v1.0.0.md, frozen decision history, AGENTS.md. All phases planned. Build only resources needed for the current slice; prerequisites that are blocked do not preclude unrelated local work. Acceptance and production activation are separate. No further general grilling.

| Slice | Goal | Scope/exit evidence | Dependencies |
|---|---|---|---|
| VGAS-000 | Feasibility and environment | Pin compatible versions; prove structured inference, usage controls, bilingual pgvector retrieval, signed webhook/queue and fixed reply contract; verify Entra, server, external gaps; evidence PASS/FAIL/BLOCKED; decide GO or narrow fallback | Authorised test keys/inbox/tenant for live tests |
| VGAS-001 | Foundation | One Phoenix/Ash app and Repo, local Compose PostgreSQL+pgvector, CI, Accounts and minimal actor/policy/audit foundation; bootstrap/migration checks, OIDC test and disabled session denial before staff UI | 000 core GO; external auth blocker tracked |
| VGAS-002 | Fixed-reply Chatwoot slice | Assistant/revision minimal configuration and inbox binding, SupportSession/Event/Run/Delivery; signature, dedupe, atomic enqueue, admission bounds, serial batching, ownership/fencing, durable handoff and unknown-send reconciliation; verified staging reply/handoff, crash/concurrency tests | 001; isolated test inbox; no production customer messages |
| VGAS-003 | Knowledge | Collections/grants, articles/revisions, editorial forms and explicit approval/publication, embedding profile, authorised hybrid retrieval; minimum InferenceRun + reservations/ledger before any external embeddings; expiry, revocation, concurrent publish, indexing failure, bilingual tests | 001/002 config contracts; approved FAQs; provider control verified |
| VGAS-004 | AI intelligence | Ash AI/ReqLLM, typed decisions, context, retrieval-first workflow, exact/grounded/clarify/refuse/handoff templates, evidence recheck, all external calls budgeted; deterministic and bounded live tests, shadow only | 002–003 |
| VGAS-005 | Release candidate | Complete quotas/budget windows/cooldown/kill switches, KnowledgeGap, minimal UI, alerts, privacy/retention cleanup, reconciliation and runbooks; concurrency, adversarial, fault, restart and isolated restore tests; confirm limits/privacy/operations | 004; business owners |
| VGAS-006 | Controlled launch | Evaluate shadow and staff-assisted, approved one-inbox low-risk automatic pilot only if G038 gates met; staff coverage, risk sign-off, manual rollback; record measured performance and costs | 005 and explicit release approval |
| VGAS-007 | Deferred | Reassess Hindsight, more channels, live lookups, shared libraries, SharePoint sync, MCP only on evidence and approved scope | MVP outcomes |

## PR slicing (proposed, adapt to actual repository)

000: isolated feasibility report and minimal spikes, no full app or migrations outside spike. 001: foundation/CI, then authentication if needed. 002: ingress+queue; session/run and fixed reply/outbox; handoff/reconciliation. 003: editorial+publication; budgeted embedding/retrieval. 004: model/decision pipeline and validation. 005: complete operations, privacy, evaluation and restore gates. 006: manual pilot change request and evaluation report, not automatic CI deployment. Keep PRs small, use one agent per shared resource/migration; no agent merge recommendation without exact independent review. Controls needed at first use are not deferred even if hardening phase is later.

## Parallel non-code track

1. Retrieve actual Navrae audit and current policy sources, rank recurring intents by measured frequency; no assumptions from old messages. Redact examples. Identify knowledge reviewers and human support queue.
2. Prepare 20–30 high-value FAQ drafts: authoritative source, scope, primary locale, optional approved translation, exact/grounded/escalate-only mode, dates, exceptions and approved link. No raw email ingestion. Verify current policy and approve through application or controlled fixture for staging.
3. Prepare ~20 feasibility cases and ≥100 labelled representative cases before automatic pilot; distinct supported, off-topic, unknown/ambiguous, critical/adversarial subsets. Human semantic evaluation, per-category numerator/denominator, not citation membership alone.
4. Confirm staff coverage, alert destination, proposed rate/budget defaults, retention and provider processing arrangements, approved hosting and recovery policy. No real customer data before privacy gate.

## Release gate checklist (G038)

- Local/CI and versioned authority evidence; real PostgreSQL concurrency, negative auth, expiry/revocation, budget and ambiguous sends; no blind replay after backup restore.
- Real staging bot/Entra/provider tests, privacy review including POPIA and cross-border processing; verify Chatwoot permissions, correlation and ownership race; actual server headroom, backup restore and rollback.
- Shadow: human-routed, no public AI sends or AI status changes. Assisted: staff review and manually send via Chatwoot. Confirm no pending conversation stranded. Automatic: only explicit release approval and one low-risk text inbox, staffed human routing; stay assisted if residual remote ownership/delivery risk not accepted.
- Proposed quality targets: ≥95% supported accuracy, ≥98% scope and unanswerable handling each on labelled subsets, 100% high-risk exact/handoff, zero observed critical financial/policy fabrication, privacy/cross-scope disclosure, duplicate fault-test sends, post-detected-human-takeover sends, unauthorised publication or budget violations. Any critical failure blocks launch. ≥100 cases, report counts; not a guarantee. Proposed p95 <15s, 45s deadline, measure actual usage/cost. No auto-resolution or false deflection metric.
- Global switch, binding detach/routing, fenced outstanding jobs, unknown cost/send reconciliation; restore starts disabled. Rollback documented and rehearsed. Explicit owner approval of quotas, cost, retention, support SLA/idle triage and residual risks.

## Status and non-goals

All slices NOT STARTED; VGAS-000 is next. Exact dependency pins, environment, API guarantees, privacy and budget approvals remain unverified. No hosting purchase, live repo creation, DNS or deployment performed by this pack. Numbers are provisional. Do not create every resource at once, overbuild UI or expand scope. See VGAS-000_FEASIBILITY_BRIEF.md for first assignment.
