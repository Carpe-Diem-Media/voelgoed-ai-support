# Voelgoed AI Support — Frozen cumulative architecture

Document: VGAS-SPEC | Version: 1.0.0 | Date: 2026-11-25

Status: **Architecture frozen with accepted amendments. VGAS-000 CONDITIONAL GO for local MVP development. Live verification pending.**

## Amendment A-011 — VGAS-001 authentication release-candidate exception

Accepted by the owner on 2026-11-25 as a narrow G036 exception.

- VGAS-001 production code may use the audited pins AshAuthentication
  `5.0.0-rc.18`, `ash_authentication_phoenix` `3.0.0-rc.12`, and Assent
  `0.3.2`. The stable AshAuthentication `4.15.1` and
  `ash_authentication_phoenix` `2.17.4` chain can only resolve Assent
  `0.2.x`. The trial resolved `0.2.13`, and the audit reported critical
  advisory `EEF-CVE-2026-117656`.
  [Stable authentication trial](../evidence/VGAS-000_REPORT.md#vgas-2-stable-authentication-trial).
- Staff authentication routes stay off by default.
- Recheck the pins for a patched stable chain before VGAS-9 live testing
  and again before production.
- Rerun the full authentication test suite after any pin change.

This exception applies to the listed VGAS-001 pins. Production
authentication requires separate authorization.

## Amendment A-010 — VGAS-000 CONDITIONAL GO and application-first sequencing

Accepted by the owner on 2026-11-25 for G036 and G037.

- Proceed from VGAS-000 into safe, locally testable MVP development
  under a documented **CONDITIONAL GO** when the essential local
  feasibility gates pass and an independent subagent review confirms
  there is no unresolved core architectural failure. Missing external
  credentials, live provider access, tenant setup and hosting access do
  not by themselves prevent this authorization. Do not claim an
  unconditional GO while required real-provider evidence is outstanding.
- Build the complete, locally testable MVP before requiring real
  external-service configuration. Implement the real integration
  interfaces and adapters now, using verified candidate contracts,
  synthetic fixtures and deterministic transport fakes.
- Keep every live integration verification and operational acceptance
  gate. Live gates move from being prerequisites of local slices to
  being prerequisites of staff use, activation and release. Parent
  phases may stay incomplete while external acceptance is blocked.
- This authorization does not permit live customer operation, production
  deployment, paid inference without separate approval, processing real
  customer data, or production authentication.

The [VGAS-000 exit assessment](../evidence/VGAS-000_REPORT.md#vgas-000-exit-assessment)
records the local evidence and the remaining gates.

## Amendment A-009 — Public repository and reviewed merges

Accepted by the owner on 2026-11-25. The standing execution authority on
Plane VGAS-1 records this decision.

- G034 uses the intentionally public GitHub repository
  `Carpe-Diem-Media/voelgoed-ai-support`. Source and documentation may
  be published when they contain no secrets or confidential data.
- The orchestrator may merge a source PR after an independent subagent
  reviews the exact complete candidate and applicable authorities, all
  required approvals are recorded, all objections and blockers are
  resolved, and all required CI passes on the exact candidate head.
  Follow the merge procedure in `AGENTS.md`. Plane states track delivery
  and confer no merge authority.
- Paid inference, deployment, and processing real customer data each
  require separate authorization.

This amendment supersedes the earlier private-repository proposal and
records the standing PR merge authority for G034.

## Amendment A-008 — Final acceptance and freeze

The user explicitly accepted G032–G038, all Option B, and requested the implementation pack and a lean MVP. The full A-007 final-pass contracts are incorporated, subject to their stated verification gates and provisional operational defaults. G001–G031 and VGAS-P001 remain accepted. The historical Dify-first design is superseded per A-001 and subsequent accepted decisions. No further general grilling is required. Start VGAS-000; amendments only for material findings or deliberate scope changes.

| Decision | Option | Accepted direction |
|---|---|---|
| G001 | B | Single organisation, scoped assistants |
| G002 | C | Versioned configuration and code-controlled execution |
| G003 | C | Shared collections, explicit grants |
| G004 | B | Explicit inbox bindings |
| G005 | B | Entra ID only |
| G006 | B | Fixed roles and scoped actors |
| G007 | B | Five domains |
| G008 | B | Independent AI ownership |
| G009 | C | Durable ingress and transactional enqueue |
| G010 | C | Serialised runs and bounded batching |
| G011 | C | Durable outbound intent and reconciliation |
| G012 | B | Sticky human ownership; human resolution |
| G013 | C | Bounded operation-aware recovery |
| G014 | C | Native knowledge authority |
| G015 | C | Versioned multilingual articles |
| G016 | C | Guarded publication |
| G017 | B | Explicit Ash-native indexing |
| G018 | C | Authorised hybrid retrieval |
| G019 | C | Evidence-bound responses and reviewed gaps |
| G020 | B | Configurable ReqLLM model |
| G021 | B | Ash AI first; narrow ReqLLM fallback |
| G022 | B | Retrieval-first bounded workflow |
| G023 | C | Small typed support decision |
| G024 | B | Bounded Chatwoot context |
| G025 | B | Deterministic validation and regression evaluation |
| G026 | B | Atomic PostgreSQL limits |
| G027 | C | Pre-inference reservations and reconciliation |
| G028 | B | Layered abuse restrictions and cooldowns |
| G029 | B | Data minimisation and bounded retention |
| G030 | B | Minimal LiveView administration |
| G031 | B | Kill switches and monitoring |
| G032 | B | Five domains, 17 candidates progressively |
| G033 | B | UUIDv7 and DB integrity |
| G034 | B | Single repository, Ash-native scoped PRs |
| G035 | B | Measured capacity, isolated Docker |
| G036 | B | Bounded feasibility and narrow fallbacks |
| G037 | B | Functional vertical slices |
| G038 | B | Evidence-based release and staged rollout |

## Authority and interpretation

- This document is the historical decision authority. Latest explicit accepted amendments supersede earlier proposals and conflicting historical text. The clean implementation specification is the active engineering view; the resource contracts and roadmap elaborate it, not override it. If an implementation detail conflicts, stop that affected work and seek a narrow amendment.
- The 17 resources are candidates to implement progressively, not a required table count or initial migration batch. Use ordinary Elixir, native Ash actions and minimal supporting persistence where appropriate.
- Architectural acceptance is not approval of actual pricing, quotas, retention, RPO/RTO, hosting purchase, provider privacy arrangements or production activation. Defaults remain provisional until the relevant gate. No production data, keys, repo or infrastructure changed.
- All versions, dependency APIs, remote delivery correlation and ownership races, Entra configuration and server capacity remain unverified in the actual environment. Do not claim exactly-once delivery, zero hallucinations or compliance.
- Implementation artifacts: VGAS_IMPLEMENTATION_SPEC_v1.0.0.md; VGAS_RESOURCE_CONTRACTS_v1.0.0.md; AGENTS.md; VGAS_ROADMAP_v1.0.0.md; VGAS-000_FEASIBILITY_BRIEF.md. Historical source below preserved exactly; SHA-256 of v0.8.0: 599d4e7b0a1584abff5cb27aef7377916e24a3ea6e0be50556063d80a3c27a67.

---

# Historical baseline — v0.8.0 (verbatim; latest acceptance above governs)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.8.0 |
| Date | 2026-11-25 |
| Status | Working / final grilling pass 07 / not implementation-ready |
| Previous version | 0.7.0 (retained verbatim below) |

## Amendment A-007 — Pass 06 accepted; final pass 07 proposed

### Locked decisions

User explicitly accepted G026 B, G027 C, G028 B, G029 B, G030 B, G031 B. The full detailed A-006 contracts are incorporated as accepted architectural direction, subject to their explicitly provisional numerical values, legal review and implementation verification gates. G001–G025 and VGAS-P001 (minimum viable architecture) remain locked. Acceptance of architectural direction is not activation of proposed budgets, approval of privacy arrangements or permission to deploy. The historical Dify baseline remains superseded as recorded in A-001. No code, repo, DNS, provider configuration or infrastructure has been changed.

| ID | Locked direction |
|---|---|
| G026 | Atomic PostgreSQL application limits |
| G027 | Reserve budget before inference and reconcile |
| G028 | Layered restrictions and temporary cooldowns |
| G029 | Data minimisation and bounded retention |
| G030 | Minimal role-gated Phoenix LiveView administration |
| G031 | Persistent kill switches and basic monitoring |

### Final pass 07 decision register — PROPOSED, not locked

| ID | Alternatives | Recommended |
|---|---|---|
| G032 | A aggressive resource consolidation; B retain five domains and 17 candidates, implement progressively; C expand future platform resources | B |
| G033 | A default integer IDs everywhere; B UUIDv7 for new business resources, qualified external identities and database constraints; C custom/public ID system for all resources | B |
| G034 | A loose prototype then rewrite; B single private repo, Ash-native conventions, scoped PRs and contract-led tests; C umbrella/packages and extensive governance framework | B |
| G035 | A install immediately on existing production host; B measured capacity, isolated Docker deployment, private DB and recoverable backups; C distributed/cloud infrastructure | B |
| G036 | A assume documented APIs work; B bounded feasibility spike and explicit stop/go; C extensive platform benchmark before development | B |
| G037 | A horizontal build all schemas first; B end-to-end vertical slices with safety controls introduced at first use; C build generic AI platform first | B |
| G038 | A deploy after happy path; B staged evidence-based release with assisted fallback and explicit risk sign-off; C require exhaustive testing of future capabilities | B |

### G032 — Resource model and implementation scope

Retain five accepted domains; 17 candidate persisted business resources are the target model, not a required initial migration batch. Each independent identity, relationship, authority or lifecycle justifies persistence; use embedded types/modules for value objects and technical implementation. Framework auth tokens, Oban tables, rate counters, budget window rows, circuit state and singleton global switch may require additional persistence; do not claim 17 is the total DB table count. No tenant, organisation, local customer/transcript, generic role, prompt editor, tool registry, Escalation or separate AbuseEvent resource for MVP. AssistantKnowledgeGrant remains candidate join resource owned by Intelligence (revision + collection unique, frozen with revision; current security restrictions apply immediately). ArticleEmbedding conditional on verified native vectorization; if separate table needed preserve G017 generation contract. KnowledgeGap is not needed for fixed-reply slice but required for agreed MVP. Keep SupportRun distinct from InferenceRun and OutboundDelivery; separate recovery and accounting lifecycles. Handoff as OutboundDelivery intent with explicit kind and operation-specific guards, not separate generic job engine. No duplication of authoritative Chatwoot objects. Fixed code prompts/workflows and evaluation fixtures; bounded validated configuration. Use AshStateMachine where it simplifies explicit lifecycle rules, not for immutable facts/joins. State-machine DSL does not itself prove concurrent guards; use DB-enforced transaction/claim/fence rules. Use Ash actions and policies by default; narrow reviewed persistence helper where native Ash cannot satisfy atomic operations, never general policy bypass.

| Domain | Resource | Essential identity / constraint | Primary action/lifecycle authority |
|---|---|---|---|
| Accounts | StaffUser | issuer + subject unique; trusted tenant validated | provision, activate, disable, retire; G005/G006 |
| Intelligence | Assistant | stable UUID and unique operational slug | activate, disable, retire; G002 |
| Intelligence | AssistantRevision | assistant + revision number unique; active revision belongs to assistant | draft, publish, supersede; G002/G020 |
| Intelligence | AssistantKnowledgeGrant | revision + collection unique | draft-only membership, freeze on publish; live deny overrides G003 |
| Intelligence | InferenceRun | immutable attempt ID; explicit purpose and originating support run or indexing revision | claim, succeed, reject, fail, mark unknown, reconcile, abandon; G021 |
| Knowledge | KnowledgeCollection | unique slug; public/internal audience ceiling | enable, disable, retire; G003 |
| Knowledge | Article | stable UUID, unique article_ref, collection-scoped slug | create, archive, active revision pointer; G015 |
| Knowledge | ArticleRevision | article + revision number unique; content hash and current pointer integrity | review, approve, publish, revoke, expire etc.; G016/G017 |
| Knowledge | KnowledgeGap | unique originating run occurrence or equivalent idempotency key | register, review, address, dismiss; G019; frequency grouping optional, no AI clustering required |
| Support | InboxBinding | installation + account + inbox unique | enable, disable, rebind, retire; G004 |
| Support | SupportSession | qualified conversation + session generation; one nonterminal session per external conversation | ownership and close; G008 |
| Support | InboundEvent | qualified message/event identity for stable IDs; state observations reconcile | register, dispatch, ignore, quarantine; G009 |
| Support | SupportRun | unique run ID, source message refs and lineage, one running claim per qualified conversation | queue, claim, complete, supersede, cancel, fail; G010 |
| Support | OutboundDelivery | stable operation ID; unique run/purpose or session/ownership epoch/purpose for operational handoff | prepare, claim, confirm, reconcile, abandon; G011/G012 |
| Governance | UsageReservation | inference attempt unique; conservative accounting | reserve, settle, release, unknown reconciliation; G027 |
| Governance | UsageLedger | unique settlement and separately keyed correction entries | append immutable accounting facts; G027 |
| Governance | AuditEvent | event UUID; actor, target, reason and correlation | append immutable operational facts; G029/G030 |

All accepted transitions, guards, failure paths and terminal states from A-002 through A-006 remain normative. Final clean implementation spec must include explicit resource attribute types/nullability, relationships, identities, actions and actors, state transitions, transaction scopes and acceptance tests. It must not silently collapse existing security requirements or invent further features. Resolve remaining resource details just in time before the relevant slice, not before writing a feasibility spike. Candidate resource/table consolidation needs explicit evidence that all accepted contracts are preserved; material changes require amendment. No mandatory extra admin dashboards beyond G030.

### G033 — Database and identity conventions

Use UUIDv7 for new application-owned business resource primary keys, stored as PostgreSQL native uuid (16 bytes), using a verified compatible generator and Ash type. Do not rely on UUID order for causality, authorization or revision ordering; deterministic tie-break by binary UUID if needed, monotonic revision number/epoch for domain ordering. Existing Chatwoot IDs are external values, preserve verified type/canonical representation and qualify by trusted installation/account; inbox and conversation binding guard mandatory. Never use unqualified external ID as local PK. Framework-managed Oban/auth tables use supported defaults. No generic prefixed API ID scheme or customer-facing order reference needed; stable human-readable article_ref (e.g. VG-KB-0001), generated safely by DB sequence or unique constraint, no gapless guarantee. UUID is not authorization. UTC timestamps with explicit timestamp precision, local display Africa/Johannesburg; revision validity uses trusted clock, no implicit local date conversion. Use immutable created timestamps, updated timestamps only where mutable, reason and actor references on transitions. Money exact integer nano-USD or exact decimal as G027; choose integer nano-USD initially with overflow/round-up verification. Use typed enum states and DB constraints on critical identities, uniqueness, FK consistency, nonnegative quantities and validity; use partial unique indexes/atomic conditional writes for active session and claims, verify generated migrations. Restrict deletion/cascades for historical audit, no automatic destruction of approval or delivery evidence; retention-driven redaction/deletion explicitly G029. Native Ash identities/actions preferred, DB constraints are final concurrency boundary; test collisions on real Postgres. Do not add indexes speculatively beyond identities/FKs and measured queries; no approximate vector index initially. Standard single Repo with reviewed migration snapshots, explicit transaction boundaries, no network IO inside transaction. DB migrations are reproducible in empty and upgraded test databases. Exact generator/type, DB engine and extension version verified at feasibility, do not assume documentation version compatibility.

### G034 — Repository and development standards

Single private GitHub repo proposed `voelgoed-ai-support`, one Phoenix app (`:voelgoed_ai` provisional) with lib/voelgoed_ai/{accounts,intelligence,knowledge,support,governance}, lib/voelgoed_ai_web/{controllers,live}, priv/repo, priv/prompts, test, evals, docs/{spec,decisions,runbooks}, infra, .github/workflows. Use standard Phoenix/Ash project conventions, no umbrella, reusable package extraction deferred until demonstrated reuse. Keep cumulative spec history and clean active spec; conflict resolution: accepted latest explicit amendments supersede prior requirements, do not silently resolve substantive conflicts, escalate. AGENTS.md instructs inspect authorities and actual pinned deps, clear naming/comments for rationale and invariants, no guessed APIs, no broad CRUD/authorization bypass, no unbounded provider loops, no secrets/PII in repo/logs, no unrelated refactors. Implementation briefs per slice define scope, allowed files, tests, non-goals, evidence and rollback. One agent per overlapping slice, parallel only truly independent work; separate independent PR review. Pin Elixir/OTP, mix.lock, image versions; read official versioned HexDocs and release notes/security advisories. CI includes mix format --check-formatted, compile warnings-as-errors, mix test on real Postgres with pgvector, migration consistency and fresh DB check, dependency/secret scans, Compose validation when applicable; use supported framework tasks after pin verification. Mock external boundaries in ordinary CI; explicit live smoke/evals use separate bounded staging keys and sanitised inputs, no production credentials. No merge recommendation without independent exact diff/head/base, CI/results, tests and all applicable authority references. Track unrelated issues separately; no production deployment from unreviewed PR. Runbooks for deployment, handoff/unknown delivery, secret rotation, backup/restore and rollback. No repo actually created yet.

### G035 — Hosting and deployment

One Phoenix release including Oban workers plus PostgreSQL/pgvector; existing Chatwoot external; no additional Redis, Dify, Hindsight, GPU, orchestration platform or monitoring stack required. Local Docker Compose development; separate staging/test DB, keys and Chatwoot test inbox, then production on suitable VPS. Prefer existing RackZar capacity if measured headroom, network isolation and backup/recovery support it; otherwise dedicated VPS. No install on live WordPress or Chatwoot host before audit and explicit authorization. Planning envelope 2–4 vCPU, 4–8 GiB RAM, 30–50 GB SSD excluding Chatwoot, not benchmarked requirements; inspect CPU/memory peak, disk, Docker, ports, current workloads and existing backup. Prefer maintained supported OS, DB/pgvector and versioned images verified; no forced upgrade of existing host. Use dedicated DB/role and isolated network; shared DB server only when supported isolation, capacity and backup policy proven, never access Chatwoot internal tables. DB not publicly exposed; TLS, secure runtime secrets, trusted endpoint configuration and allowlisted egress as appropriate. Proposed `ai.voelgoed.co.za` admin and `bot.voelgoed.co.za` webhook (one deployment, split paths/hosts if useful); private machine transport preferred where supported, public ingress signed only. Entra OIDC callback must remain functional; no interactive login in webhook path; raw body signature and limits. Non-root container where practical, persistent DB storage, health/readiness, restart policy, no secrets baked into image. Stage deployment migrations separately from service rollout; backward-compatible migration strategy or explicit maintenance/restore plan. Encrypted offsite backups for DB/config needed to reconstruct system; verify restore in isolated environment, preserve revocation/deletion and unknown delivery safeguards (restore cannot replay old sends; start disabled, reconcile with Chatwoot, re-establish dedupe/accounting, authorise new epoch). Proposed RPO 24h and RTO 4h subject to business approval, not actual guarantees; if backup loses recent delivery ledger, no auto replay; human reconcile. Rollback kill switch, detach/route pending Chatwoot conversations, revert compatible release or tested restore; never blind schema downgrade. No hosting, domain, backup provider or cost commitment until audit.

### G036 — Bounded feasibility and version verification

First coding work is a small local disposable spike, target one focused 4–6 engineering-hour session (not delivery promise), with integration blockers separated from framework feasibility. Read current upstream Hex packages/release notes, pin mutually compatible stable Elixir/OTP/Phoenix/Ash/AshPostgres/Ash AI/ReqLLM/Oban/AshOban/AshAuthentication/AshStateMachine as applicable; verify actual lockfile, migrations, advisory status; do not copy unverified version claims from earlier discussion. Prove live Luna exact ID, typed output, trusted usage (including reasoning where charged), supported output bound, timeouts, retry controls, storage options; Ash AI prompt path first, direct ReqLLM only if required. Prove approved FAQ indexing and authorized pgvector search for 20–30 sample FAQs, approximately 20 representative bilingual/ambiguous/off-topic cases, exclusion of revoked/expired/cross-scope records, verify multilingual vector storage and profile. Fixture-based signed webhook/raw body validation, durable enqueue/rollback and fixed reply adapter test; then actual test inbox integration, bot signing/events, token privileges, explicit handover, ownership check and correlation roundtrip on deployed version. Verify Entra test app login, local allowlisted roles, disabled-session rejection, exact claims/tenant; separate external prerequisite from core Ash feasibility. Use synthetic or approved sanitised data, test keys, no production automatic bot. Capture commands, versions, outputs, timings, known limitations and pass/fail/blocked evidence. GO native when core typed inference/accounting and authorized retrieval pass; fix bounded minor issues. If Ash AI wrapper lacks control, use direct ReqLLM narrow fallback; if indexing DSL insufficient, minimal explicit pgvector adapter; if native approach materially delays release after bounded investigation, evaluate Dify behind same Ash boundary, explicit amendment required; do not install both by default. Chatwoot/Entra/host/credential blocker does not by itself disprove Ash; continue independent local slice tests but block affected staging/production gate. No claim of pass without evidence, no open-ended technology comparison.

### G037 — Vertical slices and implementation order

Supersedes historical Dify roadmap. VGAS-000 feasibility and authority verification; VGAS-001 foundation; VGAS-002 fixed-reply Chatwoot slice; VGAS-003 Knowledge; VGAS-004 Intelligence; VGAS-005 production hardening; VGAS-006 controlled launch; VGAS-007 future backlog only. Each slice must implement necessary safety contracts at first use rather than postponing correctness to hardening. No public customer reply until final acceptance. In particular signed ingress, dedupe, ownership/handoff and no blind retries required in fixed-reply test slice; reservation, bounded retries, scope and evidence validation required before any external inference using production budget. Earlier slices may be isolated/local fixture tests; no reliance on eventual future safeguards to justify live unsafe testing.

| Slice | Deliverable | Minimum exit evidence |
|---|---|---|
| VGAS-000 | Feasibility spike, resolve dependency pins, verify environment/prerequisites | Evidence report with pass/fail/blocked; chosen narrow fallbacks or approved amendment |
| VGAS-001 | Phoenix/Ash app, repo, DB/pgvector, CI, Accounts and actor foundation, deployment config | Clean bootstrap/migrate, CI on real DB, negative auth tests; Entra smoke before staff UI use |
| VGAS-002 | Assistant/binding minimum config, session/event/run/delivery lifecycle, durable fixed-reply test bot and handoff | Signed test webhook, transactional enqueue, replay, bounded batching, ownership, unknown send and restart tests; isolated test inbox |
| VGAS-003 | Collections/grants, article/revision lifecycle, approved FAQ import, hybrid retrieval and minimal editorial UI | Bilingual relevant retrieval, publish/expiry/revoke, conflicting scope, embedding failure; budget reservation before any external indexing/query inference |
| VGAS-004 | Bounded support workflow, InferenceRun and typed decisions, approved templates, evidence validation | Exact/grounded/clarify/decline/handoff fixtures, real bounded provider smoke, no unauthorized data, shadow/test inbox only |
| VGAS-005 | Complete quotas, ledger, cooldown, operational controls, KnowledgeGap and remaining minimal UI, alerts, retention, recovery | Real DB concurrency, limit/budget/fence, fault injection, privacy and operator runbook tests; restore/reconcile rehearsal |
| VGAS-006 | Staff-assisted pilot then limited automatic support if gate passes | Approved test report, privacy sign-off, staff routing/coverage, measured pilot and rollback approval |
| VGAS-007 | Deferred extensions only | New evidence-based scope decision |

One narrow PR or small dependent PRs per deliverable; independent knowledge content preparation/approval parallel with development, target first 20–30 approved FAQs, build to actual coverage not arbitrary count. No overlapping agent changes to the same resource contract/migrations. No blanket generation of 17 tables first. Time-box feasibility, then begin coding; do not add another speculative grilling pass. Final accepted v1.0.0 cumulative freeze and clean active specification plus resource/action contracts, AGENTS.md, roadmap, first coding brief are next artifacts, not delivered by this amendment. Where exact version-specific implementation depends on VGAS-000 results, mark verification gate rather than invent API syntax. Treat freeze as architectural baseline, not deployment permission; further material changes via SemVer amendments.

### G038 — Test, acceptance and release gates

Use ExUnit and actual PostgreSQL/pgvector tests for state, FK/unique constraints, atomic claims, quotas, budget and publication races; deterministic HTTP boundary fakes for timeout before/after send, duplicate webhook, provider failure, and negative authorization; Oban testing manual/inline as appropriate (manual for transaction/enqueue assertions, real concurrent DB tests for races). Live integration checks in isolated staging, synthetic or consented/redacted data, no production API key in CI. Versioned evaluation fixtures with question, locale, context, expected eligible evidence and decision, approved reference answer and severity; human assess semantic correctness, not only schema/citation equality. No mandatory LLM judge; test stronger model only if needed, budgeted. Retain earlier 100+ representative anonymised evaluation cases before public automatic pilot, with distinct labelled answerable, off-topic and unanswerable/ambiguous subsets and adversarial/critical cases; report counts/denominators and error types. Proposed acceptance >=95% correct supported answers, >=98% proper scope refusal and unanswerable escalation on their respective sets (clarification counted only where expected), 100% high-risk exact/handoff policy cases and zero observed critical unsupported financial/policy claims, cross-scope/PII disclosures, duplicate external sends in fault tests, replies after detected human takeover, unauthorized publication or budget reservation violations. Treat any critical failure as blocker regardless aggregate score; small datasets not statistical guarantees. Measure p95 target <15s, 45s interactive deadline, actual token/cost/latency and handover recovery; proposed thresholds subject to pilot. No auto-resolution V1, measure answer acceptance/human escalation and confirmed human resolution separately, no false deflection claims.

Release gates: (1) local/CI and dependency/contract verification; (2) real staging integration and security/privacy checks; (3) shadow or replay with human-routed conversations, no public bot sends or status changes by AI; (4) staff-assisted pilot, human sends via Chatwoot; (5) narrow automatic pilot on approved text FAQ scope, one inbox, explicit admin enable, staffed human queue, reviewed data and rollback, monitor actual results; (6) expand only after acceptance and per-channel tests (WhatsApp/email separate). If remote atomic ownership/send or idempotency unsupported, document residual risk, verify conservative fencing and no blind retry, explicitly approve risk before automatic mode; otherwise stay assisted. No claim of exactly-once delivery or zero hallucinations. Automatic pilot may be blocked by privacy/Entra/Chatwoot or operational readiness even if code passes. Release owner approves actual limits, budget, retention, alert routing, idle triage, operational support coverage and residual risks. Provisional numeric settings inherited unchanged from latest amendments; confirm before pilot, not silently locked as production config. Rollback rehearse global disable, inhibit old epochs, handoff pending conversations and reconcile unknown sends/costs. Restore/manual intervention requires audit; no automatic replay. PR merge gate distinct from release gate. Production launch only after explicit human authorization.

### Authority references and outstanding verification

- Ash identities: https://ash.hexdocs.pm/identities.html ; atomic update actions: https://ash.hexdocs.pm/update-actions.html — confirm actual selected version and generated constraints.
- Oban API/transactional enqueue: https://oban.hexdocs.pm/Oban.html ; testing: https://oban.hexdocs.pm/Oban.Testing.html — versioned testing and actual transactions must be demonstrated.
- Earlier A-001–A-006 references remain applicable for Ash AI, ReqLLM, pgvector, Chatwoot, Entra and privacy; reverify pinned releases and deployed contract in VGAS-000. Documentation snapshots differ, no new package version pinned by this amendment.

G032–G038 remain proposed. No live credentials, installed versions, actual VPS capacity, provider retention/pricing, staff process or Chatwoot external guarantees verified in this pass. No application/repository/infrastructure changes. Candidate resource model and release gates are architectural proposals, not implementation evidence. Prior accepted G001–G031 and VGAS-P001 preserved. Upon acceptance, freeze v1.0.0 and produce clean implementation artifacts; proceed with VGAS-000 feasibility, not another broad grilling round.

---

# Historical baseline — v0.7.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.7.0 |
| Date | 2026-11-25 |
| Status | Working / grilling pass 06 / not implementation-ready |
| Previous version | 0.6.0 (retained verbatim below) |

## Amendment A-006 — Pass 05 accepted; Pass 06 proposed

### Locked decisions

User explicitly accepted G020 B, G021 B, G022 B, G023 C, G024 B, G025 B. This supersedes their OPEN status in A-005. Incorporate the actual detailed contracts in A-005 as accepted architectural direction, including their explicit feasibility gates and provisional numerical settings. G001–G019 and VGAS-P001 (minimum viable architecture) remain locked. No application implementation, production deployment or budget activation is authorised by this amendment.

| ID | Locked direction |
|---|---|
| G020 | One configurable validated model through ReqLLM |
| G021 | Ash AI first; narrow direct ReqLLM path where necessary |
| G022 | Retrieval-first, bounded deterministic AI workflow |
| G023 | Small typed support decision, software-owned execution |
| G024 | Bounded Chatwoot context; no persistent AI memory |
| G025 | Deterministic validation and regression evaluation |

### Pass 06 decision register — PROPOSED, not locked

| ID | Alternatives | Recommended |
|---|---|---|
| G026 | A edge/provider limits only; B atomic PostgreSQL admission control; C dedicated Redis limiter | B |
| G027 | A provider alerts only; B charge after inference; C atomic pre-inference reservations and conservative settlement | C |
| G028 | A prompt-only protection; B deterministic layered scope and abuse controls; C separate AI moderation/security platform | B |
| G029 | A duplicate full transcripts; B data minimisation, bounded retention and approved external processing; C no persistent operational records | B |
| G030 | A developer-only operations; B minimal role-gated LiveView administration; C full AI management platform | B |
| G031 | A manual service restart only; B basic persistent kill switches, monitoring and recovery; C separate observability platform | B |

### G026 — Admission and rate limits

PostgreSQL atomic counter updates / guarded transactions, with DB unique keys and bounded lock ordering; no Redis. Keys include trusted installation/account/contact for contact limits (shared across that contact's conversations), qualified inbox, conversation, assistant and global scopes as applicable. External identity not proof of a natural person across channels. Limit authentic distinct incoming AI-eligible messages before batching, not duplicate webhook deliveries; one admitted run per conversation and global worker concurrency. Distinguish incoming messages, AI response/turn allowances, actual inference calls, and provider spend; retries cannot reset counters or parent deadline. Proposed defaults (not activated): 10 messages/min/contact, 60/hour/contact (supersedes prior provisional 5/30 to accommodate WhatsApp bursts), 40 AI responses/day/contact and /conversation, max 3,000 chars/message, bounded batch/context per G024, one active run/conversation, five global concurrent support runs, two total generative calls/turn incl safe retries. Use simple fixed UTC windows initially; document boundary bursts (edge/global limits mitigate); daily response limits measured on admitted response turns, not confirmed delivery, so failure cannot restore abuse allowance. Fixed window counts, server clock only, atomic check/increment of all applicable counters, no partial charges on rejected admission except explicit ingress/abuse accounting; retries of same admission key idempotent. Inbox/global message and pending queue depth/age ceilings required, calibrate with pilot; starting candidate global 100 pending runs and existing 45s interactive deadline; excess legitimate queries safely route to human, never indefinitely queue. Counter storage is implementation data, not mandatory business resources; delete expired windows safely. Explicit human requests and operational handoff must remain possible without inference allowance, using deterministic path. One approved limit notice per cooldown, no notice spam; human route cannot be disabled by AI quotas. Invalid signatures, body too large and unknown binding rejected before inference. Separate edge protection from customer quotas: webhook peer IP is not contact identity. Test concurrent boundary, duplicate, rollover, batching, backlog, new-contact abuse and bypass attempts.

### G027 — Budget and inference accounting

Governance owns UsageReservation and UsageLedger; Intelligence owns InferenceRun. Dedicated provider project/key, one configured model and embedding profile, no separate billing engine. Reserve pessimistic maximum cost BEFORE every actual external inference, including query/article embeddings, classifier, answer, retries and evaluations using production budget (CI/live test keys separately capped). One reservation per immutable inference attempt ID; a turn's total calls remain bounded G022. Use integer nano-USD or exact decimal, never binary floats; immutable versioned price snapshot (provider/model/profile, input/cached/output/reasoning pricing semantics, effective date, currency); estimate worst-case uncached input and enforced maximum output incl billed reasoning when applicable; no double count reasoning included in output. Where provider cannot enforce/estimate finite maximum or actual usage not observable, do not enable automatic execution until verified. Concurrent atomic check of settled plus outstanding reserved cost against daily/monthly global caps and optional assistant caps; lock ordered window rows; no HTTP within transaction. Use UTC calendar day/month initially, display SAST; charge attempt to reservation windows even if outcome arrives after rollover; carry unresolved reservations into new admission risk calculation or conservatively settle at upper bound, never discard on rollover. Proposed $2/day and $20/month global, warnings 50/80/100%, no automatic top-up; values await user/operational approval. Indexing shares global cap; reserve capacity for support or defer indexing manually if needed, no complex quota scheduler. Budget is application-controlled admission ceiling for configured costs, not guaranteed invoice maximum (provider price changes, usage anomalies, external key use, tax/FX). Provider project alerts supplementary. Record actual trusted transport usage and effective price in append-only ledger with unique attempt settlement; discrepancies or actual > reservation -> record actual, inhibit new inference when cap exhausted, alert, reconcile. No model-reported cost/usage. RESERVED -> SETTLED when reliable actual usage available (including chargeable failures); RESERVED -> RELEASED only proven no provider execution/charge; RESERVED -> UNKNOWN on timeout/crash/ambiguous usage; UNKNOWN -> SETTLED or RELEASED with trusted reconciliation evidence; UNKNOWN -> CONSERVATIVELY_SETTLED at reserved ceiling by authorised policy/operator if unrecoverable, no automatic refund. SETTLED/RELEASED/CONSERVATIVELY_SETTLED terminal per reservation; later corrections append linked audited ledger adjustments, never overwrite. Stale claims without provable no-send become UNKNOWN, not released by TTL. Exact reconciliation against provider billing may be aggregate rather than per request, report uncertainty. Tests: parallel overspend, retries, unknown costs, duplicate settlements, rounding, rollover and price changes, kill switch. Human handoff unaffected by exhausted AI budgets.

### G028 — Scope, prompt injection and abuse

V1 no tools, arbitrary URLs, web search, attachments, code execution, external data actions or user-controlled model/system settings. Treat customer messages, past replies and retrieved text as untrusted instructions; approved content grants evidence, never execution authority. Code-controlled scope, explicit collection grants, public ceiling, exact/handoff modes for sensitive info, typed decision validation, approved links only, bounded tokens and context; never include secrets/private staff notes. No-match is not proof of abuse; legitimate ambiguity/missing info -> clarify/handoff; model classification alone not a permanent ban. Fixed Afrikaans/English scope refusal for off-topic; known trivial greetings/human requests deterministic, no inference where safely possible; no repeated off-topic conversation. Proposed three distinct clear off-topic/injection misuse outcomes per contact in rolling hour -> 15min AI-only cooldown, rate limit cooldown notices once per window; ambiguous/legitimate queries not strikes. Explicit human request remains possible, spam does not create unbounded staff notifications; route via existing Chatwoot human queue with deduped handoff/notice, no AI auto-block contact or permanent ban in MVP. Abuse counter state NORMAL -> COOLDOWN when threshold exceeded; COOLDOWN -> NORMAL on trusted expiry or authorised manual reset; new cycle as needed, no permanent terminal state for a recurring control; individual abuse events immutable audit facts, expire per retention. Manual Chatwoot spam/contact blocking remains staff-owned. No separate moderation model unless evaluation justifies; safe handling of unsupported sensitive input, no general medical/financial advice, no diagnosis, no revealing prompts or private data. Validate with adversarial fixtures, multilingual injection, mixed requests, false positives and abuse bypass. Never claim prompt-injection elimination.

### G029 — Privacy, retention and provider processing

Chatwoot remains transcript authority; persist only qualified message IDs/watermarks, minimised durable payload where genuinely needed for recovery/delivery, evidence references, decision and reason, trusted usage, staff audit. No raw webhook/prompt/response logs by default, no full transcript duplicate, no attachment fetching, no customer secrets or unnecessary identifiers in prompts or embedding queries; redact/minimise before outbound inference; route account-specific, sensitive or unsupported material to staff; redaction imperfect, verify in tests. No historical email archive ingested without redaction/review. Pseudonymous IDs are still potentially personal data. Proposed retention: transient content necessary for processing/delivery until resolved then purge, target maximum 7 days except unresolved intent/reconciliation or approved legal hold; minimise/redact unresolved content and alert, do not silently destroy required recovery state; operational metadata/audit/knowledge-gap review 90 days default subject to approved schedule, accounting/approval/security records per approved business/legal need, aggregate non-identifying metrics may remain longer. Preserve minimal dedupe tombstones and unresolved references for verified replay/reconciliation horizon; deleting content never grants permission to resend. No raw request logging or unredacted stack traces; redact telemetry, Oban args/errors and exports, restrict role access; no production data in Git/test fixtures. Scheduled Oban cleanup, legal hold exception recorded; retention/deletion lifecycle for transient payload PRESENT -> PURGED when no active dependency and retention/hold allows, or HELD -> PRESENT/PURGED on authorised release; PURGED terminal, cannot recover from application store; backups separately expire and restore must reapply deletion/revocation policy. Document data subject access/correction/deletion process across Chatwoot, Ash, backups and providers; no promise of immediate deletion of immutable backups or provider logs. TLS, private DB, restricted secrets, least privilege, encrypted offsite backups, restore tests, no sensitive data in public diagnostics. OpenAI stateless requests store:false where supported, no hosted memory; this is not Zero Data Retention. Verify actual account/provider retention, processing agreement and cross-border safeguards before real customer data; review POPIA lawful basis/purpose, notices, retention, operator contracts, security and incident notification, cross-border conditions (sections 11, 13–14, 18–22, 72 as applicable) with responsible information officer. No claim compliance or approval yet. AI identity disclosure and human handover in customer interface; no consequential automated decisions/refunds. Incident procedure: inhibit AI, rotate/revoke impacted credentials, preserve minimal required evidence, notify responsible staff and follow statutory process. Proposed retention durations not legal advice or statutory deadlines.

### G030 — Minimal administration and operator responsibilities

Existing Accounts roles G005/G006; Entra only (verify tenant/app registration, role mapping, session revocation), no duplicate credentials, no public signup. Minimal LiveView: knowledge collections/articles/draft editing, approve/publish/revoke and index status; knowledge gaps review; assistant/inbox config and mode with safe defaults; basic usage/cap/status readout and audit of consequential actions; failed/unknown deliveries and pending handoff list with authorised resolution; staff review draft in app, actual manual sending/resolution remains Chatwoot. No new chat UI, dashboard suite, workflow editor, provider key UI or generic RBAC. Configuration and prompt changes reviewed/versioned; no raw prompts/transcripts displayed by default. Authorised ADMIN can disable automation, change validated budgets and bind assistants; knowledge roles own publication; SUPPORT_OPERATOR review and route, no permission to publish or change budgets by default. All actions enforce Ash policy independently of UI; record actor, reason, old/new version or safe metadata, UTC time, target and correlation. Audit append-only, not mutable state machine; security logs minimise PII. Initial operator alert on failed handoff/unknown delivery/circuit outage/budget exhaustion, clear links to existing Chatwoot queue; operator must verify conversation before manual recovery. No blind resend action. Staff capacity/operating hours and ownership escalation runbook verified before pilot. Use simple list/detail pages; no custom analytics/reporting until needed.

### G031 — Kill switches, health and recovery

Persistent global automation enabled/disabled control plus existing assistant and inbox enabled states; environment-level emergency disable overrides all DB flags; safe default disabled until configured. Global switch ENABLED -> DISABLED on authorised admin/incident action, increments epoch or equivalent invalidates queued/in-flight work, prevents new inference and public AI replies; DISABLED -> ENABLED only authorised explicit enable, health/credentials/budget checks and fresh conversation eligibility; do not replay old pending work automatically. Recurring control no terminal state except underlying retired assistant/binding. Check at admission, before each inference, before delivery; unavoidable remote in-flight send/charge race documented, never claim recall. Handoff/reconciliation/cleanup and human support continue even disabled; guard handoff notices separately, operational disable must not strand pending conversations; use manual Chatwoot detach/routing runbook if application unavailable. Circuit per affected provider/integration using G013 bounded policy, DB or simple persistent shared state if multiple workers; no auto enable administrative kill switch on health recovery. Minimal health endpoints: liveness (process), readiness (DB/job access/config; no paid LLM call), internal detailed status; provider outage does not necessarily fail webhook readiness if safe durable handoff available. Public probes disclose no secrets. Use structured logs, Phoenix telemetry/Oban metrics, simple counters and alert destination (existing staff email/Teams/manual operator channel to verify), no new Grafana/Prometheus stack required for MVP. Monitor queue age/depth, stuck ownership, unknown deliveries, failed handoffs, budget/unknown reservations, provider errors, latency, knowledge indexing; initial thresholds align with G010/G013, immediate alert for unknown send/failed handoff/exhausted cap, dedupe alerts, no notification per retry. Test backup/restore, restart with outstanding jobs, global disable mid-inference, stale epoch, DB/provider/Chatwoot outage and manual rollback. No public automatic mode unless verified handover, delivery ambiguity and residual race risk approved. No autonomous reactivation of disabled bot.

### Governance resource ownership and implementation scope

Keep UsageReservation (per attempt), UsageLedger (append-only accounting entries) and AuditEvent (append-only security/operational records). UsagePolicy is validated code/config/assistant revision settings; atomic counter/window rows and circuit state are implementation persistence, not automatically additional Ash domain resources. Staff permissions remain Accounts; Support owns session/run/delivery; Intelligence owns model invocation; Knowledge owns approved content. Budget and quota updates are software actions with explicit authorisation; no external HTTP in DB transactions. Reuse Ash, Oban, Phoenix telemetry and PostgreSQL. Keep MVP-first rule; no separate Redis, policy engine, billing platform, observability stack or security agent. Numerical thresholds and retention are provisional, validate with pilot and responsible staff. Prior locked safety invariants unchanged.

### References / remaining verification

- PostgreSQL row locks and transactions: https://www.postgresql.org/docs/current/explicit-locking.html (verify pinned PostgreSQL version and actual transaction strategy).
- OpenAI data controls: https://developers.openai.com/api/docs/guides/your-data ; Responses API: https://developers.openai.com/api/reference/resources/responses/methods/create (verify actual project settings, provider options, usage/cost visibility and retention terms).
- POPIA statutory text: https://lawlibrary.org.za/akn/za/act/2013/4/eng%402013-11-26 ; official act: https://www.justice.gov.za/legislation/acts/2013-004.pdf (legal/information officer review required; no compliance finding).

G026–G031 are proposed, not locked. No live credentials, server, provider usage, company privacy policy, staff workflow or alert destination inspected; no code or infrastructure changed. Final grilling pass: implementation-ready resource/action/identity contracts, bounded feasibility gate, minimal vertical slices, deployment/CI, acceptance and release gates; no additional speculative architecture work unless material blocker. Preserve all historical records.

---

# Historical baseline — v0.6.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.6.0 |
| Date | 2026-11-25 |
| Status | Working / grilling pass 05 / not implementation-ready |
| Previous version | 0.5.0 (retained verbatim below) |

## Amendment A-005 — Pass 04 accepted; MVP-first mandate; Pass 05 proposed

### Locked decisions

User explicitly accepted G014 C, G015 C, G016 C, G017 B, G018 C, G019 C. Incorporate the detailed A-004 candidate contracts as accepted architectural direction, subject to the explicitly provisional numerical settings, feasibility gates and schema finalisation. G001–G013 remain locked. The user additionally required: “We MUST not overengineer this and make this more complicated than it needs to be. We build a strong base and get to MVP and we can refine later”. This supersedes OPEN status for G014–G019, not the historical text. No code or deployment is authorised by this record alone.

| Decision | Locked direction |
|---|---|
| G001 | Single organisation, scoped assistants |
| G002 | Versioned configuration, code-controlled execution |
| G003 | Shared collections, explicit grants |
| G004 | Explicit qualified inbox bindings |
| G005 | Entra ID only, subject to feasibility |
| G006 | Fixed roles and scoped actors |
| G007 | Five focused domains |
| G008 | Independent AI ownership lifecycle |
| G009 | Durable event identity and transactional enqueue |
| G010 | Serialised runs and bounded batching |
| G011 | Durable delivery intent and reconciliation |
| G012 | Sticky human ownership and human resolution |
| G013 | Bounded operation-aware retries and recovery |
| G014 | Native Ash canonical support knowledge |
| G015 | Versioned articles with approved language variants |
| G016 | Guarded publication and practical small-team approval |
| G017 | Explicit Ash-native background indexing |
| G018 | Authorised hybrid search and relevance checks |
| G019 | Evidence-bound responses and reviewed knowledge gaps |

### VGAS-P001 — Minimum Viable Architecture (accepted project-wide requirement)

Build one operational support assistant first, with a small approved FAQ collection, one test inbox, minimal editorial and operational UI, one model provider and embedding profile, one Phoenix/Ash release plus PostgreSQL/pgvector, Oban, essential controls and repeatable tests. Use Ash-native functionality first; no general-purpose AI platform, visual editor, generic tool framework, separate AI gateway, multiple active agents, automatic provider fallback, autonomous memory or learning, broad document ingestion, sophisticated dashboards, extra service dependencies or generic package extraction without demonstrated need. Existing accepted safety, authority, state-transition, privacy, knowledge publication, durable processing and delivery invariants are not waived. Meet them through the smallest viable implementation, using ordinary Elixir modules and native framework mechanisms wherever sufficient. Candidate resources, retry intervals, ranking settings and UI details are not mandates to implement unnecessary mechanisms; any actual relaxation of a locked contract requires an explicit amendment. Keep planned feasibility tests time-boxed; record unrelated enhancements as deferred backlog, do not block MVP for them. Prefer a small staff-assisted pilot if public automatic sending safety cannot yet be verified. Proposed remaining grilling passes: Intelligence; Governance/privacy; Delivery/implementation and acceptance. No endless legislative expansion.

### Pass 05 decision register — PROPOSED, not locked

| ID | Alternatives | Recommended |
|---|---|---|
| G020 | A hardcoded OpenAI only; B one configurable validated model through ReqLLM; C dynamic routing/fallback | B |
| G021 | A direct ReqLLM everywhere; B Ash AI prompt-backed actions where sufficient, narrow ReqLLM escape hatch; C general agent/tool runtime | B |
| G022 | A mandatory classifier + generator every turn; B bounded retrieval-first deterministic workflow, optional clarification/classification; C autonomous agent | B |
| G023 | A free text; B extensive agent protocol; C small typed decision contract with software-owned execution | C |
| G024 | A latest message only; B bounded Chatwoot context; C persistent model memory | B |
| G025 | A trust structured output; B deterministic validation + versioned evaluation and staff pilot; C mandatory LLM judge for every answer | B |

### G020 — Model configuration and provider portability

One validated generative model per AssistantRevision initially, candidate openai:gpt-6-luna, using ReqLLM (no separate provider gateway). Separate embedding profile as G017. Record provider, exact model ID (resolved version where exposed), prompt/workflow version, bounded input/output, timeout, reasoning effort if supported, provider options from a code-controlled allowlist and pricing snapshot reference. Start with low/none reasoning only after testing actual support and quality; no default temperature assumptions. Secrets in runtime environment/secret store, never in assistant records, source, or model inputs. No arbitrary endpoints, keys, tool definitions or provider options from UI/customer. One provider key/project initially, validate model capabilities and structured output/usage in VGAS-000. New provider or model requires regression evaluation and authorised configuration publication; no silent fallback, automatic routing, or bespoke model registry. Provider unavailable -> safe handoff per G013. Provider metadata and usage taken from runtime response/transport, not generated content. Verify provider storage settings, request budgets and API retries on pinned libraries. No OpenAI hosted threads, vector store, server-side tools or durable provider conversation ID for MVP. Use stateless calls with storage disabled where supported, subject to actual retention terms; not a zero-retention guarantee.

### G021 — Ash AI action strategy

Use Ash AI typed prompt-backed generic actions for pure AI interpretation/generation when exact pinned release provides structured output, usage/metadata, timeout, model configuration, retry visibility and policy controls. Candidate action names interpret_message (optional), propose_reply; application-defined, not library APIs. Use ordinary Elixir orchestration and authorised Ash actions for retrieval, quotas, state and delivery; no LLM inside a DB transaction. Narrow application-owned inference entry point may directly use ReqLLM where native action cannot expose required usage, timeout, strict schema or provider controls. No duplicate provider abstraction framework on top of ReqLLM, no agent loop, no tools/MCP/browser/customer-provided URLs, no generated chat UI. Pin prompt templates in Git with stable version/hash; fixed system instructions separate from untrusted customer history and approved evidence (which is data, never instructions granting authority). Model output is a proposal; no AI-owned resource transitions. Record an InferenceRun for each attempted external inference (including query/article embeddings where applicable; linkage to SupportRun or ArticleRevision, purpose, model/prompt/profile, timing, request ID, usage, outcome, reason and correlation to Governance reservation). QUEUED -> RUNNING on permission, reservation and claim; RUNNING -> SUCCEEDED (valid transport/result, actual usage reconciled), REJECTED (definite non-execution where established), FAILED (definite failure, usage may still be chargeable), UNKNOWN (uncertain request/cost, hold reservation and no automatic retry), QUEUED -> CANCELLED before invocation. UNKNOWN -> SUCCEEDED/FAILED/REJECTED only with reliable evidence, or ABANDONED by authorised reconciliation with conservative accounting. SUCCEEDED/REJECTED/FAILED/CANCELLED/ABANDONED terminal per attempt; new attempt gets new ID, stale completions do not authorize delivery. Inference success does not imply valid support answer or delivery. Avoid raw prompt/response persistence by default, use redacted metadata and limited necessary evidence. Governance pass finalises budget and retention. Verify Ash AI Result usage semantics and library internal retries on exact resolved versions; fail closed if not observable.

### G022 — Retrieval-first bounded orchestration

Deterministic checks for webhook, ownership, limits, explicit human request, known greeting and simple prohibited/unsupported input where unambiguous. For other eligible text, use bounded current-turn/context retrieval query and authorised hybrid retrieval G018. Most requests: one query embedding plus one structured generative call with retrieved evidence; the model proposes answer/clarify/decline/handoff, locale and evidence selection. Exact answers rendered by application, not the model. No separate mandatory classification call; use optional one interpretation/query-rewrite step only when context/ambiguity requires it and within budget. For no/weak evidence do not fabricate: use fixed handoff or clarify if deterministic/obvious, or bounded structured intent discrimination to distinguish plausible support need from unrelated request. A missing hit is not proof of off-topic. Explicit human request always overrides AI; account-specific/financial exceptions hand off, mixed queries never answer restricted part; suspected injection cannot broaden scope. No retrieval or model call for safely deterministic branches. Maximum two generative calls per support turn initially including classification, generation and safe retries; stale successor and all retries still consume parent turn deadline/budget, reconcile with G010/G013 (no extra implicit retry allowance; if exhausted handoff). One normal query embedding; bounded additional retrieval only for explicit rewrite/regrouping and reservation. Article indexing separate. No external reranker, default AI verifier, agent loop or chain-of-agents. Recheck eligibility before delivery. Budget/timeout and stale work controls apply at every external inference boundary.

### G023 — Typed decision contract

Small typed Ash embedded resource/struct with schema_version, decision enum (answer_exact, answer_grounded, clarify, decline, handoff, greeting), locale enum af-ZA/en-ZA (fallback rules code-owned), reason_code enum (e.g. supported, ambiguous, off_topic, human_requested, account_specific, missing_evidence, conflicting_evidence, unsafe, unavailable), evidence_revision_ids (bounded list selected only from application-provided evidence), reply_text nullable. Model may not supply trusted scope, destination, ownership, price, usage, URL authority or approval status. Contract validation rejects unknown fields/enum, missing required fields, invalid sizes and cross-field combinations. Exact: exactly one eligible EXACT revision and approved requested locale, application renders canonical approved text; ignore/reject generated reply text, no combining sensitive policy with generated claims. Grounded: nonempty approved GROUNDed evidence IDs, bounded reply, all substantive claims must be supported; exact/esc-only articles cannot be paraphrased; if conflict or unverifiable sensitive information handoff. Clarify: one relevant bounded follow-up; use approved template if possible; max two clarification turns per unresolved issue initially then handoff, reset only on meaningful resolution/new issue. Decline/greeting/handoff: application-approved fixed templates; no generated substantive answer; evidence optional only for internal routing, never required for greeting. Model decline is not sufficient to block explicit human requests. Internal evidence manifest from actual authorised retrieval includes revision IDs, locale/content hash and response mode; final validation rechecks current collection grants, revision pointer, validity, active config, ownership and URL allowlist. No user-facing internal IDs, private references or secrets. Reason codes logged independently of customer message; operational failures software-generated. Invalid output -> bounded safe retry only if deadline/attempt allowance/budget remain, otherwise handoff. No arbitrary JSON commands or tool calls. Schema conformance does not establish factual correctness.

### G024 — Context and memory boundaries

Chatwoot authoritative for public conversation messages. Fetch only qualified account/inbox/conversation, verified sender roles and ordered public text; exclude staff notes, hidden metadata, unrelated conversations and attachments. Current batched turn separate from prior context; proposed 6 recent prior messages, 4,000 total prior chars, 3,000 chars per incoming message and bounded current batch size/token budget; no silent truncation of current customer question that alters meaning, clarify/handoff oversized/unsupported input. Context window caps configurable and tested; include earlier bot replies as non-authoritative context, never business evidence; staff public messages likewise context only. No persistent model memory, cross-conversation summarisation, provider session state, Hindsight, or profile learning. Sanitise unnecessary identifiers before external inference; keep necessary personal account requests in human support, do not send raw payment/identity documents or attachments. Context failure or ambiguous reference -> clarify or handoff, no invented history. Persist minimal message IDs, watermark and relevant decision/evidence metadata, not duplicated full Chatwoot transcripts. Invalidate stale responses per G010; human takeovers remain sticky. Privacy/retention finalised in Governance pass.

### G025 — Output validation and evaluation

Deterministic validation required for every proposed response: type/enum/size, exact mode render, evidence membership and current eligibility, sensitive category policy, allowed links, prohibited data/secret leakage checks where feasible, ownership and usage. No claim deterministic checks prove semantic entailment, or a second LLM can guarantee truth. For MVP use exact/handoff for high-risk facts and human-reviewed regression set for grounded responses; no mandatory LLM judge per request. Start feasibility with 20 representative bilingual/ambiguous/off-topic cases and 20–30 approved FAQs; grow toward at least 100 representative anonymised cases before public pilot as earlier release gate, including adversarial, cross-scope, expired/revoked, contradictory, language, context, invalid outputs, timeout and provider switch scenarios. Measure on fixed labelled subsets: >=95% correct supported answers, >=98% appropriate refusal and unanswerable escalation, zero observed critical unsupported policy/financial claims, disclosure, duplicate or post-detected-human-takeover messages. Report sample counts and failures, not statistical guarantees; human adjudication of semantic correctness. Test exact responses byte-for-byte approved text where applicable, evidence checks, deterministic negative tests, provider contract mocked in CI and bounded real-provider smoke in controlled test env. Prompt/model/retrieval revisions require rerun before enabling automatic mode. Git fixtures, ExUnit and simple CSV/JSON evaluation report; no evaluation platform. Shadow/staff-assisted then narrowly scoped automatic mode only after safety gates, operational handover/rollback and staffing confirmed. No mandatory automated model judge; add only if real failure data justifies and validate separately.

### Intelligence resource ownership and MVP implementation notes

Retain Assistant, AssistantRevision, AssistantKnowledgeGrant and InferenceRun from G007. Prompt versions/workflow and model allowlist in code; no separate PromptVersion, ModelRegistry, EvaluationCase or provider entities for MVP. Structured decision embedded/typed, no independent persistence lifecycle; SupportRun owns validated business decision. InferenceRun owns provider attempt, Governance owns usage reservation and ledger; do not duplicate accounting authority. Use existing accepted assistant revision states/grant controls. Proposed build order: smoke test ReqLLM/Ash AI structured outputs, embedding, usage and Chatwoot; scaffold; fixed-reply vertical slice; approved knowledge; bounded AI workflow; security/operational tests; staff-assisted pilot. All public send gates remain mandatory before automatic launch. No change to accepted G001–G019 except the scope/priority mandate stated above; new candidate details await acceptance.

### Authority references / verification (2026-11-25)

- Ash AI v1.5.4 docs (prompt-backed typed actions): https://ash-ai.hexdocs.pm/1.5.4/ ; Ash AI result metadata docs (older version, reverify): https://ash-ai.hexdocs.pm/AshAi.Actions.Result.html
- ReqLLM v1.31.0 overview and OpenAI guide: https://req-llm.hexdocs.pm/ ; https://req-llm.hexdocs.pm/openai.html
- ReqLLM usage docs (retrieved v1.28.0): https://req-llm.hexdocs.pm/usage-and-billing.html ; Responses API implementation docs (retrieved v1.30.0): https://req-llm.hexdocs.pm/ReqLLM.Providers.OpenAI.ResponsesAPI.html
- Documentation snapshots differ in version; exact latest compatible release, prompt action metadata/usage, retry behavior, reasoning options and strict structured output not verified live. No code, API calls using user credentials, infrastructure or repository changed. Numerical settings provisional. Next pass G026–G031: rate limits, budgets/usage, abuse, privacy/retention, staff operations, health/kill switch; then implementation and release gates.

# Historical baseline — v0.5.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.5.0 |
| Date | 2026-11-25 |
| Status | Working / grilling pass 04 / not implementation-ready |
| Previous version | 0.4.0 (retained verbatim below) |

## Amendment A-004 — Pass 03 accepted; Pass 04 proposed

### Locked decisions

User explicitly accepted G008 B, G009 C, G010 C, G011 C, G012 B, G013 C without amendments. All detailed candidate contracts in A-003 are incorporated as accepted architectural direction, subject to their explicitly stated provisional numerical settings, schema finalisation and live verification gates. G001–G007 remain locked. This supersedes the OPEN status in A-003, not its historical text. No deployment or implementation is authorised by this record alone.

| Decision | Locked direction |
|---|---|
| G001 | Single organisation, scoped assistants |
| G002 | Versioned configuration and code-controlled execution |
| G003 | Shared collections with explicit grants |
| G004 | Explicit qualified inbox binding |
| G005 | Entra ID only, subject to feasibility |
| G006 | Fixed roles and scoped system actors |
| G007 | Five focused domains |
| G008 | Independent AI ownership lifecycle |
| G009 | Durable event identity and transactional enqueue |
| G010 | Serialised runs, bounded batching and fencing |
| G011 | Durable delivery intent and conservative reconciliation |
| G012 | Sticky human ownership and human resolution |
| G013 | Bounded operation-aware retries and recovery |

### Pass 04 decision register — PROPOSED, not locked

| ID | Alternatives | Recommendation |
|---|---|---|
| G014 | A SharePoint master; B Git files master; C native Ash support knowledge authority | C |
| G015 | A separate unrelated language articles; B single language with runtime translation; C stable article with immutable revisions and approved locale variants | C |
| G016 | A instant edits; B mandatory separate-person approval; C explicit approval and guarded publication with audited small-team self-approval | C |
| G017 | A synchronous auto-vectorize all edits; B explicit approved-revision background indexing, one active embedding profile; C external retrieval service from day one | B |
| G018 | A keyword only; B vector only; C scoped hybrid retrieval with calibrated sufficiency gates | C |
| G019 | A trust model citations/confidence; B exact only; C evidence-bound decisions, exact or grounded responses and reviewed gaps | C |

### G014 — Canonical knowledge authority

Ash Knowledge domain owns canonical approved customer-support articles and publication state. Company source documents remain authoritative for their underlying policies; published articles must accurately represent them. SharePoint, Git, websites, approved documents and anonymised mailbox analysis are inputs/references, not automatically published evidence. Live system-of-record facts in future require authorised tools, not static FAQs. No raw mailbox ingestion, automatic learning, arbitrary web search, or general document pipeline in V1. Native minimal LiveView editorial UI and controlled import/export (versioned JSON/Markdown, stable article IDs and revision metadata, no secrets or customer PII). Restore/reindex independent of embedding vendor. Conflicting authoritative material -> hold/escalate; no AI precedence decision. External updates require new reviewed revision or immediate revoke; manual publication/import initially. Provider interface returns evidence identities, not permission. Hindsight remains deferred.

### G015 — Article and revision model

Candidate resources: KnowledgeCollection (locked G003), Article (stable identity), ArticleRevision (content snapshot and lifecycle), KnowledgeGap. Article fields: id UUID, unique stable article_ref, collection_id, slug scoped to collection, owner_id, nullable current_revision_id, status, UTC timestamps. Collection membership cannot silently change published content scope: archive/replace or guarded migration with permission revalidation. Article states ACTIVE -> ARCHIVED terminal (archive revokes active revision and inhibits retrieval; restore via new article or explicit future amendment). Active article may have no published revision. Revision fields: article_id, monotonic revision_number unique per article, status, category, typed applicability (event/product/service identifiers where applicable), primary_locale, localized_content, source_references, response_mode, effective_from, expires_at, review_due_at, author/reviewer IDs, approval/publication timestamps, content_hash. Composite integrity or transaction invariant ensures current_revision belongs to article. Immutable approved content and policy metadata; changes create new revision. Drafts editable; reviewed snapshot hash protects against edits after approval. Embedded typed locale variants (af-ZA/en-ZA initially) and source refs rather than new independent resources; each variant includes title, alternative questions, approved answer, ordered steps, escalation conditions. Source refs include type, stable reference, source version/date where known and public link separately allowlisted; internal refs never rendered publicly. No customer PII in articles. One canonical primary locale, optional approved translations; grounded cross-language synthesis permitted only if low risk; exact sensitive answers require approved requested locale or offer approved locale/handoff. No runtime translation labelled approved. Applicability structured rather than inferred solely from similarity; ambiguous product/event -> clarify; conflicting scopes -> handoff. Article status is distinct from revision publication state. Use stable identifiers and UTC validity with explicit Africa/Johannesburg interpretation for staff-entered local dates; enforce expires_at > effective_from. Review date advisory unless policy sets hard expiry; time-sensitive offers require expiry. Do not use version SemVer as revision ordering; integer revision is sufficient.

### G016 — Editorial lifecycle and atomic publication

DRAFT -> IN_REVIEW (required source, primary locale, validity and scope validation; freeze review snapshot); IN_REVIEW -> DRAFT (request changes; invalidate prior review); IN_REVIEW -> APPROVED (authorised reviewer confirms exact snapshot and source); APPROVED -> PUBLISHING (authorised publish request, enqueue durable indexing job transactionally); PUBLISHING -> PUBLISH_FAILED (bounded attempts exhausted; previous publication untouched); PUBLISH_FAILED -> PUBLISHING (explicit retry same immutable content, revalidate approval and profile); PUBLISHING -> PUBLISHED (embedding ready, scope/validity current, compare expected current revision and atomic switch pointer; supersede old revision in same transaction); PUBLISHED -> SUPERSEDED (replacement activated) / EXPIRED (validity ended) / REVOKED (authorised withdrawal); approved or pending revisions may be REVOKED to cancel; DRAFT/IN_REVIEW -> WITHDRAWN (authorised abandonment). SUPERSEDED/EXPIRED/REVOKED/WITHDRAWN terminal for revision; rollback creates new reviewed revision. No two eligible current revisions per article. Future-dated revision remains approved until eligible publication time; explicit scheduled publication optional later, manual V1; old revision remains only if still independently valid, no fallback to expired or revoked content. Guard timestamp in retrieval even if expiration job delayed. Review and publish actions distinct, may be performed by same authorised reviewer for low-risk V1 due to small staff; self-approval allowed only explicit reviewer role and audited attestation, proposed independent second reviewer for sensitive financial/legal policy or keep unapproved and handoff. No bot or publisher worker can grant approval. Approval does not imply publication. Disable collection/assistant and revoke/expire article immediately fence unsent delivery under G008/G011; do not wait for index removal. Concurrent publications compare expected active revision, reject stale publish attempts; no stale embedding can activate after cancellation. Publication records actor, timestamps, source/hash, profile and reasons. Terminal revisions never silently edited or deleted; retention/privacy exceptions handled via governed deletion later. Article archive cancels pending publication and revokes active revision; no automatic resurrection.

### G017 — Derived embeddings and explicit indexing

Prefer Ash AI vectorization and AshOban/Oban where verified compatible. Use explicit manual/background strategy for approved publication, not automatic inference on each draft edit. Candidate initial text-embedding-3-small with 1536 dimensions (confirm pinned provider and actual results), cosine distance; evaluate Afrikaans and English, no assumption that provider quality is sufficient. One active embedding profile in V1: provider/model ID, dimensions, metric, canonical serialization version and profile ID/hash. Deterministically serialize approved title, alternative questions, answer and necessary scope per available locale (bounded, no secrets/internal refs/PII); one vector per revision per approved locale initially, no document chunking/OCR. Derived vectors stored on revision as fixed af/en vector slots or separate ArticleEmbedding resource if native vectorization and query constraints justify it; exact schema is feasibility gate. Track revision ID, locale, content hash, profile, embedding state, error/attempt metadata; MISSING -> QUEUED -> RUNNING -> READY / FAILED, retry FAILED -> QUEUED with budget and eligibility; stale/cancelled -> INVALIDATED terminal for that generation; reindex creates new generation. No duplicate provider job for same revision/locale/profile/hash; guard against late stale worker writes, validate dimension and finite vector, never call external provider inside DB transaction. All embedding calls subject to governance budgets; cache only matching profile/hash and authorised scope. READY means verified vector exists; not publication permission. Publishing requires all approved variants indexed (or explicitly approved alternate deterministic retrieval path in future amendment). Provider outage fails closed or retain independently valid old publication, not downgrade silently. Model/profile changes re-embed canonical content in staging or side-by-side derived generation; never mix incompatible vectors; atomic active profile cutover after evaluation, rollback only to valid matching index. No automatic model change or Hindsight dependency. Current Ash AI docs retrieved at mixed versions; exact DSL/action and integration must be verified against selected stable lockfile.

### G018 — Retrieval and relevance

Authorised application-owned Knowledge.search_published action. Resolve trusted assistant revision and current grants, enforce public audience ceiling, enabled collection, active article/current revision, published state, effective_from <= trusted UTC now, expires_at absent or > now, applicable brand/product/event scope and active embedding profile before candidates are provided to model. Historical pin cannot override current grant revocation; deny by default. No cross-collection leakage even in lexical branch. Use PostgreSQL pgvector exact cosine nearest-neighbour initially (no HNSW until measured need), lexical ranking via simple full-text configuration and optionally pg_trgm for names/typos, query includes bounded relevant context and extracted/verified scope; deterministic rank fusion (candidate reciprocal rank fusion k=60 as starting hypothesis), dedupe by revision, deterministic tie-break by UUID ordering; candidate top 10 each branch and final max 4–6 revisions, tune using evals. Do not compare raw vector and lexical scores as probabilities or use a universal score threshold; calibrate separately, require candidate relevance and coverage; lack of sufficient/conflicting evidence -> clarify or handoff, no generic answer. Query embeddings and article embeddings must match profile. Short names and exact identifiers supported; avoid lexical-only silent fallback on embedding failure until separately validated and approved. Bound retrieved text/token size, no arbitrary documents or prompt instructions from sources. Record candidate IDs, scores, profile, selected revision references, retrieval config and decision reason; minimise PII in telemetry. Validate query plan/latency at realistic data volume, Afrikaans/English/mixed/typo/ambiguous/multi-turn retrieval and negative authorization tests. pgvector exact search and hybrid fusion supported by upstream; exact integration with Ash policies requires proof.

### G019 — Evidence contract, answer modes and knowledge gaps

Model only sees selected eligible evidence projection and bounded conversation context; not full database or arbitrary source URLs. Evidence manifest generated by application, containing run ID, article/revision IDs, locale, content hash, retrieval profile, relevant content, response mode, permitted public links and current scope. Model returns structured decision (ANSWER/CLARIFY/DECLINE/HANDOFF), reply if appropriate, evidence IDs from manifest, reason code; actual schema refined Intelligence pass. Application checks schema, nonempty supporting evidence for substantive answers, no fabricated references, scope/locale/response-mode constraints, allowlisted links, current eligibility and content hash before delivery; citation membership alone is not entailment. EXACT selects one approved locale variant and renders verbatim using software; no model modification; conflicting or missing exact variant -> offer approved locale or handoff. GROUNDED limited to low-risk paraphrase/synthesis; assess coverage and contradiction, evaluate empirically; optional bounded independent validation if warranted by risk/evals; no unsupported promises/financial terms or private data. ESCALATE_ONLY never returns substantive policy answer; fixed safe routing. Greetings/refusals/clarification/handoff notices use approved templates where possible; do not require citations for non-factual templates. Recheck at delivery boundary (G011 residual race remains). No reliance on self-reported model confidence. Public sources rendered from stored approved link metadata, internal evidence refs logged privately. KnowledgeGap created for legitimate missing/conflicting/insufficient support knowledge, not spam or account-specific requests with no missing policy; sanitise/minimise text, link run and category, merge by reviewed grouping not model confidence alone. Lifecycle OPEN -> IN_REVIEW -> ADDRESSED (verified eligible published article linked) / DISMISSED (authorised reason); IN_REVIEW -> OPEN (defer); ADDRESSED/DISMISSED terminal per gap, recurring issue creates linked new record; staff may create drafts but never auto-publish. No customer transcript as authoritative content. Reports count occurrences and prioritise high-impact topics. Tests include fabricated evidence, revoked or expired articles, changed scope, stale run, prompt injection inside article, conflict, language variant absent, unsupported claim and gap privacy.

### Authority references and verification notes (2026-11-25)

- https://hexdocs.pm/ash_ai/readme.html and https://hexdocs.pm/ash_ai/dsl-ashai.html — vectorization and manual/background strategies; search snapshots mixed versions; pinned 1.5.6 docs could not be opened directly, verify actual stable dependency source and tests before implementation.
- https://hexdocs.pm/ash_postgres/AshPostgres.Extensions.Vector.html — vector type support.
- https://github.com/pgvector/pgvector — exact search, cosine operators and hybrid retrieval guidance.
- https://developers.openai.com/api/docs/guides/embeddings — embedding models and dimensions.

G014–G019 are proposals. Resource fields, indexing storage shape, numerical ranking settings, self-approval policy and exact dependency configuration await decisions or feasibility tests. No code, repo, production data or infrastructure changed. Next pass: Intelligence (model configuration, inference contracts, deterministic routing, context, response validation and evaluation).

---

# Historical baseline — v0.4.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.4.0 |
| Date | 2026-11-25 |
| Status | Working / grilling pass 03 / not implementation-ready |
| Previous version | 0.3.0 (retained verbatim below) |

## Amendment A-003 — Pass 02 accepted; pass 03 proposed

### Accepted decisions (locked)

The user explicitly accepted G002 C, G003 C, G004 B, G005 B, G006 B, G007 B without amendments. This supersedes their OPEN status in A-002; the candidate contracts in A-002 are incorporated by reference as accepted architectural direction, including their stated verification conditions and unresolved details. G001 remains locked. No implementation or production deployment is authorised by acceptance of these architecture decisions.

| Decision | Locked direction |
|---|---|
| G001 | Single organisation, multiple scoped assistants |
| G002 | Versioned assistant configuration, code-controlled execution; immutable published revisions and explicit grants |
| G003 | Shared knowledge collections with explicit grants and deny-by-default visibility and publication filtering |
| G004 | Explicit qualified Chatwoot inbox-to-assistant binding |
| G005 | Microsoft Entra ID only via AshAuthentication OIDC, subject to feasibility; no local password fallback without amendment |
| G006 | Fixed staff roles and least-privilege scoped system actors |
| G007 | Five focused Ash domains: Accounts, Intelligence, Knowledge, Support, Governance |

The 17 persisted resource candidates in A-002 remain candidates pending implementation-level design; acceptance of the domain map does not freeze every proposed table or attribute. The previous specification remains historical and earlier conflicting Dify-first recommendations remain superseded.

### Pass 03 decision register — PROPOSED, not locked

| ID | Alternatives | Recommendation |
|---|---|---|
| G008 | A Chatwoot status only; B independent local AI permission lifecycle; C mirror all Chatwoot state | B |
| G009 | A synchronous webhook; B Oban uniqueness only; C persisted ingress dedupe plus transactional enqueue | C |
| G010 | A parallel per message; B strict FIFO per message; C serialized processing with bounded message coalescing and stale-work suppression | C |
| G011 | A blindly retry failed POST; B never reconcile; C durable delivery intent and conservative reconciliation | C |
| G012 | A bot auto-resolves and resumes; B sticky human handoff, human-owned resolution; C AI decides ownership | B |
| G013 | A unlimited retry; B no retry; C bounded operation-aware retry, deadline and safe escalation | C |

### G008 — SupportSession ownership and boundaries

Chatwoot is authoritative for external conversation status, messages, identity and assignment. Local SupportSession is authoritative for AI permission only. Qualified conversation key = trusted installation/account/conversation ID, with verified inbox association. At most one nonterminal session per qualified conversation (database constraint). New session generation is monotonic; a closed session never reopens. Persist session ID, binding ID and generation, external conversation identity, state, ownership epoch, observed external status/assignment metadata, last verified timestamp, close reason/timestamp, timestamps and correlation references. No transcript duplication by default. Human ownership remains sticky across reopening unless explicitly returned by authorised staff and external eligibility reverified. New never-human pending conversation can be admitted after verification; unknown history or inconsistent state fails closed. For a previously closed session, new events cannot reactivate old jobs. Verify current conversation, sender, association and status through trusted adapter before inference and before public delivery; pending alone is insufficient. Restrictive updates to assistant, binding, knowledge or global policy fence in-flight work. Local kill switch inhibits automation regardless of external state.

| Transition | Guard / effect |
|---|---|
| UNVERIFIED -> BOT_ACTIVE | Verified enabled binding/assistant, correct inbox, bot-eligible external state and no sticky human ownership; issue new ownership epoch |
| UNVERIFIED -> HUMAN_ACTIVE | Human ownership confirmed; no AI automatic replies |
| BOT_ACTIVE -> HANDOFF_PENDING | Handoff requested; persist durable intent, increment epoch, inhibit delivery and cancel/fence unsent work |
| HANDOFF_PENDING -> HUMAN_ACTIVE | External handoff confirmed; audit completion |
| BOT_ACTIVE -> HUMAN_ACTIVE | Human takeover detected; fence and cancel unsent work |
| HUMAN_ACTIVE -> BOT_ACTIVE | Explicit authorised return, current verified bot eligibility, fresh epoch; no replay of stale jobs |
| Any nonterminal -> CLOSED | External resolution or explicit local termination; fence pending work, preserve audit |

CLOSED terminal per session. HANDOFF_PENDING remains inhibited if external API fails; no automatic return. Unknown ownership is a denial condition, not permission; refresh or escalate. Shadow/assisted evaluation is not permission for automatic public delivery. Rate limiting and processing tracked separately. Actual Chatwoot event/assignment semantics and ownership API races require live verification.

### G009 — InboundEvent and transactional ingress

Phoenix endpoint verifies raw body HMAC, timestamp and replay window against trusted installation credential, constant-time comparison, bounded request/body size and schema validation. Never trust caller-supplied endpoint, actor, account or scope. Exact signature format and retry window depend on pinned Chatwoot version; verify. Invalid auth rejected, minimal security metadata only. Authentic unknown/mismatched scope quarantined or ignored without AI or arbitrary external action. For message events unique key installation/account/event_type/external_message_id; validate inbox/conversation consistency; duplicates do not enqueue twice. Non-message events require event-specific stable identifier if documented, otherwise current-state reconciliation; no universal assumed event ID. Incoming public customer messages trigger inference; outgoing bot messages may reconcile delivery, human public messages inhibit bot, private notes and system events never trigger inference. Status/assignment changes trigger reconciliation, edits/deletes invalidate affected work if supported. Verify event availability through bot/account subscriptions; duplicate subscriptions handled safely. Store minimal IDs, event type, received/occurred timestamp (untrusted for ordering), payload hash if useful, outcome, reason, correlation ID; raw content only if necessary under retention policy. ACCEPTED -> DISPATCHED (event and job inserted in one transaction; no visible half-complete commit), ACCEPTED -> IGNORED or QUARANTINED; latter three terminal ingress outcomes. Duplicate delivery returns successful acknowledgement for already durable receipt. Transaction failure returns appropriate retryable HTTP failure, never 2xx for lost work. Oban uniqueness supplemental, not primary correctness. Jobs contain internal record IDs only. Verify recovery for missed webhook, out-of-order updates, retry signatures, duplicate requests and enqueue rollback.

### G010 — Serialized runs, bounded batching and fencing

Use one active processing run per qualified session/conversation including pending outbound outcome; other conversations can execute concurrently subject to global limits. PostgreSQL transaction/row lock + unique constraint or equivalent atomic claim; use monotonic ownership and claim generation/fencing tokens. Do not hold DB transactions across model or HTTP calls. Lease expiry permits guarded recovery, not blindly duplicating external side effects. Do not require Oban Pro or distributed Redis lock. Coalesce eligible customer text messages arriving close together into one turn: proposed 1–2s debounce, hard 5s maximum from first eligible receipt; configurable, subject to latency/channel tests. Inbound per-message quotas still apply. Durable ordered membership/coverage mapping links each message to at most one active batch, preserves audit and prevents duplicate handling; canonical message ordering from verified Chatwoot history, not webhook arrival or timestamps alone. Use fresh bounded conversation context, never cross-contact data. New messages arriving during inference mark answer stale if materially unaddressed; suppress unsent stale result and create successor run covering still-unanswered messages, with bounded regrouping (proposed max one regeneration per turn, then clarify/handoff) and absolute deadline. Never discard a message solely because it arrived late; carry it forward or route human. No new public turn while earlier delivery UNKNOWN until reconciliation or explicit human ownership. Run pins assistant revision, prompt/workflow/model settings, triggering message IDs, context watermark, ownership epoch, correlation ID; validate current restrictions before delivery. Candidate fields include id, session_id, state, decision, reason, attempt_count, claim_generation, lease_expires_at, context_watermark, started/finished_at, deadline, evidence refs, revision_id. SupportRun state QUEUED -> RUNNING -> COMPLETED (validated decision and durable delivery or handoff intent in same transaction); RUNNING -> RETRY_WAIT -> QUEUED for safe bounded retries; QUEUED/RUNNING/RETRY_WAIT -> SUPERSEDED (stale work carried forward) / CANCELLED (ownership or config invalid) / FAILED (permanent/exhausted, recovery intent or alert). COMPLETED, SUPERSEDED, CANCELLED, FAILED terminal for run. COMPLETED means decision committed, not customer delivery or resolution. Oban job state separate from domain state. Tests: bursts, out-of-order, concurrent workers, lease expiration, restart, stale answers, queue fairness and max age.

### G011 — Durable outbound delivery, conservative ambiguity handling

OutboundDelivery resource owns each external message or handoff status intent, unique by run/intent purpose (one public answer per run; optional handoff notice and status intent separately identified). Fields: id, session_id, run_id (nullable for operational handoff), intent_kind, visibility, destination identity, immutable payload or minimised reference/hash, correlation token, state, attempt count, claim generation, external message ID where applicable, timestamps, reason, last reconciliation result. Create intent atomically with domain decision; only delivery worker has permission to execute. Public AI message requires current valid ownership, binding, assistant, evidence, channel eligibility and unexpired deadline immediately before send. Explicit handoff status intent requires current authorised handoff and fresh external state; avoid reopening resolved conversations or overwriting human routing. Local serialization/fencing reduces races but cannot guarantee atomic ownership check + remote write. Documented Chatwoot Create New Message API does not establish a guaranteed idempotency key or conditional send; test pinned API for durable round-trippable correlation metadata (e.g. content_attributes if actually supported), exact permissions and read-after-write. Do not equate content hash or matching text with proof. No blind retry after ambiguous POST timeout/connection reset/uncertain 5xx or worker crash after sending. Disable automatic HTTP client retries for non-idempotent writes. Reconcile via verified API/webhook correlation and exact qualified identity; if no reliable match, hold UNKNOWN and escalate for human inspection. Explicit operator decision to abandon or create a new reviewed delivery is audited; never mutate history or silently resend. SENT means Chatwoot accepted the message with verified external ID, not channel/customer delivery; downstream statuses tracked as observed facts if available. PENDING -> SENDING after atomic claim and guards; SENDING -> SENT on verified acceptance; SENDING -> UNKNOWN on uncertain result; SENDING -> PENDING only proven no side effect and within retry policy; SENDING/PENDING -> FAILED on definitive failure, CANCELLED before send on invalid eligibility; UNKNOWN -> SENT on positive reconciliation, UNKNOWN -> FAILED only proven no effect and abandonment, UNKNOWN -> ABANDONED on authorised manual close without proof (outcome remains uncertain). SENT/FAILED/CANCELLED/ABANDONED terminal. No automatic launch if ownership race/ambiguity cannot be reduced to accepted risk; staff-assisted fallback. Test timeout after remote commit, worker crash before/after POST, duplicate webhooks, stale lease, human takeover and revoked knowledge at send boundary.

### G012 — Handoff and resolution policy

Explicit human request, personal/account-specific request, insufficient/conflicting knowledge, restricted policy/financial issue, repeated failed clarification, operational failure and budget exhaustion (legitimate requests) trigger handoff, with deterministic policy and no autonomous AI ownership actions. Abuse cooldown itself need not create repeated handoffs; human access remains possible. Handoff: atomically inhibit session, fence/cancel unsent work, create durable handoff status intent; optionally send one approved acknowledgement only if still permitted under separate handoff-notice guard (never after confirmed human takeover; failure does not delay handoff). Verify live state then explicitly set open via Chatwoot API if still eligible, route configured team only if supported and appropriate, avoid overwriting existing human assignment. Confirm external state; if already human-owned treat as success; if resolved stop and do not reopen. Pending failure stays inhibited and alerts staff; reconcile boundedly. Do not claim human has received or responded until verified. Reason codes and brief sanitised context for staff; no private chain-of-thought, raw provider errors or secrets. No promised human response time unless approved. V1 bot does not auto-resolve conversations; customer thanks/confirmation recorded as outcome only; staff resolves in Chatwoot, later auto-resolution policy subject to amendment. Unattended pending conversations need configurable idle routing/monitoring, not indefinite hiding; initial proposed 30 min inactivity -> human triage, validate business hours and staffing; no inference needed. Shadow mode no bot public replies or AI-driven status changes; assisted mode draft in internal UI, staff sends through Chatwoot; test inbox must not strand pending conversations. Automatic mode only enabled approved scope. Human return explicitly authorised and verified, new epoch; no implicit return on reopening. Handoff state represented in session + durable delivery intent, no separate resource unless needed. Channel delivery constraints and assignment semantics require live tests.

### G013 — Operation-aware retry and recovery

Use Oban/AshOban with bounded attempts and deadline; no duplicate custom scheduler. Classify errors: transient safe read or explicitly rejected provider call, permanent validation/auth/config, ambiguous side effect, stale/cancelled. Proposed interactive end-to-end deadline 45s from first accepted message, target p95 <15s, max 2 generation attempts total only when safe and budget reserved, max 3 safe read attempts total, initial short exponential backoff with jitter (1s, 3s as applicable), respect Retry-After only inside deadline. No auto retry ambiguous inference if usage/outcome unknown in V1; retain conservative reservation and escalate; no blind retry ambiguous outbound writes. Handoff/reconciliation operates independently of interactive deadline with bounded operational recovery, proposed 3 attempts over 5 min then operator alert and durable inhibited status; unknown remote side effects reconciled not blindly replayed. Permanent configuration/auth failures trip affected binding/provider circuit, alert, no retry storm. Circuit-breaker policy proposed e.g. 5 consecutive transient failures -> 60s cooldown, one half-open probe, recovery on verified success; operator can disable independently. Keep failure details redacted; record reason codes, attempt number, elapsed time, provider request ID/usage when available. Worker restart scans durable unfinished intents and expired claims; revalidate epoch and current restrictions; uncertain send becomes UNKNOWN. Queue backlog age/depth alarms, no indefinite pending conversations; staff manual recovery and audit. Terminal jobs not rewritten; explicit reprocess creates new linked run, never replays stale customer response without fresh eligibility. Tests: provider outage/429, invalid structured response, DB rollback, timeout, kill switch, retry deadline, exhausted budget, failed handover, lost webhook, restart recovery. Exact limits provisional; Governance pass will define atomic quota/budget semantics and infrastructure pass monitoring/retention.

### Authority references (reviewed 2026-11-25)

- https://chatwoot.help/hc/user-guide/articles/1677497472-how-to-use-agent-bots — Agent Bot pending/open handoff.
- https://chatwoot.help/hc/user-guide/articles/1677693021-how-to-use-webhooks — webhook events and signature contract; installed version unverified.
- https://developers.chatwoot.com/api-reference/messages/create-new-message — message creation contract; no documented conditional ownership write or guaranteed idempotency key established by review.
- https://developers.chatwoot.com/api-reference/messages/get-messages — reconciliation read API; correlation round trip and pagination to test.
- https://developers.chatwoot.com/api-reference/conversations/toggle-status — explicit target status, not blind toggle.
- https://oban.hexdocs.pm/Oban.html — transactional job enqueue.
- https://oban.hexdocs.pm/unique_jobs.html — job uniqueness is supplemental to application invariants.

### Outstanding verification and next pass

G008–G013 are proposed, not accepted. Exact schema, foreign keys, Ash actions and transaction implementation remain to be finalised. Chatwoot installed version, signed event coverage, token permissions, remote correlation, conditional delivery and assignment semantics remain unverified; automatic mode is contingent on pilot and explicit residual-risk acceptance. Provisional debounce, deadlines, attempts and idle routing need user approval and testing. No infrastructure or repository modified. Next pass: knowledge authority, article/revision schema, editorial lifecycle, embedding generation and retrieval/evidence contracts.

---

# Historical baseline — v0.3.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.3.0 |
| Date | 2026-11-25 |
| Status | Working / grilling pass 02 / not implementation-ready |
| Previous version | 0.2.0 (retained verbatim below) |

## Amendment A-002 — G001 accepted; grilling pass 02

### Locked decision VGAS-G001 — Organisation and tenancy

User explicitly accepted Option B: single organisation, multiple scoped assistants. One Voelgoed organisation per deployment; no SaaS tenant onboarding, tenant billing or cross-organisation isolation model in V1. Multiple inboxes may share an assistant; assistants can have separately controlled knowledge permissions and operational configurations. Launch with one public customer-support assistant. Code reuse in other applications does not require shared runtime tenancy. Scope must be enforced by software, not customer or model input. This supersedes the OPEN entry for G001 in A-001. Exact scope representation, configuration ownership and identities remain subject to G002–G007.

### Process amendment

User requested multiple grilling questions per pass. Present related decisions together, independently identify recommendations, and lock only explicit user acceptances. Preserve accepted decisions and prior text with explicit supersession. Increment SemVer as accepted requirements accumulate. No implementation or deployment authorised by this record alone.

### Pass 02 — proposed, NOT locked

| ID | Options | Recommendation |
|---|---|---|
| G002 | A hardcoded assistants; B fully dynamic builder; C persisted versioned configuration + code-controlled workflow and prompts | C |
| G003 | A universal knowledge; B duplicate per assistant; C explicit collection grants | C |
| G004 | A global bot; B per-inbox explicit binding to assistant; C model dynamically chooses assistant | B |
| G005 | A local authentication; B Entra-only; C Entra primary with controlled local break-glass | B, subject to access verification; local fallback only by explicit amendment |
| G006 | A blanket admin/worker bypass; B simple explicit staff roles and scoped service actors; C full custom RBAC | B |
| G007 | A one domain; B five domains (Support, Knowledge, Intelligence, Governance, Accounts); C additional integration/platform domains | B |

#### G002 candidate contract

Assistant stable identity; AssistantRevision immutable after publication; AssistantKnowledgeGrant belongs to revision (Knowledge owns collections, Intelligence owns grants). Configuration selects supported model role, workflow and prompt version, allowed collections, language, response and usage policies. No arbitrary editable execution or tool permissions. Revision lifecycle DRAFT -> PUBLISHED -> SUPERSEDED; publish validates configuration and permissions and atomically activates revision, superseding former revision. Superseded terminal; rollback creates new revision. Assistant ACTIVE <-> DISABLED by authorised operator, either -> RETIRED (terminal, only after disabling and draining/inhibiting outstanding work). Disabled/retired prevents new inference and pending automatic delivery. Runs pin revision but recheck current security restrictions before sending; restrictive changes invalidate stale work. Draft abandonment is a terminal DISCARDED outcome (proposed). No physical deletion of referenced history.

#### G003 candidate contract

KnowledgeCollection owned by Knowledge; each Article belongs to one collection initially. Shared company-wide collections via explicit revision grants, deny by default. Public-facing assistant may never access internal content even with a mistaken grant. Enforce visibility, active collection, active grant, published revision and effective/expiry window before vector/keyword results reach model. Recheck evidence before delivery. Collection ACTIVE <-> DISABLED by authorised actor; DISABLED -> RETIRED (terminal); disable/retire immediately removes eligibility, index cleanup later. Public-support collections only populated in V1. Collection visibility changes that revoke access invalidate affected runs. No unrestricted raw company archive.

#### G004 candidate contract

Explicit InboxBinding in Support, unique by trusted installation/account/inbox identity, points to one assistant, multiple bindings can target same assistant. Chatwoot instance URL and credential reference server-controlled; no user/model-selected endpoints or scope. One installation/account in V1; keep external identifiers qualified. Unknown or disabled bindings fail closed; no inference, monitored routing to human if authorised. Binding DRAFT -> ENABLED after verification of credentials, bot association, routing, assistant and test inbox; ENABLED -> DISABLED; DISABLED -> ENABLED after revalidation; DISABLED -> RETIRED terminal. Rebinding via disable and guarded change/re-enable; cancel stale pending runs; audit all changes. Chatwoot is authority for contact, conversation, messages, team/assignment and external status; internal gate authoritative for AI eligibility. Pending alone insufficient; confirmed human takeover inhibits bot until explicit return; live API checks and residual race need tests. No local customer identity master.

#### G005 candidate contract

Use AshAuthentication OIDC with Microsoft Entra ID (single tenant) if app registration, consent and supported integration verified. StaffUser stores stable issuer/subject identity (and verified tenant context), no email-based auto-linking; local permissions and enabled status are authoritative. No self-registration or automatic admin grant. Invite/provision explicit allowlist; first admin bootstrapped via controlled deployment command. Staff INVITED -> ACTIVE upon verified authorised login; ACTIVE -> DISABLED on revocation; DISABLED -> ACTIVE via authorised reprovision; RETIRED terminal, retain audit references. Disable invalidates sessions or rejects on next privileged request, verify actual session revocation mechanism. No local password fallback by default; if Entra unavailable, fail closed, operational CLI kill switch available to authorised infrastructure operator. Feasibility and actual Microsoft 365 permissions unverified.

#### G006 candidate contract

Staff roles ADMIN, KNOWLEDGE_EDITOR, KNOWLEDGE_REVIEWER, SUPPORT_OPERATOR (fixed role enum/sets initially, no generic role builder). Small team may hold multiple roles; publication requires explicit reviewer action, self-approval policy to settle in knowledge lifecycle pass. Admin manages assistant/binding/security configuration, users and kill switch; editor drafts/submits; reviewer approves/publishes/revokes; operator views scoped operational metadata and performs permitted handoffs, not edits policies or budgets. Staff permissions explicit and server-side; separate least-privilege internal actors for webhook ingress, support worker, embedding worker, reconciliation/publishing jobs; typed actor context established by trusted code, never input/model. No blanket authorize?: false, no universal worker role. Deny by default; test negative paths, field restrictions and direct action invocations. Credentials not stored in assistant revision or exposed in UI.

#### G007 candidate domain ownership

| Domain | Candidate persisted resources / nonpersisted capabilities |
|---|---|
| Accounts | StaffUser; fixed roles as attributes, conditional external identity resource only if auth library requires |
| Intelligence | Assistant, AssistantRevision, AssistantKnowledgeGrant, InferenceRun; prompt versions/workflows/evaluations in Git initially |
| Knowledge | KnowledgeCollection, Article, ArticleRevision, KnowledgeGap; derived embeddings on revision initially |
| Support | InboxBinding, SupportSession, InboundEvent, SupportRun, OutboundDelivery; handoff as durable intent/transition initially |
| Governance | UsageReservation, UsageLedger, AuditEvent; policy config and atomic counters; separate AbuseEvent only if demonstrated |

One Phoenix application and Repo; domain boundaries represent business capabilities, not microservices. Integration HTTP clients, signature checks, Oban workers, ranking, prompt rendering and structured response schemas are modules/types/actions, not automatically persistent resources. Support orchestrates Intelligence/Knowledge/Governance through explicit authorised interfaces; no unrestricted cross-domain CRUD. Governance cross-cutting without owning other domain state. Resource names, fields, relationships, state machines and exact transaction boundaries to be specified in subsequent passes. No separate integration domain in V1.

### Authority references for pass 02

- https://ash-authentication.hexdocs.pm/AshAuthentication.Strategy.Oidc.html — OIDC strategy capability; installed version and Entra settings not verified.
- https://ash.hexdocs.pm/dsl-ash-policy-authorizer.html — resource policies and actor context; reverify pinned version.
- https://chatwoot.help/hc/user-guide/articles/1677497472-how-to-use-agent-bots — pending bot conversations and open handover; deployed API behavior unverified.

### Outstanding verification

No live server, Chatwoot, Entra or repository changes. All G002–G007 proposals remain open. Exact dependency pins, identity provider permissions, credential topology, session revocation, concurrent delivery behavior and technical feasibility require verification. The final detailed implementation specification remains in progress.

---

# Historical baseline — v0.2.0 (verbatim; read amendments above first)

# Voelgoed AI Support — Cumulative Working Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.2.0 |
| Date | 2026-11-25 |
| Status | Working / grilling in progress / not implementation-ready |
| Previous version | 0.1.0 (retained verbatim below) |

## Amendment A-001 — Ash-first direction and grilling baseline

The user has agreed to start the Ash-native design and a grilling session. This records the working architectural direction, not approval of every proposed resource, policy or implementation detail. The Ash-first direction is subject to a bounded feasibility test. No code or infrastructure has been changed.

### Supersession register

| Previous section / decision | Current disposition |
|---|---|
| ADR-002, ADR-003, ADR-004, ADR-010; Dify deployment, workflow and Python gateway | Superseded as the preferred implementation direction by Phoenix, Ash, Ash AI, ReqLLM and PostgreSQL/pgvector; Dify retained only as fallback. Dify-specific contracts below are historical, not active requirements. |
| ADR-005 | Amend: candidate Luna via ReqLLM; verify live model ID, capabilities, usage, retention and limits. |
| ADR-006 | Canonical approved knowledge remains mandatory; native Ash knowledge repository proposed, SharePoint sync deferred pending grilling. |
| ADR-007 | Amend: Oban and PostgreSQL for durable jobs and atomic limits; no new Redis service by default. |
| ADR-001, ADR-008, ADR-009 | Chatwoot CE, narrow scope, no autonomous multi-agent system and staging isolation retained as working requirements. Hindsight optional, not V1 dependency. |
| Sections 3, 5, 6, 9, 10 | Platform-specific topology, Dify API/index and Python repository/roadmap details superseded where inconsistent with this amendment; replacement contracts to be locked during grilling. |
| Sections 1, 4, 7, 8, 11, 12 | Preserve business scope, Chatwoot requirements, lifecycle intent, security, privacy and open issues where technology-neutral; reverify exact API contracts and replace Dify-specific references before implementation. |

### Working target

One Phoenix/Elixir modular monolith; Ash domains/actions/policies; Ash AI prompt-backed typed actions where suitable; ReqLLM provider integration; AshPostgres and pgvector for approved text FAQs; Oban for durable execution; minimal authenticated LiveView administration; Chatwoot CE remains customer channel and conversation authority. No separate Dify, Hindsight, LiteLLM, Redis or GPU in V1 unless a proven requirement warrants an amendment. Use latest mutually compatible stable packages, pin exact versions after feasibility verification.

### Candidate domain/resource map (not locked)

| Domain | Core resource candidates | Authority / boundary |
|---|---|---|
| Support | InboxBinding, SupportSession, InboundEvent, SupportRun, OutboundDelivery | Bot ownership/inhibition, processing and delivery; Chatwoot owns actual contact/conversation/transcript. Handoff can be a session transition with durable delivery intent; separate Escalation resource only if independent lifecycle demands it. |
| Knowledge | Article, ArticleRevision, KnowledgeGap | Approved versioned content and missing knowledge. Embedding initially derived revision data; separate resource only if multiple embedding versions/strategies require it. |
| Intelligence | InferenceRun; typed classifier/generation actions | AI invocation and measured usage. Prompts/model roles initially versioned configuration in Git; not automatically database resources. |
| Governance | UsageReservation, UsageLedger, AuditEvent | Atomic budgets, quotas and auditable security decisions; rate counters may be implementation data. UsagePolicy initially validated configuration. |
| Accounts | StaffUser, conditional on admin authentication design | Staff authorization only; do not duplicate Chatwoot customers. |

Phoenix controllers, HTTP adapters, Oban workers, retrieval ranking and prompt rendering are implementation modules, not automatically Ash resources. Embedded types for structured decisions and evidence are not necessarily persisted tables. No blanket CRUD actions; define business actions with explicit authorization. Each meaningful lifecycle requires states, transitions, guards, side effects, failure paths and terminal states.

### Proposed development slices (pending grilling)

1. VGAS-000: verify dependencies, Luna structured result and trusted usage, embeddings and bilingual retrieval, actual Chatwoot version/signature/token/ownership behavior; inspect host. Time-box and decide Ash vs fallback based on evidence.
2. VGAS-001: reproducible Phoenix/Ash foundation and CI; explicit actor/authorization boundary.
3. VGAS-002: durable Chatwoot vertical slice, fixed response in test inbox, idempotency and human handoff.
4. VGAS-003: approved FAQ lifecycle and eligible retrieval; prepare real anonymised bilingual test fixtures in parallel.
5. VGAS-004: bounded classifier/retrieval/generator/validator workflow; exact answers for sensitive policies; shadow mode only until safeguards verified.
6. VGAS-005: atomic quotas, spending reservations, ownership and delivery races, failure/recovery, privacy and audit tests.
7. VGAS-006: staff-assisted pilot, acceptance and rollback rehearsal, then approved automatic low-risk responses.

### Grilling register

| ID | Question / decision | State |
|---|---|---|
| VGAS-G001 | Application ownership and scope: single Voelgoed organisation with explicit brand/inbox knowledge scopes vs multi-organisation tenant architecture | OPEN — recommendation single organisation, multiple explicit scopes, no SaaS tenancy in V1 |

Future questions will cover identity and authorization, Chatwoot authority, sessions/jobs/delivery, knowledge ownership and lifecycle, retrieval, AI action contracts, quotas and costs, privacy, admin UX, infrastructure and release gates. Lock one decision at a time; append decision records and SemVer increments, preserving prior proposals and amendments. Final detailed specification follows accepted decisions. This baseline is not permission to deploy or merge.

### Reference notes

Ash resources/actions/domains: https://ash.hexdocs.pm/what-is-ash.html ; https://hexdocs.pm/ash
Ash AI prompt actions: https://hexdocs.pm/ash_ai/AshAi.Actions.Prompt.html ; https://hexdocs.pm/ash_ai
AshOban: https://hexdocs.pm/ash_oban/triggers-and-scheduled-actions.html
Retrieved documentation versions vary; exact compatible versions and behavior require verification during VGAS-000.

---

# Historical baseline — v0.1.0 (verbatim; read amendment above first)

# Voelgoed AI Support — Working Architecture & Implementation Specification

| Field | Value |
|---|---|
| Document ID | VGAS-SPEC |
| Version | 0.1.0 |
| Date | 2026-11-25 |
| Status | Proposed / pre-development |
| Owner | Voelgoed Media (proposed) |
| Decision history | Initial draft; no production deployment or acceptance implied |

**Governance:** MUST/MUST NOT denote proposed release requirements, not claims of implementation. Changes to accepted decisions require explicit amendment or supersession and a SemVer increment; preserve previous versions. The user has accepted exploring Dify, not every technical decision below.

## 1. Mission and scope

Reduce repetitive customer-support work using a bilingual, evidence-grounded bot integrated with Chatwoot Community Edition. Keep staff in control, protect customer information, limit cost and avoid model-provider lock-in.

V1: text FAQ support; website test inbox first; Afrikaans and English; human handoff; bounded contextual follow-ups; approved knowledge; signed ingress; queue, rate limits and budgets; audit and metrics; operator kill switch; staging and pilot. WhatsApp and email require channel-specific acceptance tests before activation. Attachments and account-specific queries go to humans. No automatic refunds, order changes, password resets, payment data retrieval, web search, arbitrary tools, self-learning from chats or model-controlled API calls.

## 2. Decisions and authority

| ID | Proposed decision | Rationale |
|---|---|---|
| ADR-001 | Chatwoot CE Agent Bot, no fork or Captain subscription | Native inbox integration and human handoff |
| ADR-002 | Self-host upstream Dify CE, official Compose | Fast deployment and integrated RAG |
| ADR-003 | Dify Workflow (not Chatflow) with explicit inputs and outputs | Gateway owns bounded conversation context and delivery policy; revises earlier Chatflow proposal |
| ADR-004 | FastAPI + Python, typed schemas, HTTP client, PostgreSQL, Redis | Small independently testable adapter; no AI in security decisions |
| ADR-005 | GPT-6 Luna via official OpenAI plugin/Responses where verified | Initial low-cost provider; no model-specific external contract |
| ADR-006 | Canonical approved articles independent of Dify; proposed SharePoint list, controlled import | Staff editing and portability; verify existing permissions/versioning before adoption |
| ADR-007 | Durable PostgreSQL job ledger/queue; Redis atomic limits; no additional broker initially | Reuse supported infrastructure; reliable recovery |
| ADR-008 | No LiteLLM, autonomous agents, additional retrieval platform or Kubernetes in V1 | Reduce dependencies; introduce only on demonstrated need |
| ADR-009 | Separate production and staging application keys, datasets, databases and test inboxes | No production experimentation |
| ADR-010 | Default upstream vector database for first deployment; pgvector optional after verification | Avoid unsupported configuration |

Chatwoot is authoritative for contact, messages, status and human assignment. Gateway owns bot enablement, ownership inhibition, execution jobs, delivery decisions, quotas and audit. Canonical KB owns article content and approved versions. Dify indexes the approved KB and executes AI workflow; model is inference only. GitHub owns code, specs, tests, config templates, DSL exports. No direct reads/writes to Chatwoot or Dify internal database tables. No Chatwoot credentials in Dify.

## 3. Deployment architecture

Customer -> Chatwoot -> signed Agent Bot webhook -> Gateway HTTP receiver -> durable job queue -> Gateway worker -> Dify private API -> approved KB + model provider -> typed result -> Gateway policy check -> Chatwoot API.

Proposed hostnames: `ai.voelgoed.co.za` restricted Dify admin; `bot.voelgoed.co.za` webhook only; existing Chatwoot domain unchanged. If same server/network, use internal gateway address when supported and omit unnecessary public webhook DNS. No public Dify web app or service API; restrict admin through private VPN or Cloudflare Access with MFA; configure callback/plugin requirements before enforcing path restrictions. HTTPS; origin protection; private Docker networks; databases and Redis not host-exposed. Only signed webhook route public when needed; Cloudflare Access interactive login must not intercept machine callbacks. Cloudflare IP-based rules are coarse protection, not customer quota enforcement.

Dify documented minimum 2 CPU/4 GiB RAM, Compose >=2.24. Initial sizing estimates: development 2–4 vCPU/4–8 GiB, production 4 vCPU/8–12 GiB and 80–100 GB SSD excluding Chatwoot. Inspect current workloads and peaks before deciding existing vs dedicated VPS. Prefer Ubuntu 24.04 LTS for new host; no forced upgrade on existing host. No GPU needed. Start with upstream default vector backend; select supported release and inspect Compose profiles before installing. Separate gateway database/user and Redis credentials/keyspace; dedicated Redis if supported ACL/isolation cannot be assured. Never share application credentials with WordPress or Chatwoot. Pin Dify release, plugin versions and gateway dependencies/images; review release notes, security advisories and license. Upstream sources returned inconsistent current release numbers; exact tag is an implementation gate, not assumed. Dify license is modified Apache with extra restrictions; verify own-company usage and redistribution restrictions against selected tag.

### Deployment checklist

1. Collect OS, CPU/RAM/disk, 7-day load if available, Docker/Compose versions, port inventory, Chatwoot deployment topology/version, backups and maintenance windows. No secrets or raw environment dumps in chat.
2. Choose isolated host/environment; inspect official tagged `.env.example` and Compose file; configure unique secrets, DB passwords, storage persistence, ingress/ports, network and egress. Avoid default passwords and binding public admin endpoints during initialisation.
3. Clone reviewed tag and copy `.env.example` to `.env`; apply secure overrides before `docker compose up -d`; verify service health and one-time init completion. Do not run on production before capacity approval.
4. Create Dify admin, restrict UI, install signed official OpenAI plugin; configure restricted OpenAI project key; test exact `gpt-6-luna` ID, supported reasoning settings, structured outputs, embedding provider and storage/retention behavior. Configure no web search or tools.
5. Create staging KB and workflow; publish, issue app API key; separate knowledge API key for import only. Gateway runtime has app key, not dataset management key.
6. Deploy gateway API/worker, migrations and secrets. Test signed webhook, state and rate policies. Connect test inbox. Production enablement requires acceptance.
7. Back up PostgreSQL, Dify storage, vector store and configuration/keys (encrypted); export DSL and canonical knowledge; define consistent snapshots and restore test. Provisional RPO 24h, RTO 4h; validate with stakeholders. Rollback via disable bot, open pending conversations, restore last tested workflow/image/config; database migrations may require full compatible restore. Never blindly downgrade schema.

## 4. Chatwoot integration contract

Create Settings > Bots > Add Bot, set name/avatar/webhook URL, obtain bot secret and dedicated bot API token; attach only staging inbox through Bot Configuration. Native bot conversations start pending; explicit handoff changes status to open. Current documentation describes Agent Bot HMAC signing; v4.13.0 release notes introduced signed bot/channel webhooks. Verify actual installed build and header/secret behavior. If absent, upgrade or use verified private authenticated transport before production. No unsigned public ingress.

Gateway endpoint `POST /webhooks/chatwoot/{integration_id}`. Config maps integration to allowed account/inbox IDs, expected bot, secret and configured Chatwoot base URL. Never use caller-provided URLs to call services. Read raw bounded body, validate timestamp freshness (initial 300 seconds, accommodate verified retry behavior), constant-time HMAC-SHA256 `timestamp + '.' + raw_body` against `X-Chatwoot-Signature`, check `X-Chatwoot-Delivery` when present. Verify account, inbox, event and schema. Deduplicate `(account_id, message_id)` with unique DB constraint; delivery ID optional secondary signal. Only customer-authored incoming public text `message_created` enters reply queue. Ignore bot/agent/outgoing/system/private/edited events for generation; status/assignment events can invalidate ownership when available. Normalise numeric/string event fields against installed version. Acknowledge only after transaction commits durable job or verified no-op; return non-2xx on temporary persistence failure; verify Chatwoot retry behavior rather than assuming it. No inference in webhook handler.

API calls (application API, `api_access_token` header):
- `GET /api/v1/accounts/{account_id}/conversations/{conversation_id}`: refresh ownership/status.
- `GET /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages`: bounded public history; verify pagination semantics.
- `POST /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages`: `{ "content": "...", "message_type": "outgoing", "private": false, "content_type": "text" }`.
- `POST /api/v1/accounts/{account_id}/conversations/{conversation_id}/toggle_status`: `{ "status": "open" }` for handoff; never implicit toggle.
- Private note and label/assignment endpoints optional; verify bot-token permission for each. If additional token needed, separate minimal credential; no general administrator token for inference.

### Human ownership and delivery reliability

Check live Chatwoot status and assignment before inference and immediately before reply; allow only bot-enabled configured inbox with pending, no human owner, no inhibit latch, matching ownership generation. Human takeover invalidates queued/in-flight work; do not resume on status change alone. Staff explicit return-to-bot resets latch for a new bot session, subject to live state. Handoff latches inhibit before API call, then sets open and optionally records reason in private note; retry status update only as explicit target, reconcile failures and alert staff. Open status alone does not guarantee human assignment; test routing/team coverage and alert if unassigned. On outage, staff can detach bot and recover pending conversations manually.

One worker per conversation; use DB row/advisory lock or lease with fencing and heartbeat; reject stale results. Persist send intent and result message ID. Chatwoot API atomic ownership check and idempotency are not yet verified. A status check followed by send has a race; a network timeout after send is ambiguous. Do not claim exactly-once or atomic ownership. Never blindly retry ambiguous sends; reconcile against Chatwoot history using verified correlation marker if supported, otherwise inhibit and flag for manual review. Test race conditions; unresolved unacceptable races block public rollout or restrict to draft-only. No direct DB edits to compensate.

## 5. Dify workflow contract

Use Dify Studio > Create from blank > Workflow. Name `VG Customer Support V1`. Publish only reviewed versions. Export DSL to GitHub; environment-specific dataset IDs and secrets mapped separately. Call `POST /v1/workflows/run` with `Authorization: Bearer <app-key>`, `response_mode: blocking` initially (worker only, test timeout; switch SSE internally if needed), `user` stable pseudonymous contact key, `inputs` configured in Start node.

Proposed input fields: `request_id`, `query`, `history_json` (bounded text serialization with roles, no internal notes), `locale_hint`, `brand_scope`, `channel`, `as_of_utc`, `kb_release`. Gateway derives scope and time from trusted config, never customer input. No email/phone/name or unrelated conversation history unless approved necessity. Dify API `user` is not an authentication credential or customer identity verification.

Nodes:
1. User Input: required fields, text-only.
2. LLM classify/rewrite: `in_scope`, `off_topic`, `clarify`, `human_requested`, `account_specific`, `suspected_injection`, `greeting`; use bounded history; produce category, locale, standalone retrieval query. Explicit human requests also caught locally where feasible. No actions.
3. IF/ELSE: off-topic, greeting, clarification and handoff branches use approved fixed or bounded templates. Mixed requests answer eligible part only when safe; unclear is clarify, not off-topic.
4. Knowledge Retrieval: approved public dataset, filter scope/current version; hybrid search where supported, Top K initially 4–6, score threshold calibrated (not universal), embedding `text-embedding-3-small` candidate or multilingual alternative after tests; no web search. Capture real retrieved article/version/chunk IDs and excerpts. For no/weak/contradictory evidence -> handoff/clarify. Retrieval score is not factual confidence.
5. LLM answer: use evidence only, no fabricated details, natural Afrikaans/English. Strict structured result; source references selected from retrieved evidence. No unrestricted agent node, HTTP tool, browser or MCP.
6. Optional evidence verifier for risk categories or pilot; no claim of perfect hallucination detection. For critical policies use approved verbatim text or handoff. Validate output format in gateway, cross-check sources against retrieval records and current published manifest, scope, expiry and allowed URL hosts. Evidence references alone do not prove entailment; test actual correctness. Fail closed.
7. Output node: return typed result fields and retrieval manifest; ensure every branch produces contract, errors become handoff. Model cannot set destination, permissions or state.

Proposed result schema (illustrative; IDs here are placeholders, not existing articles):
```json
{
  "schema_version": "1.0",
  "decision": "answer",
  "locale": "af-ZA",
  "category": "ticketing",
  "reply": "<approved grounded answer>",
  "evidence": [{"article_id":"VG-KB-0001","version":"1.0.0","chunk_id":"<retrieved-id>"}],
  "reason_code": "supported"
}
```
Allowed decisions: `answer`, `clarify`, `decline`, `handoff`, `greeting`. Evidence mandatory for business factual answer; empty for fixed template greetings/refusals. Gateway checks schema (no unknown fields), output length, locale, evidence membership and active version, PII/secret risk, allowed links and ownership. Dify's workflow response envelope is separate from this output schema; validate `data.status` and `data.outputs` against deployed version. No trusting model self-reported confidence or usage. Gateway generates handoff messages, status changes and off-topic warnings itself. Failures -> safe response or human queue, no speculative answer. Workflow can be run independently via test harness; no API keys in browser.

## 6. Knowledge base and editorial process

Proposed canonical source: a dedicated SharePoint list `Voelgoed Customer Support Knowledge`, subject to verification of staff permissions, version history, reviewer process and API access. Alternative: versioned Markdown in private Git repository if technical team owns editing. Do not maintain two editable masters. Start with manual approved import to Dify, then build a publisher when repetitive updates justify it. SharePoint event/Graph delta sync can be introduced later, no AI polling. Dify Knowledge API supports create-by-text, metadata and asynchronous indexing; verify selected release endpoints. No broad SharePoint or mailbox access by runtime bot.

Article fields: immutable `article_id`, version, title, category/subcategory, brand/product/event scope, locale, alternative question phrases (Afrikaans/English), approved answer, steps, exceptions, handoff criteria, public source URLs, authority reference (internal only, excluded from retrieved text if sensitive), owner, reviewer, approval timestamp, effective_from, expires_at, review_due, visibility, status, last modified, content hash. Version per language variant with common article ID; translations approved independently; contradictory variants block publication. Public-support facts only in runtime index. No raw customer emails, personal details, internal notes or unpublished drafts. Prefer one coherent FAQ per document; keep answers/conditions together; chunk only long procedures; test retrieval of acronyms, misspellings, mixed-language and exact dates/event names. Provide links only if approved.

Initial categories: events/tickets, memberships/subscriptions, online learning, online shop/delivery, login/password troubleshooting, billing policy, contacts and current campaigns. Use prior Navrae mailbox audit to rank question frequency; actual audit results must be retrieved/verified before assigning priorities. Redact and deduplicate historical examples, extract candidate questions, identify conflicting answers, validate against current official policy, get business owner approval, publish. Begin with 20–30 high-value articles, expand to 50–100 after retrieval quality. Use 2027 cruise/event FAQs only after owner confirms details and validity windows. For pricing/availability/promotion with no current authoritative evidence, handoff or link to approved source; no stale claims.

Article lifecycle (per immutable version): DRAFT -> IN_REVIEW (required fields complete) -> APPROVED (authorised reviewer, authority valid) -> PUBLISHING (publisher only, current approval, no forbidden content) -> PUBLISHED (index completed, retrieval smoke test, manifest activation). IN_REVIEW -> DRAFT on rejection; PUBLISHING -> PUBLISH_FAILED on error (not retrievable through gateway; retry after repair). PUBLISHED -> SUPERSEDED/EXPIRED/REVOKED (terminal version states, revoke active manifest first then disable/remove index); historical versions retained under retention policy. Edits create new DRAFT, never silently mutate published version. On index failure, old valid version remains or article unavailable; do not keep revoked data available. Use current manifest at gateway delivery check; prefer staged/new dataset release or explicit deny-by-version while indexing. Verify retrieval excludes non-published content. If manifest unavailable, fail closed. Scheduled expiry software job plus time check at answer delivery; do not wait solely for index refresh. Audit every approval, publication, failure, retirement. No autonomous publication from chats.

## 7. Lifecycle and state

Separate ownership from job processing; do not encode both in one conversation status. Bot session: `BOT_ELIGIBLE`, `BOT_PAUSED` (cooldown/operator/budget), `HANDOFF_PENDING`, `HUMAN_OWNED`, `CLOSED`. Pending Chatwoot with configured bot and no human assignee plus no latch is eligibility guard. `BOT_ELIGIBLE -> BOT_PAUSED` on quota/kill switch; recover only after cooldown/authorised enablement and live eligible state, otherwise handoff. `BOT_ELIGIBLE/BOT_PAUSED -> HANDOFF_PENDING` on user request/risk/failure; inhibit immediately, set open. `HANDOFF_PENDING -> HUMAN_OWNED` on confirmed open/human control, alert if unassigned. Any active state -> HUMAN_OWNED on human takeover (cancel/invalidate jobs); any -> CLOSED on resolve. Human -> BOT_ELIGIBLE only via explicit staff return-to-bot/new session with valid pending state. CLOSED terminal per session; reopen creates new session under explicit ownership rules. Clarification is a result, not ownership state.

Job lifecycle: `RECEIVED -> QUEUED -> RUNNING -> VALIDATED -> SEND_PENDING -> SENT`; guards signature, persistence, quota reservation, lease, valid result, ownership and manifest freshness. Other terminal outcomes `IGNORED`, `SUPPRESSED`, `HANDED_OFF` (confirmed transfer), `FAILED_FINAL`, `DELIVERY_UNKNOWN` (requires operator reconciliation, no auto resend). `RUNNING -> RETRY_WAIT -> QUEUED` only bounded transient failure with still-valid ownership; permanent failure to safe handoff or FAILED_FINAL with alert. Stale lease fenced; no duplicate outbox delivery. Persist timestamps, attempt counts, correlation, reason codes, workflow run ID, output message ID; retention for raw content minimised. Worker recovery scans durable queue, no polling external AI continuously.

## 8. Abuse, privacy and costs

Initial configurable proposed quotas: 5 incoming eligible messages/min/contact; 30/hour/contact; 40 AI replies/day/conversation; 3 off-topic attempts/rolling hour -> 15-minute bot cooldown (do not block human help); 3,000 input chars/message; 6 recent public messages / 4,000 total history chars; 500 output tokens/answer including configured reasoning limit where supported; 3 LLM calls maximum/workflow; 30s target worker inference deadline, one active run per conversation, 5 global concurrent runs initially. Set independent body-size and queue limits; burst coalesce only with bounded delay and deterministic job lineage. Global cap e.g. $2/day and $20/month provisional, alerts 50/80/100%; user approval required. Provider billing alerts not assumed hard caps. Atomic quota reservations before inference, conservatively reserve cost including retries/embeddings/reasoning; reconcile actual trusted usage, handle unknown spend conservatively. Cross-contact abuse mitigated by inbox/global caps and website ingress protection; Chatwoot server webhook IP is not customer IP. A contact ID is not a verified identity; distinguish cross-channel aliases. Rate limit fallback template once per window, offer human assistance, do not repeatedly escalate spam. Separate human availability policy.

No tools for generic questions, no open web, no arbitrary URL fetching, no attachments V1. Input and retrieval text untrusted instructions; approved content never grants permissions. No secrets in prompts. Apply data minimisation/redaction, encrypted transport/storage/backups, RBAC and separate keys, log redaction and restricted access. POPIA assessment: processing purpose, lawful basis, notice, provider agreements/cross-border transfers, retention and data-subject requests. Dify and model-provider logs may retain text; verify actual provider storage settings including `store:false` if plugin supports, not equivalent to zero data retention. Proposed raw gateway retention <=7 days where necessary, operational metadata <=90 days subject to approved policy and legal requirements; Chatwoot authoritative transcript retention separate. Incident response: disable affected inbox/global processing, revoke keys, reconcile pending conversations, preserve necessary audit evidence. No claims of POPIA compliance until review.

OpenAI Luna published standard rates $0.10/M input, $0.50/M output and $0.01/M cached input; 10k turns at 3k input/500 output total each = $5.50 (~R99 at illustrative R18/USD), excluding embeddings, retries, hosting, tax. Use measured whole-workflow tokens including reasoning and validation. Monitor answer accuracy, p95 latency, cost/turn, automated resolution (confirmed, not merely sent), escalation, off-topic/abuse, unanswered intents, queue depth, duplicate and delivery-unknown counts. No public launch without real measured budget and alert testing.

## 9. Repository and delivery

Proposed private repository `voelgoed-ai-support`:
```
docs/spec/                 # cumulative versions and ADRs
infra/                     # pinned Compose overlays, env examples, deploy/backup runbooks
gateway/app/api/           # signed webhook handler
gateway/app/adapters/      # Chatwoot and Dify clients
gateway/app/domain/        # states, quotas, policy, types
gateway/app/workers/       # durable job execution and delivery
gateway/app/storage/       # migrations, repositories, audit
workflows/dify/            # reviewed DSL exports and mapping docs
knowledge/                 # schema, importer, examples (no customer data)
evals/                     # anonymised fixtures, expected outcomes
tests/                     # unit, integration, end-to-end
```
CI: formatting/lint, typing, unit/integration, schema and fixture validation, dependency/secret scans, Compose config validation, versioned DSL review. No production keys in CI. PRs small and scoped; exact full diff/head/base/CI/contracts independently reviewed before merge. Staging smoke tests before manual production release. No claim of implemented or deployed until evidenced.

## 10. Vertical slices / acceptance

| Slice | Deliverable | Acceptance evidence |
|---|---|---|
| VGAS-000 | Discovery & decisions | server audit; Chatwoot version/signature; deployment option; exact Dify tag/license; owners and budget approved |
| VGAS-001 | Isolated Dify deployment | health, HTTPS/access restriction, backup and restore, Luna structured response, embeddings |
| VGAS-002 | KB seed and editorial model | 20–30 approved FAQs, bilingual retrieval results, expiry/revocation test |
| VGAS-003 | Standalone workflow | published DSL, typed contract, answer/decline/clarify/handoff fixtures, no-evidence failure closed |
| VGAS-004 | Gateway + test inbox | signed webhook, dedupe durable jobs, fixed echo/test response, explicit handoff; auth and permission evidence |
| VGAS-005 | End-to-end AI and safeguards | provider call, history boundaries, quotas, budgets, race/timeout/recovery tests, ownership inhibition |
| VGAS-006 | Shadow and pilot | private drafts or replay first; human review, monitored low-risk subset and rollback rehearsal |
| VGAS-007 | Production expansion | approved go-live checklist, support coverage, channel-specific tests and metrics |
| VGAS-008 | Knowledge sync / gap reports | controlled publisher if needed, approval and index reconciliation; no automatic answer approval |

Phases 001/002 can run in parallel after 000; 003/004 independently against fixture contract; 005 joins both. Initial evaluation: >=95% answer correctness on answerable set, >=98% off-topic handling and unanswerable escalation; zero critical unsupported financial/policy claims, unauthorised disclosures, duplicate deliveries or replies after observed human ownership in test suite. Include 100+ representative anonymised cases with Afrikaans/English and multi-turn, adversarial and outage scenarios; zero observed failures is not proof of zero real-world risk. Race/ambiguous delivery limitations documented and approved, otherwise draft-only. Test data from real audit requires approval/redaction. Operational metrics proposed p95 <15s where feasible; timeouts/handoff tested. Rollback kill switch + detach inbox + recover pending queue.

## 11. Open decisions and blockers

- Actual Chatwoot host/version, agent bot signing and API token permission, human routing/team/working hours, channel constraints and message/ownership API race behavior.
- VPS resource measurements, network topology, reverse proxy and backup destination; existing vs dedicated host, staging separation.
- Exact Dify release and plugin pin (web snapshots inconsistent); license review; vector backend, supported parameters, retention and usage telemetry.
- Knowledge source and owners, approved source documents, mailbox audit results, reviewer permissions, publishing cadence, policy for expired promos.
- Budget, rate-limit values, support escalation SLA, retention/POPIA review, pilot scope, approved domain names.
- No repository, DNS, servers, keys, knowledge or workflows created by this specification. Proposed names, sizing, limits and lifecycle rules await review; not deployment-ready without VGAS-000.

## 12. Authority references (reviewed 2026-11-25; reverify pinned versions)

- Dify upstream and release notes: https://github.com/langgenius/dify/releases ; https://github.com/langgenius/dify/blob/main/docker/README.md ; https://github.com/langgenius/dify/blob/main/LICENSE
- Dify Docker: https://docs.dify.ai/en/self-host/deploy/quick-start/docker-compose
- Dify Workflow/Chatflow: https://docs.dify.ai/en/cloud/use-dify/build/workflow-chatflow
- Dify Workflow API: https://docs.dify.ai/en/api-reference/workflow-runs/run-workflow
- Dify LLM and retrieval: https://docs.dify.ai/en/self-host/use-dify/nodes/llm ; https://docs.dify.ai/en/cloud/use-dify/nodes/knowledge-retrieval
- Dify Knowledge API: https://docs.dify.ai/en/api-reference/documents/create-document-by-text ; https://docs.dify.ai/llms.txt
- Dify OpenAI plugin: https://marketplace.dify.ai/plugin/langgenius/openai
- Chatwoot Agent Bot and signing: https://chatwoot.help/hc/user-guide/articles/1677497472-how-to-use-agent-bots ; https://chatwoot.help/hc/user-guide/articles/1677693021-how-to-use-webhooks ; https://github.com/orgs/chatwoot/discussions/14087
- Chatwoot messages and status: https://developers.chatwoot.com/api-reference/messages/create-new-message ; https://developers.chatwoot.com/api-reference/conversations/toggle-status
- Model and price: https://developers.openai.com/api/docs/models/gpt-6-luna ; https://developers.openai.com/api/docs/pricing

## Revision history

- 0.1.0 (2026-11-25): initial proposed spec; Dify Workflow preferred over earlier Chatflow design; defined authority, ingress, job/session lifecycle, KB editorial lifecycle, controls, deployment and delivery slices. No approval or implementation claimed.
