# Coding-agent brief — VGAS-000

Version 1.0.0 | 2026-11-25 | First assignment | Status: NOT STARTED

## Mission

Prove the smallest viable Ash-native foundation for the support MVP. Produce evidence, not a finished chatbot. Time-box core feasibility to approximately 4–6 engineering hours; this is an effort cap, not a completion promise. Work locally or in explicitly isolated staging. Do not create a full production schema, UI, or deploy to the VPS. Do not install Dify or Hindsight. The approved architecture and scope are in AGENTS.md, VGAS_IMPLEMENTATION_SPEC_v1.0.0.md (G001–G038, especially G017–G025/G026–G029/G036), VGAS_RESOURCE_CONTRACTS_v1.0.0.md, VGAS_SPEC_v1.0.0.md, VGAS_ROADMAP_v1.0.0.md. Inspect actual repository and local environment before editing. Use current stable compatible Ash packages, not stale versions from previous conversations.

## Allowed scope / outputs

If repo exists, work on a dedicated branch, e.g. `spike/vgas-000`; follow actual repo conventions. If not, initialise only a local disposable spike with explicit user-controlled repo setup (no remote creation unless authorised). Suggested paths `spike/vgas-000/` for isolated code, tests and local Compose; `docs/evidence/VGAS-000_REPORT.md` for report; `evals/fixtures/vgas-000/` for sanitised fixtures. Do not modify production app contracts or shared unrelated resources. If generator requires different paths, report chosen paths. Keep useful spike code only if reviewed for reuse in 001; no commitment to merge temporary code as production. Record dependency lock and image versions within spike. No production secrets/data. Test credentials provided securely through runtime environment; never echo, commit or log them.

## Prerequisites (request only missing access; continue local work)

- Local Elixir/OTP and Docker/Compose or supported equivalent; disposable PostgreSQL with pgvector.
- Dedicated staging OpenAI project/key, live model entitlement, approved small test spend cap (no paid execution without approval), verify pricing and caps. User/owner supplies via environment, not chat/Git. Disable implicit retries, bound input/output/reasoning and reserve test allowance before each call; no unknown-spend automatic retry. Use synthetic data only. Separate test and production budgets.
- Actual Chatwoot version/host, test account/inbox, dedicated test bot token and signing secret, verified access and permission. No bot in live inbox, no changes to existing human assignments.
- Microsoft Entra test app registration, approved tenant, callback and scoped permissions; no broad directory access. If unavailable mark external gate BLOCKED.
- Read-only server capacity audit (CPU/peak load, memory, disk, ports, containers and backup topology); no installation or configuration changes. Host findings are deployment prerequisites, not evidence against Ash.

## Test matrix and execution order

| ID | Task | PASS evidence / required negative path |
|---|---|---|
| F01 | Resolve current compatible stable Elixir/OTP, Phoenix, Ash, AshPostgres, Ash AI, ReqLLM, Oban/AshOban, AshAuthentication and AshStateMachine as applicable | Record exact versions, mix.lock, upstream versioned docs/source links and advisories, compile and fresh migrate on disposable DB, show pgvector extension/version; no guessed APIs |
| F02 | Native Ash AI structured prompt-backed action with Luna | Exact model ID, typed output with unknown/invalid field rejection, request metadata and actual usage; verify timeout, output/reasoning bound, stateless storage options and internal retry behaviour; narrow ReqLLM test only if wrapper insufficient |
| F03 | Inference control | Demonstrate reserve-before-call with conservative upper cost in bounded test harness; no request on insufficient allowance, trusted usage reconciliation, timeout remains uncertain, no secret logs; include embedding calls. Use mocks for failures; real provider call only authorised and capped |
| F04 | Approved FAQ vectorization | 20–30 sample FAQ revisions (synthetic or approved anonymised), one approved variant vector/locale; explicit background generation, actual dimensions/profile/hash, no embedding on draft edit; verify supported DSL or narrow adapter |
| F05 | Authorised hybrid retrieval | Exact cosine + lexical baseline, deterministic rank fusion, ~20 bilingual/mixed/ambiguous/off-topic cases with expected evidence; revoked/expired/unpublished/internal/wrong grant excluded before model projection; no-match not assumed abuse; record candidate rankings and human-labelled results |
| F06 | Chatwoot local ingress | Raw-body signature fixture matching actual documented algorithm; invalid signature/timestamp, duplicate message event, qualified scope, transactional event+Oban enqueue and rollback; fixed reply/handoff HTTP boundary fakes; no repeated send on ambiguous outcome |
| F07 | Actual Chatwoot test integration | Verify deployed signing/event coverage, token permissions, pending/open/human ownership, message creation/read correlation survives round trip, explicit handover; document race and unknown delivery. If external guarantees absent, no automatic pilot approval; use assisted fallback |
| F08 | Entra and staff authorisation | Verify tenant/issuer/subject and local allowlist, wrong tenant/disabled local user denied, session revocation or subsequent privileged denial. Real test registration if available, local fixture otherwise labelled partial/BLOCKED |
| F09 | Hosting readiness | Read-only capacity and topology evidence; identify staging separation, TLS, backup/restore requirements, proposed deployment location; no live changes |

Use ordinary deterministic CI tests for external boundaries. Capture exact commands and exit status, measured latency/usage for real calls, expected vs actual results, no credentials or raw personal content. Do not convert mocked evidence into live PASS. If access missing, report BLOCKED for live test and still perform local independent portions. Avoid repeated provider calls merely for exploration; respect test budget and deadline.

## Stop/go rule

- GO native when compatible versions compile and migrate, typed inference with finite bounds/trusted usage and authorised bilingual retrieval pass core tests. Explicitly distinguish core GO from external readiness. If live model not tested, core GO remains conditional, no production inference.
- If Ash AI wrapper lacks required observability, use ReqLLM directly for that narrow operation after recording evidence. If native vectorization cannot satisfy eligibility/generation, test smallest explicit pgvector adapter. Do not add new services. If core remains failing or threatens urgency after bounded investigation, report STOP/REVIEW and propose one narrow amendment; Dify only after explicit decision, not automatic switch.
- Chatwoot, Entra, host or credentials blocked: continue local foundation where safe, block affected live gate. No release approval from feasibility. No requirement to prove all production-grade implementation in a spike.

## Report template (required)

```markdown
# VGAS-000 feasibility evidence
- Commit/branch, environment, date, test data classification
- Exact toolchain/package/DB/image pins and upstream authority references
- F01–F09: PASS / FAIL / BLOCKED / PARTIAL; expected, observed, command, exit status, evidence path
- Model options, actual usage/bounds/retry findings; test budget authorised and measured spend; unknown outcomes
- Retrieval evaluation: cases, evidence IDs, expected/actual, errors, profile and timing
- Chatwoot deployed version, signing/event scope, correlation and race findings (no secrets)
- Entra/host evidence or specific access blocker
- Security/negative tests, known limitations, narrow fallback decision if needed
- GO / CONDITIONAL GO / STOP-REVIEW, reasoning, remaining gates, no live-launch claim
- Changed files, rollback/cleanup steps, deferred issues and suggested next VGAS-001 scope
```

At exit, stop after report and local tests. Do not merge, deploy, modify real inboxes, ingest customer data or start VGAS-001 without separate assignment. If authorised to open a PR, include exact diff/head/base and CI/test evidence for independent review. AGENTS.md merge gate mandatory.
