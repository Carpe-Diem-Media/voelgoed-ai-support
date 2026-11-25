# AGENTS.md — Voelgoed AI Support

Policy version: 1.0.0 | Architecture: VGAS v1.0.0

## Mission and authority

Deliver the smallest secure, reliable Chatwoot CE support MVP using Phoenix/Elixir, Ash, Ash AI/ReqLLM, PostgreSQL/pgvector and Oban. One public assistant, one initial inbox, Afrikaans/English approved text FAQs, no live business actions. Preserve VGAS-P001 (MVP first). This is not a general-purpose agent platform.

Before editing, read the repository's actual instructions, current slice brief and applicable sections of `docs/spec/VGAS_IMPLEMENTATION_SPEC_v1.0.0.md`, `docs/spec/VGAS_RESOURCE_CONTRACTS_v1.0.0.md`, `docs/spec/VGAS_SPEC_v1.0.0.md` and `docs/VGAS_ROADMAP_v1.0.0.md`. If these files have not been installed, use the delivered pack and report missing repository authority. Latest explicitly accepted cumulative amendments govern; implementation spec is the active engineering view. If conflict or unsupported API is found, stop the affected portion, document it and ask for a narrow amendment; do not invent requirements or silently weaken them. Continue independent safe work. Exact API and dependency versions must be verified from official pinned docs/source and lockfile, not old examples. No production authority implied by architecture approval.

## Development rules

- Before implementation begins, the orchestration agent must delegate creation of the implementation plan to a subagent. Use GPT-6.2 Sol on Codex Pro when available, or a comparable planning model. The orchestration agent reviews the plan against the assigned slice and approved project requirements before proceeding.
- One assigned vertical slice per PR; inspect actual code/migrations, do not scaffold future tables or frameworks. Prefer current compatible stable Ash-native functionality, ordinary Elixir where simpler, and a narrow direct ReqLLM path only when required. Use supported generators and review output. Pin Elixir/OTP, dependencies and images; commit mix.lock and migration snapshots. No speculative package extraction, umbrella, Redis, Dify, Hindsight, tool framework, multi-agent loop or extra UI features.
- Explicit Ash actions, policies and typed input/output; no blanket CRUD or `authorize?: false` in normal runtime; trusted narrow system actors, never customer/model identity. Names precise; comments explain rationale, invariants and nonobvious behaviour. Do not copy unverified DSL. All meaningful lifecycles explicitly define states, transitions, guards, side effects, failure paths and terminal states. State-machine DSL is not concurrency proof.
- Use UUIDv7 for business keys; qualified external IDs, DB-enforced identities, foreign keys, active pointer/claim constraints, UTC, exact integer nano-USD. No HTTP in long DB transactions. Atomic claims/fencing, idempotent ingress+enqueue, transactional outbox, no blind retries for ambiguous external sends or inference. No claim of remote exactly-once. Chatwoot owns transcripts/status/assignment; AI permissions locally denied unless verified. Human handover sticky; no auto resolve. Unknown outcome remains unknown until reliable evidence or authorised conservative closure.
- Only authorised, published, currently valid knowledge before retrieval and again before send. No internal knowledge in public prompts, drafts, revoked revisions, arbitrary URL fetch, secrets or private staff notes. No permanent customer memory or attachments. Exact sensitive answers rendered by software; model proposals validated, no evidence or insufficient scope means clarify/handoff. No hidden/unbounded retries; at most two total generative calls/turn under proposed caps; reserve before every paid external call including embedding, settle trusted usage, preserve uncertain spend. Enforce first-use safety rather than postpone to hardening.
- No production credentials, personal data, raw prompts, transcripts or customer payloads in Git, fixtures, CI or logs. Use sanitised fixtures and separate test keys with explicit budget. Never expose secrets in reports. Store minimal operational metadata. No production changes, hosting purchases, DNS changes or deployments without explicit approval. Default automation disabled; assisted fallback if external safety unresolved.
- Keep changes focused. Record unrelated findings in Plane and keep their fixes outside the assigned slice. Parallelise only independent slices, never overlapping migration/resource edits.

## Plane execution and Ready authority

Plane is the authoritative issue and development tracker for Voelgoed AI Support. Record every issue and blocker in Plane and link every dependency to the affected issue. Update Plane whenever progress, blockers or dependencies change.

Use the **VGAS Implementation Board** in the Voelgoed AI Support project as the live execution queue. During an authorised VGAS development run, the executing agent has standing authority to promote and start eligible tickets within the run's approved scope, including the next slice. Routine handoffs require no separate assignment. Record the owner-reviewed VGAS-000 decision before starting VGAS-001. A conditional GO authorises only the work it explicitly permits.

1. Before choosing work and after each ticket reaches a handoff or blocker, refresh the live queue. Read the candidate ticket's scope, acceptance criteria, priority, dependencies and prerequisites. Keep work already assigned to another agent or sharing resources or migrations with active work out of your queue.
2. Move an executable ticket from **Backlog** or **Blocked** to **Ready** when its scope and acceptance criteria are agreed, blocking tickets are **Done**, and other prerequisites for starting are satisfied. Record the evidence in Plane. Keep unresolved access, evidence or owner decisions visible as blockers on the affected work. Phase summaries stay in Backlog until their work is scoped for execution.
3. Start the highest-priority eligible **Ready** ticket in Plane's order and move it to **In Progress**. Record verification evidence at handoff. Use **In Review** while required review is pending and **Done** only after the ticket's acceptance and review gates are met. Refresh downstream tickets and continue with the next eligible item. Stop when the approved scope is complete, the owner pauses the run, or every remaining in-scope item needs a blocker resolved.
4. Apply the governing specs and slice brief at each transition. Keep independent review and owner approval for merging, and obtain separate authority for paid inference, real customer-data processing, deployment and production activation.

## Local bootstrap and parallel work

1. Run `git status -sb` and identify the assigned branch or worktree. Use the Erlang and Elixir versions in `.tool-versions`. If the shell uses different versions, run commands through `mise exec -- <command>`.
2. Read `.devcore/project.conf` and `.devcore/render-map.tsv`, then run `devcore-project doctor`. If the allocation or generated environment is missing or stale, run `devcore-project plan`, then `devcore-project activate` and recheck. Each checkout needs its own ignored `.env.local`. DevCore supplies credentials.
3. Run `devcore-project run dev -- mix setup` and `devcore-project run test -- mix test`. Both use pre-provisioned databases and apply migrations. Verify locked dependencies with `mix deps.get --check-locked` and run `mix hex.audit` in a separate invocation. Keep the AshAuthentication and Phoenix adapter pins compatible when changing either version.
4. For a runtime check, choose a free project HTTP port as described below and run `PORT=4186 devcore-project run dev -- mix phx.server`, substituting the assigned port. Confirm `curl --fail http://127.0.0.1:4186/health` returns HTTP 200 on that port. The health route checks HTTP liveness. Use the Repo tests to verify database access and confirm pgvector availability before starting vector-backed work.

### Port allocation

- DEV PostgreSQL uses `127.0.0.1:55432`, database and role `vgas_dev`.
- TEST PostgreSQL uses `127.0.0.1:55433`, database and role `vgas_test`. ExUnit uses this allocation even when a DEV server is running.
- Use loopback ports `4186–4205` for local Phoenix sessions. The coordinating agent assigns distinct ports before dispatching parallel work, then each agent checks its port with `ss -ltn` before binding. If it is occupied or startup reports `:eaddrinuse`, coordinate another free port. Leave the existing listener running.
- Use separate worktrees for independent changes. HTTP ports isolate listeners only. Coordinate local database runs against the shared allocation. Run migration-changing or otherwise database-mutating work serially per database unless separate database allocations have been approved and verified.

### Cleanup and handoff

- Stop the servers, watchers and other processes you started unless the user asks to keep one running. Confirm your ports are free. If a process stays up by request, record its port, purpose and how to stop it.
- Remove temporary files you created once they are no longer needed. Preserve DevCore services, databases, secrets, other agents' processes, and uncommitted work. Remove a temporary worktree only after checking that its work is retained and the worktree is clean.
- Run `git status -sb` at handoff. Report the branch, pending changes, checks run and anything still running or blocked. Consult [Application CI](docs/development/application-ci.md) when changing test routing, cache behavior or the GitHub Actions gate.

## Mandatory verification for each slice

Run supported equivalents for formatting (`mix format --check-formatted`), compile warnings-as-errors, relevant ExUnit and real PostgreSQL tests, fresh/upgrade migration checks and generated snapshot consistency, dependency/advisory and secret scans, Compose validation where applicable. Discover exact tasks against pinned versions; do not claim a task ran if missing. Test negative auth, error paths and concurrency for affected contracts; deterministic external fakes in CI, bounded separate live smoke tests only with approved keys. Do not weaken tests to pass CI. Report exact commands, exit codes, tests and skipped/blocked tests; no false green status. Redact outputs. Do not call untested code implemented-and-verified.

## PR handoff and merge gate

Use the `$pr` skill whenever drafting or updating a PR description. Follow its template and include the repository-specific details below.

PR description: slice/authority IDs; scope and non-goals; changed files, migrations and actions; lifecycle/authorization changes; tests and evidence; exact head/base; failure modes, risks, rollback; unresolved blockers and deferred issues. Open a scoped PR only if requested/authorised, after local checks. Independent reviewer must inspect exact complete PR diff, current head/base, CI status/results, required tests, all applicable authority references, security, permissions, data integrity, regressions, compatibility and rollback BEFORE any merge recommendation. Never approve on agent summary alone; no merge or production deploy by coding agent unless separately authorised. Distinguish implemented, tested, review-ready, merged, deployed. Red CI, unresolved material blocker or missing evidence means no merge recommendation.

## Exit conditions

Deliver each slice with its verification evidence, updated Plane status and applicable runbook. Follow the Plane execution rules above to select the next eligible ticket within the approved scope. If external access blocks a check, record the precise blocker and finish independent checks. Record narrow follow-up when needed. The release owner alone approves live automation after G038 gates.
