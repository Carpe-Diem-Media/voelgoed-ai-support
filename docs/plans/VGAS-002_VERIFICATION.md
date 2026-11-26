# VGAS-002 PR B verification

Plane VGAS-13. PR #9 started at `59fce6c`, based on `24453be`. Evidence below applies to the local candidate. A-010 keeps the deployed contract, isolated Chatwoot checks and Req wire-attempt test pending under F07/VGAS-8. The overdue-input rule remains triage only. The owner decision about overdue remote routing remains open.

## Acceptance matrix

Test files below use their basenames under `test/voelgoed_ai/support`, except `chatwoot_webhook_test.exs` under `test/voelgoed_ai_web` and the inherited staff tests under `test/voelgoed_ai/accounts`.

| §8 area | Case | Status and evidence |
| --- | --- | --- |
| AC1 | Signed bytes, terminal receipt, job and accepted fixed reply | Covered. Workflow, "the durable receipt produces an accepted fixed reply". |
| AC1 | Run pins revision and current epochs | Covered. Workflow, "the durable receipt produces an accepted fixed reply" checks the stored revision and four epochs. |
| AC1 | Receipt and job invisible before commit and durable after commit | Covered. Ingress, "another connection cannot see the receipt before its job is inserted". |
| AC1 | Authorized handoff persists inhibit, cancels the reply, writes status once and confirms | Covered. Workflow, "only a current support operator can request a durable handoff". Delivery recovery, "a closed reply window still permits qualified status handoff". |
| AC1 | Closed reply window permits qualified handoff | Covered. Delivery recovery, "a closed reply window still permits qualified status handoff". |
| AC1 | Shadow and assisted send zero writes | Covered. Workflow, "shadow completes its decision without a delivery" and "assisted completes its decision without a delivery". |
| AC1 | Default-disabled endpoint creates no work | Covered. Webhook, "default endpoint does not accept Chatwoot work". |
| AC1 | Deployed signed flow, duplicate, takeover, closure, handoff, crash and ambiguous send | Staging-only. F07/VGAS-8. |
| AC1–2 | Nil and unrelated role deny | Covered. Configuration, "actions reject anonymous, wrong role, forged input and stale authority". Workflow, "only a current support operator can request a durable handoff". |
| AC1–2 | Wrong processing, delivery and reconciliation scopes | Covered. Workflow, "receipt processing denies mismatched worker scope and runs with the qualified scope". Delivery recovery, "delivery and reconciliation deny crossed roles, wrong targets and wrong inboxes". |
| AC1–2 | Forged target and inbox deny | Covered. Same job-scope tests. |
| AC1–2 | Stale and revoked staff deny | Covered. Configuration, "actions reject anonymous, wrong role, forged input and stale authority". Workflow, "only a current support operator can request a durable handoff". |
| AC1–2 | Staff and operational audit actions are separate | Covered. Configuration, "operational audit is distinct and an audit error rolls back publication", and the direct staff authorization suite. |
| AC1–2 | Historical revision and terminal lifecycle | Covered. Configuration, "discard and the composite pointer and published slot are enforced" and "assistant activation, disable and retirement fence prior epochs". |
| AC1–2 | Concurrent publish and cross-assistant pointer | Covered. Configuration, "publish serializes the compare and switch on the assistant row" and "discard and the composite pointer and published slot are enforced". |
| AC1–2 | Configure, disable, rebind, retire and stale configuration | Covered. Configuration, "binding qualification, scoped safe reads, fencing and terminal retirement", "binding mutations lock the assistant first and retirement needs disabled bindings" and "a binding action rejects a rebind committed while it waits for the old assistant". |
| AC1–2 | Global switch between claim and dispatch | Covered. Delivery recovery, "a restored control cannot authorize a handoff claimed under its old epoch". |
| AC1–2 | Disabled binding between claim and dispatch | Covered. Delivery recovery, "disabling the binding after claim cancels the public write". |
| AC1–2 | Automatic mode denied with network adapter unavailable | Covered. Configuration, "binding qualification, scoped safe reads, fencing and terminal retirement". |
| AC1–2 | Operator projection scope, action and target validity | Covered. Delivery recovery, "the operator projection exposes only internal intent references and safe reasons". |
| AC1–2 | Staff history and auth regressions | Covered by the inherited staff suite. |
| AC2 webhook | Missing, duplicate and malformed headers | Covered. Webhook, "rejects missing, duplicate and malformed authentication headers". |
| AC2 webhook | Wrong HMAC and raw whitespace changes | Covered. Webhook, "validates literal bytes and inclusive freshness before decoding". |
| AC2 webhook | Inclusive freshness boundaries | Covered. Same literal-byte test. |
| AC2 webhook | Oversized declared and actual body | Covered. Webhook, "rejects ambiguous JSON, unsupported content types, and excessive bodies". |
| AC2 webhook | Chunked body continuation and elapsed read budget | Covered. Webhook, "authenticates literal bytes across body chunks" and "a body read timeout rejects before any receipt can be decoded". |
| AC2 webhook | Invalid and ambiguous JSON | Covered. Webhook, "validates literal bytes and inclusive freshness before decoding" and "rejects ambiguous JSON, unsupported content types, and excessive bodies". |
| AC2 webhook | Wrong installation | Covered. Workflow, "a signed request on an unconfigured installation creates no receipt". |
| AC2 webhook | Wrong account/inbox/conversation and conflicting fields | Covered. Webhook, "qualifies identity and keeps private, unsupported, and invalid senders out of reply work". |
| AC2 webhook | Invalid sender, private, system and unsupported attachment input | Covered. Same identity and sender test. |
| AC2 webhook | Signed human fences before job | Covered. Workflow, "signed human receipt fences before its job and rolls back on enqueue failure". |
| AC2 webhook | Wrong human shape cannot fence | Covered. Same signed human test. |
| AC2 webhook | Failed enqueue rolls back human inhibit | Covered. Same signed human test. |
| AC2 webhook | Concurrent duplicate | Covered. Workflow, "concurrent deliveries of the same signed receipt register one event and one job". |
| AC2 webhook | Oban insert rejection and retry after rollback | Covered. Ingress, "failed enqueue rolls back its receipt and a later attempt can register". |
| AC2 webhook | Replay preserves deadline and counters | Covered. Workflow, "a signed replay after admission leaves its run deadline and charges unchanged". Ingress, "a repeated signed receipt keeps the initial timestamp and durable job". |
| AC2 webhook | Distinct non-message observations do not initiate reply | Covered. Webhook, "oversized text is triage and status observations never become customer input". |
| AC2 webhook | Lost event | Covered. Delivery recovery, "verified history suppresses a reply if a newer input's webhook was missed". |
| AC2 webhook | Out-of-order event recovery | Covered. Workflow, "an out-of-order receipt is batched by verified history without moving the hard cutoff". |
| AC2 admission | Actual lock wait crosses 45 seconds for a fixed reply | Covered. Workflow, "a contended session lock cannot admit an overdue fixed_reply decision". |
| AC2 admission | Actual lock wait crosses 45 seconds for handoff policy | Covered. Workflow, "a contended session lock cannot admit an overdue handoff decision". |
| AC2 admission | Concurrent 10/minute reservation and rollover | Covered. Admission, "contact_minute serializes concurrent reservations and permits the next window". This is a counter-layer test. |
| AC2 admission | Concurrent 60/hour reservation and rollover | Covered. Admission, "contact_hour serializes concurrent reservations and permits the next window". This is a counter-layer test. |
| AC2 admission | Shared 40/day contact allowance, separate conversations | Covered. Admission, "contact daily quota follows a contact across conversations and preserves operator access". |
| AC2 admission | Preserved staff access at quota | Covered. Same daily quota test. |
| AC2 admission | Queue cap | Covered. Admission, "100 waiting receipts cap pre-admission work before it can become queued runs". |
| AC2 admission | Five globally running support runs | Covered. Admission, "five distinct conversations can run while a sixth waits for global capacity". |
| AC2 admission | Fixture inbox cap, retry idempotence, no partial charges | Covered. Admission, "inbox_limit denies a distinct receipt without charging the other windows". |
| AC2 admission | Fixture global cap, retry idempotence, no partial charges | Covered. Admission, "global_limit denies a distinct receipt without charging the other windows". |
| AC2 admission | Oversize input | Covered. Workflow, "oversize input is stored as triage with no work or text". |
| AC2 admission | Bounded debounce and hard cutoff | Covered. Workflow, "an out-of-order receipt is batched by verified history without moving the hard cutoff". |
| AC2 admission | Late input coverage and inherited deadline | Covered. Workflow, "late input transfers coverage on the original deadline and preserves completed history". |
| AC2 admission | Concurrent claim and stale run generation | Covered. Workflow, "two jobs cannot claim one run and the expired generation cannot complete it" and "PostgreSQL rejects a second active run for the same session". |
| AC2 admission | Independent work in distinct conversations | Covered. Admission, "five distinct conversations can run while a sixth waits for global capacity". |
| AC2 admission | Cancel completed run's pending intent without mutating history | Covered. Workflow, "late input transfers coverage on the original deadline and preserves completed history". |
| AC2 admission | Reopen with new generation, inherited inhibit and UNKNOWN | Covered. Workflow, "reopening inherits human inhibit and unresolved delivery across generations". The persisted UNKNOWN and zero new runs are asserted. |
| AC2 admission | Pending without verified bot assignment | Covered. Workflow, "an unassigned pending conversation never admits a run". |
| AC2 admission | Stale or missing eligibility | Covered. Workflow, "an unassigned pending conversation never admits a run". Delivery recovery, "a restored control cannot authorize a handoff claimed under its old epoch". |
| AC2 admission | Explicit return, no replay | Covered. Workflow, "explicit return requires a verified assignment and does not replay prior work". |
| AC2 admission | Qualified resolution and zero reopen writes | Covered. Delivery recovery, "handoff preflight with %{status: :resolved} issues no write" and "a resolved observation after handoff POST closes locally and preserves uncertainty". |
| AC2 admission | Disable then re-enable without public replay | Covered. Workflow, "restoring global control cannot replay a pending public reply". |
| AC2 admission | Binding circuit and one half-open probe | Covered for immediate auth failure, consecutive transient failures, one half-open read, and re-opening on failed probe. Delivery recovery, "a binding auth failure inhibits writes until a successful read-only probe" and "five consecutive transient failures open the binding and a failed probe keeps it open". A second configured binding is outside the fixture setup. |
| AC2–3 | Current checks before claim and between claim and dispatch | Covered. Delivery recovery, "disabling the global epoch during preflight cancels the write" and "a restored control cannot authorize a handoff claimed under its old epoch". |
| AC2–3 | Crash before authorization | Covered. Delivery recovery, "a worker lost before authorization can be recovered by sweep after losing its expiry jobs". |
| AC2–3 | Crash after authorization, before POST | Covered. Delivery recovery, "a worker lost after authorization and before POST stays unknown". |
| AC2–3 | Crash during POST before remote commit | Covered. Delivery recovery, "killing a worker at chatwoot_before_commit keeps an authorized attempt uncertain". |
| AC2–3 | Crash after remote commit, before local settlement | Covered. Delivery recovery, "killing a worker at chatwoot_write keeps an authorized attempt uncertain". |
| AC2–3 | Timeout | Covered. Delivery recovery, "timeout after adapter entry leaves one ambiguous attempt". |
| AC2–3 | Reset | Covered. Delivery recovery, "reset after adapter entry leaves one ambiguous attempt". |
| AC2–3 | 5xx | Covered. Delivery recovery, "server_error after adapter entry leaves one ambiguous attempt". |
| AC2–3 | Redirect | Covered against the fake. Delivery recovery, "redirect after adapter entry leaves one ambiguous attempt". |
| AC2–3 | Malformed success | Covered. Delivery recovery, "malformed_success after adapter entry leaves one ambiguous attempt". |
| AC2–3 | 403 | Covered. Delivery recovery, "forbidden after adapter entry leaves one ambiguous attempt". |
| AC2–3 | Expired writer resumes after recovery | Covered. Delivery recovery, "sweep fences an expired worker even while its write callback is blocked". |
| AC2–3 | Expired writer resumes before recovery | Covered. Delivery recovery, "an expired writer cannot settle even before recovery starts". |
| AC2–3 | Late write result and stale read reservation cannot settle | Covered. Delivery recovery, "sweep fences an expired worker even while its write callback is blocked" and "an earlier successful read cannot settle after a newer reservation". |
| AC2–3 | Discarded job, expired lease, worker restart, lost expiry and bounded sweep | Covered. Delivery recovery, "a worker lost before authorization can be recovered by sweep after losing its expiry jobs", and Workflow, "the recovery sweep requeues at most 25 stranded receipts per pass". |
| AC2–3 | Replay jobs and new input while UNKNOWN | Covered. Delivery recovery, "a committed remote write with a lost response remains unknown until qualified read-back" and "unknown blocks a new input and abandonment requires an audited operator decision". |
| AC2–3 | Replay receipt while UNKNOWN | Covered. Delivery recovery, "unknown blocks a new input and abandonment requires an audited operator decision". |
| AC2–3 | Qualified positive read-back | Covered. Delivery recovery, "a committed remote write with a lost response remains unknown until qualified read-back". |
| AC2–3 | Read-back wrong destination | Covered. Delivery recovery, "destination cannot prove acceptance on read-back". |
| AC2–3 | Read-back wrong sender | Covered. Delivery recovery, "sender cannot prove acceptance on read-back". |
| AC2–3 | Read-back wrong visibility | Covered. Delivery recovery, "visibility cannot prove acceptance on read-back". |
| AC2–3 | Read-back equal text only | Covered. Delivery recovery, "equal_text cannot prove acceptance on read-back". |
| AC2–3 | Definitive unissued failure vs absent acceptance | Covered. Delivery recovery, "qualified no-effect before dispatch differs from an absent read-back" and the crash before simulated commit case. |
| AC2–3 | Authorized abandonment, audit, unauthorized closure | Covered. Delivery recovery, "unknown blocks a new input and abandonment requires an audited operator decision". |
| AC2–3 | Abandonment races with qualified read-back | Covered. Delivery recovery, "abandonment wins over an in-flight successful read-back". |
| AC2–3 | Handoff failure after three reads | Covered. Delivery recovery, "a handoff exhausts three unavailable reads and stays inhibited". |
| AC2–3 | Handoff expiry after five minutes, no further read | Covered. Delivery recovery, "handoff past its five-minute deadline is triaged without another read". |
| AC2–3 | Already human-routed handoff, no write | Covered. Delivery recovery, "handoff preflight with %{status: :open, assignee: :human} issues no write". |
| AC2–3 | Wrong routing or assignment | Covered. Delivery recovery, "handoff preflight with %{team: 987} issues no write" and "handoff preflight with %{assignee: :unassigned} issues no write". |
| AC2–3 | Qualified resolution before and after POST | Covered. Delivery recovery, "handoff preflight with %{status: :resolved} issues no write" and "a resolved observation after handoff POST closes locally and preserves uncertainty". |
| AC2–3 | Alert and triage output contains internal references and safe reasons only | Covered for local telemetry, durable triage and operator output. Delivery recovery, "an ambiguous write emits one alert with only internal references and a safe reason" and "the operator projection exposes only internal intent references and safe reasons". |
| AC2–3 | Req transport permits one attempt across retry/redirect/timeout paths | Staging-only. F07/VGAS-8. |


## Reviewer mutations

Each mutant ran separately in a disposable checkout with the applicable test file and `--seed 0` through `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test`. Exit 2 below denotes an observed behavioral assertion failure. The database mutants dropped a single guard only inside the test transaction, rolled back even on erroneous acceptance, restored the original test, and reran it. The earlier mutation pass is superseded where repeated suites spent the same global TEST rate window. The fixtures now use a separate synthetic global window key per scenario.

| Guard removed or changed | Result | Assertion that rejected the change |
| --- | --- | --- |
| Literal HMAC verification | Killed, exit 2 | A whitespace change must return 401. |
| Configured account and inbox qualification | Killed, exit 2 | A signed payload for another account must return 403. |
| Receipt dedupe lookup | Killed, exit 2 | The replay must return the original receipt ID. |
| Transactional enqueue, deferred until after receipt commit | Killed, exit 2 | A second backend must see zero receipts while the insert waits. |
| Human inhibit inside T01, moved before the receipt transaction | Killed, exit 2 | A failed job insert must leave the existing inhibit false. |
| Current staff session generation | Killed, exit 2 | A forged stale generation must be denied. |
| Current ownership and policy epoch | Killed, exit 2 | A handoff claimed before disable/re-enable must have zero attempts. |
| Composite assistant ownership FK | Killed, exit 2. | The cross-assistant active revision must raise a foreign-key violation. |
| One-active-run index | Killed, exit 2. | A second active run must violate `support_runs_one_active`. |
| Sticky human history across session generations | Killed, exit 2 | The reopened generation must persist the inherited inhibit. |
| Resolved preflight guard | Killed, exit 2 | A qualified resolved handoff must persist the resolved disposition. |
| Sample time before the contended lock | Killed, exit 2 | Both fixed-reply and handoff policies must record overdue triage. |
| Counter comparison off by one | Killed, exit 2 | An exhausted counter must reject a further reservation. |
| Charge counters before checking all windows | Killed, exit 2 | Denial must leave the other windows available and uncharged. |
| Reset deadline on regroup | Killed, exit 2 | The successor deadline must equal the original deadline. |
| Drop one covered predecessor input | Killed, exit 2 | Both input references must belong to the successor. |
| Dispatch state and claim token | Killed, exit 2 | A stale worker must produce zero writes before the replacement resumes. |
| Dispatch lease margin | Killed, exit 2 | A still-live but insufficient lease must cancel before authorization. |
| Recover an authorized write to PENDING | Killed, exit 2 | Each possible dispatch must recover to UNKNOWN with one spent attempt. |
| Late settlement fence | Killed, exit 2 | An expired or recovered writer cannot overwrite UNKNOWN. |
| Qualified reconciliation destination | Killed, exit 2 | The wrong conversation cannot settle the intent. |
| UNKNOWN admission block | Killed, exit 2 | New input must remain in operator triage. |
| Reconciliation deadline | Killed, exit 2 | Expiry must preserve UNKNOWN without reserving a read. |
| Reconciliation read sequence | Killed, exit 2 | An earlier positive response cannot settle after a newer reservation. |
| Cron sweep delivery coverage | Killed, exit 2 | The bounded sweep must recover a stranded delivery after its jobs are lost. |
| Manual closure audit | Killed, exit 2 | ABANDONED must have an audit row with the operator event and reason. |
| Req single-attempt bound | Staging-only under A-010. | The isolated transport must reject a second wire attempt. |

The 24-source-mutant pass used implementation commit `cf599aa`. Its restored focused selection passed 73 tests, exit 0. Later changes added evidence for remaining cases and a post-commit local telemetry report. The two PostgreSQL mutations and their restored 30-test selection ran at `559eb1c`. That selection exited 0. The final application candidate also received the full and focused runs below.

## Verification commands

Application candidate `5d66c15`. The verification document is a separate commit.

| Command | Exit | Observed result |
| --- | --- | --- |
| `git fetch origin` | 0 | Confirmed `origin/main` at `24453be` and PR B at `59fce6c`. |
| `git switch feat/vgas-002b-signed-flow` | 128 | The branch was checked out in another worktree. |
| `git merge --ff-only origin/feat/vgas-002b-signed-flow` | 0 | Advanced the assigned isolated branch to `59fce6c`. |
| `devcore-project plan` | 0 | Reported the project allocations. |
| `devcore-project activate` | 0 | Rendered this checkout's ignored local environment. |
| `devcore-project doctor` | 0 | Confirmed PG18 reachability and authentication on both assigned ports. All ExUnit work ran on TEST. |
| `mise exec -- mix deps.get --check-locked` | 0 | Resolved the locked dependencies. |
| `mise exec -- mix hex.audit` | 0 | No retired or security-advisory packages reported. |
| `mise exec -- mix format --check-formatted` | 0 | Passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/support --seed 0` | 0 | 91 passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/support --seed 103` | 0 | 91 passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --seed 0` | 0 | 336 passed, 5 skipped, 2 excluded. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --seed 103` | 0 | 336 passed, 5 skipped, 2 excluded. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix compile --warnings-as-errors` | 0 | Passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ash.codegen --check` | 0 | Generated snapshot check passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | 0 | Passed in DevCore TEST. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrations` | 0 | Nine migrations up. |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact --log-opts=24453be..HEAD` | 0 | Eight commits scanned. No leaks found. |
| `python3 .github/scripts/plan_tests.py` | 0 | Generated eight test shards. |
| `git diff --check 24453be..HEAD` | 0 | No whitespace errors. |
| `git diff --exit-code 24453be..HEAD -- mix.exs mix.lock` | 0 | No dependency manifest or lockfile diff. |
| `PORT=4189 devcore-project run dev -- env -u OPENAI_API_KEY mise exec -- mix phx.server` | 0 | Started on loopback. Stopped after the health check. |
| `curl --fail -sS -o /dev/null -w 'HTTP %{http_code}\\n' http://127.0.0.1:4189/health` | 0 | HTTP 200. |
| `ss -ltn '( sport = :4189 or sport = :55434 )'` | 0 | Ports 4189 and 55434 were free after cleanup. |

Rehearsals used a self-cleaning PostgreSQL 18/pgvector container on loopback 55434 and generated credentials. Each Mix invocation exited 0. The rehearsal wrapper also exited 0.

| Rehearsal | Exact Mix commands | Observed result |
| --- | --- | --- |
| Fresh | `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | Nine migrations applied. The vector extension was present. |
| PR A upgrade | `MIX_ENV=test mise exec -- mix ecto.migrate --migrations-path "$tmp/base/priv/repo/migrations" --strict-version-order`, then `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | Loaded the `24453be` migrations, seeded staff/audit plus assistant/binding rows, and preserved the qualified assistant/binding join. |
| Rollback and reapply | `MIX_ENV=test mise exec -- mix ecto.rollback --to 20261125230109`, then `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | Reversed and reapplied all PR B migrations. |

The five skips belong to the disposable F04 knowledge tests. The two excluded tests require the pgvector and seeded predecessor CI flags. The migration rehearsal separately checked the extension and seeded upgrade. CI and deployment files stayed outside this pass. Actionlint and Compose validation did not apply. The first migration-upgrade rehearsal exited 3 on the synthetic seed's column name. The second exited 3 on the seed's missing disabled timestamp. Both were fixed in the disposable fixture. A concurrent exploratory suite hit the shared TEST fixture's staff bootstrap and rate window. Final suites ran serially with isolated synthetic global counters. The unversioned Gitleaks shim exited 1. The installed version was selected explicitly for the final scan.

## Remaining authority and evidence

- A-010 moves live Chatwoot and Req wire-attempt evidence to F07/VGAS-8. The real adapter remains unavailable, and the local circuit thresholds are synthetic defaults. The owner still controls staging credentials, routing, approved limits and alert destinations.
- The initial PR B pass recorded local alert telemetry and manual abandonment audit. The follow-up below adds the system audit and read projection required by plan §3.
- Review and CI for the pushed candidate remain the responsibility of the PR orchestrator and independent reviewer.

## PR B system audit follow-up

The follow-up starts at PR B head `3fbb38578990031ea0c9f8155d7801853a08630a` and closes the automatic audit and read projection requirement in plan §3. The application commit is `275e71404fd26b36d0ad793658ec26f18846a0f0`. Migration `20261126000420_vgas_002_system_audit.exs` and snapshot `20261126000421.json` add restricted receipt and run references and retain the existing delivery reference. The audit treats `support_worker` as a code-owned actor. It records the event and a closed reason code separately.

`AuditEvent.system_history` returns up to 100 facts for one internal target. It rechecks the current staff operator or admin role, or compares the Reconciliation actor's exact target and inbox with the qualified record. The projection includes the internal audit, target and correlation IDs, event, actor kind, reason and timestamp.

### PostgreSQL cases and mutations

- Six ambiguous adapter results and recovery after worker loss each produce one `delivery_unknown` fact. Delivery retries preserve the original fact and the spent attempt.
- Overdue receipt triage under a contended lock and overdue run recovery record `missed_deadline` against their respective targets. Reprocessing records no duplicate.
- Read exhaustion, pending handoff expiry and expiry of a claimed but undispatched handoff each record `handoff_failed`. An expired handoff already in UNKNOWN records the failure while retaining its original uncertainty.
- Forced append failures leave receipt triage uncommitted, handoff pending, and a possibly dispatched write in SENDING with its committed dispatch marker. Recovery can then record the fact.
- Tests check projection fields, current staff and reconciliation access, denial of raw storage calls inside a real transaction, actor-kind validation and the PostgreSQL actor reference constraint. The VGAS-001 audit action and staff lifecycle checks also run.

The tests were added before implementation. The original head failed the new deadline and UNKNOWN assertions with exit 2. A separate red run for expiry of a claimed handoff also exited 2 on the missing fact. Each mutation was applied separately and restored. The five commands below use `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test <selection> --seed 0`.

| Mutation | Selection | Exit and failing assertion |
| --- | --- | --- |
| Omit UNKNOWN append | `test/voelgoed_ai/support/delivery_recovery_test.exs:50` | 2. All six ambiguous-result tests expect one delivery fact. |
| Omit missed-deadline append | `test/voelgoed_ai/support/workflow_test.exs:358` | 2. Recovery retries must leave one run deadline fact. |
| Omit handoff-failure append | `test/voelgoed_ai/support/delivery_recovery_test.exs:312` | 2. Five-minute expiry must leave a handoff failure fact. |
| Move UNKNOWN append after transaction commit | `test/voelgoed_ai/support/delivery_recovery_test.exs:67` | 2. Append failure must leave the authorized row in SENDING. |
| Drop the append actor-kind validation | `test/voelgoed_ai/support/delivery_recovery_test.exs:91` | 2. The system append changeset must reject a staff actor kind. |

### Local command results

| Command | Exit | Result |
| --- | --- | --- |
| `git fetch origin` | 0 | Read base `24453be` and initial PR head `3fbb385`. |
| `git merge --ff-only origin/feat/vgas-002b-signed-flow` | 0 | Used this isolated branch because the PR branch was checked out in another worktree. |
| `devcore-project plan`, `devcore-project activate`, `devcore-project doctor` | 0 each | Confirmed PG18 and DevCore TEST on 55433. |
| `mise exec -- mix deps.get --check-locked` | 0 | Resolved the locked dependencies. |
| `mise exec -- mix hex.audit` | 0 | No retired or security advisory packages reported. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ash.codegen vgas_002_system_audit` | 0 | Generated one migration and one snapshot. |
| `mise exec -- mix format --check-formatted` | 0 | Formatting passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix compile --warnings-as-errors` | 0 | Compilation passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ash.codegen --check` | 0 | Resource snapshots matched. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | 0 | Migration order check passed in TEST. |
| `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrations` | 0 | All ten migrations were up. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/support --seed 0` | 0 | Focused suite passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/support --seed 103` | 0 | 98 passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --seed 0` | 0 | Full suite passed. |
| `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --seed 103` | 0 | 345 passed, 5 skipped, 2 excluded. |
| `python3 .github/scripts/plan_tests.py` | 0 | Generated eight shards. |
| `git diff --check 24453be..HEAD` | 0 | Full PR diff passed the whitespace check. |
| `git diff --exit-code 24453be..HEAD -- mix.exs mix.lock` | 0 | Both dependency files match the base. |
| `rg -n 'authorize\?: false' lib` | 1 | No matches. |
| `PORT=4190 devcore-project run dev -- env -u OPENAI_API_KEY mise exec -- mix phx.server` | 143 after SIGTERM | Server started and was stopped after the health check. |
| `curl --fail -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:4190/health` | 0 | HTTP 200. |
| `ss -ltn '( sport = :4190 or sport = :55434 )'` | 0 | Both ports were free after cleanup. |

The first follow-up test runs exited 2. The handoff fixture initially confirmed the remote goal, which bypassed the expiry path. The full suites also exposed two legacy tests that enumerate all audit actions. The fixture and both action inventories were updated. Earlier focused retries had intermittent fixture failures. The final suites ran serially on DevCore TEST.

Rehearsals used a temporary PostgreSQL 18 container with pgvector on loopback port 55434. They created the vector extension in the fresh database, verified it, and used generated credentials. The upgrade used `git archive 24453be priv/repo/migrations` and seeded one VGAS-001 staff-security fact and one PR A configuration fact. Both facts survived upgrade, rollback and reapply. The final rehearsal wrapper exited 0.

| Rehearsal command | Exit |
| --- | --- |
| Fresh `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | 0 |
| `MIX_ENV=test mise exec -- mix ecto.migrate --migrations-path "$d/base/priv/repo/migrations" --strict-version-order` | 0 |
| Upgrade `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | 0 |
| `MIX_ENV=test mise exec -- mix ecto.rollback --step 1` | 0 |
| Reapply `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order` | 0 |

The first fresh rehearsal omitted the CI vector extension setup and stopped at the extension probe with exit 1. Two upgrade rehearsal attempts stopped at the synthetic seed with exit 3. The final seed supplies the required assistant audience. The rollback rehearsal used historical staff and configuration facts only. Once the new system facts exist, the predecessor audit constraints prevent a schema rollback that would discard those facts.

F07/VGAS-8 still owns live Chatwoot and wire-attempt evidence. GitHub Actions and independent review must evaluate the pushed PR head.

## PR B independent review fixes

VGAS-13 review follow-up. The base was `24453be`. The implementation started
at `4bfa5eb`, which includes the audit follow-up to the reviewed `3fbb385`.
The code and tests are in `9773cad`.

### Findings and regression evidence

- **Cross-generation abandonment.** Closure records the human inhibit when a
  PENDING, SENDING or UNKNOWN delivery still exists. Abandonment locks the
  source session and then the latest qualified generation before locking any
  target rows. It applies human takeover and writes the operator audit in the
  same transaction as abandonment. The resolved-closure and operator-closure
  tests cover inheritance, triage before and after abandonment, and explicit
  return. The legacy-generation test proves the earlier UNKNOWN hold and
  takeover of an already active successor.
- **Storage authority.** WorkStore requires a private local function capture
  bound to the allowlisted orchestration module and action. It checks that
  authority at minting and again when authorizing the Ash action. The operator
  capability and staff audit remain inside `StaffAccess.with_current`. The
  untrusted-caller test tries both direct minting and a forged Ash actor.
- **Transitions.** Actions validate the persisted source state under the
  workflow's row lock. They set the destination state and accept only the
  transition's inputs. Reconciliation records read exhaustion without changing
  UNKNOWN. The Ash regression exercises all four resource types, a previously
  authorized retry, and rejected state and attempt-count inputs. The
  `20261126000422` migration rejects changes out of terminal run and delivery
  states even through SQL. Its rollback removes only the guards.
- **Authorized send fence.** The signed human takeover and resolved-observation
  tests pause after authorization and resume the worker after fencing. Each
  leaves UNKNOWN with one authorized attempt and zero wire writes. The final
  dispatch check reads current local permission before calling the adapter.
  A remote ownership or resolution race remains possible after that check.
- **Time and concurrency.** The return test changes only the ownership epoch
  while the adapter read is blocked. The session timing test proves PostgreSQL
  lock contention before advancing the fake clock. The admission test changes
  the SQL session time zone and verifies the same UTC window. The run capacity
  test observes the sixth connection waiting on the singleton control lock
  while five runs are active. That lock already covers the count and claim.
  Ingress uses the adapter clock for ignored and oversize dispositions.
- **Id-less signed replay.** The endpoint hashes the signed timestamp and body
  digest under a dedicated prefix. It stores only the final digest in the
  existing qualified index. The replay test proves one receipt and one job for
  byte-identical retransmission with the same signature timestamp. A separately
  signed observation still reconciles current state. The digest is an envelope
  replay key. It supplies no provider event identity or ordering.

### Mutation evidence

Each code mutant ran on a disposable copy. The command was
`devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test FILE:LINE --seed 0`.
Each run exited 2 on the assertion below. The changes were reverted in the
copy after each run.

- M2, `delivery_recovery_test.exs`, signed human takeover. The state assertion
  expected UNKNOWN after the authorized send was fenced.
- M5, `workflow_test.exs`, locked-session clock. The returned timestamp
  preceded the fake clock advance during the lock wait.
- M7, `workflow_test.exs`, changed return epoch. The return succeeded where
  the test required `:scope_denied`.
- M9, `delivery_recovery_test.exs`, legacy reopened generation. The input was
  covered where the test required triage with `:awaiting_operator`.
- M11, the same legacy-generation test. The next input was covered after
  abandonment where the test required triage with `:scope_denied`.
- MED2 mint check, `delivery_recovery_test.exs`, untrusted caller. The direct
  storage call reached Ash where the test required denial at minting.
- MED2 policy check, the same untrusted-caller test. Ash accepted a forged
  actor where the test required `Ash.Error.Forbidden`.
- MED3 source-state guard, `delivery_recovery_test.exs`, Ash action guards.
  The SENT abandonment changeset lacked its rejection.
- MED3 no-dispatch retry guard, the same Ash test. The authorized SENDING
  retry changeset lacked its rejection.
- MED3 destination-state change, the same Ash test. The legal abandonment
  changeset left the state UNKNOWN.
- MED3 accepted fields, the same Ash test. The abandonment changeset accepted
  an attempt-count change.
- MED3 PostgreSQL triggers. On disposable PG18, the terminal UPDATE for each
  table exited 1 in `psql` with its trigger enabled. Disabling that one trigger
  inside a transaction let the identical UPDATE exit 0. Each transaction
  rolled back. The unmodified ExUnit test requires both constraint names.

### Local command results

The following commands exited 0 unless noted. Mix output was captured in
temporary logs and removed after summarizing.

- `git fetch origin`, `git merge --ff-only origin/feat/vgas-002b-signed-flow`.
  The named branch was in use in another worktree. This isolated branch tracked
  its remote ref.
- `devcore-project plan`, `devcore-project activate`, `devcore-project doctor`.
- Separate `mise exec -- mix deps.get --check-locked` and
  `mise exec -- mix hex.audit` invocations. Hex reported no retired or
  advisory packages.
- `mise exec -- mix format --check-formatted`.
- `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix compile --warnings-as-errors`.
- `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ash.codegen --check`.
- `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order`.
- `devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix ecto.migrations`.
  Migration `20261126000422` was up.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/support --seed 0`
  and the same command with `--seed 103`. 110 passed on each seed.
- `devcore-project run test -- env -u OPENAI_API_KEY mise exec -- mix test --seed 0`
  and the same command with `--seed 103`. 357 passed, 5 skipped and 2 excluded on each seed.
- `python3 .github/scripts/plan_tests.py` emitted eight shards.
- `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='24453be..HEAD'`
  reported no leaks.
- `git diff --check 24453be..HEAD`.
- `git diff --exit-code 24453be..HEAD -- mix.exs mix.lock`.
- `rg -n 'authorize\?: false' lib` exited 1 with no matches.
- `PORT=4191 devcore-project run dev -- env -u OPENAI_API_KEY mise exec -- mix phx.server`.
  `curl --fail -sS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:4191/health`
  returned HTTP 200. The server exited 143 on SIGTERM.
- `ss -ltn '( sport = :4191 or sport = :55434 )'` showed no listeners.

Disposable PG18/pgvector rehearsals on 55434 exited 0 for each command:

1. Fresh `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order`.
   Verified pgvector and both terminal-state triggers.
2. Predecessor `MIX_ENV=test mise exec -- mix ecto.migrate --migrations-path
   "$scratch/priv/repo/migrations" --strict-version-order` from a
   `git archive 24453be priv/repo/migrations` export. Seeded the PR A
   assistant and binding plus the VGAS-001 staff audit fixture.
3. Upgrade `MIX_ENV=test mise exec -- mix ecto.migrate --strict-version-order`,
   rollback `MIX_ENV=test mise exec -- mix ecto.rollback --step 1`, and reapply
   with the strict-order migration command. The fixtures survived each step.
   Both triggers disappeared on rollback and returned on reapply.

### Follow-ups

The circuit's read-only probe still cancels the handoff intent that triggered
it. The operator's manual recovery path remains available. Retry or intent
replacement after a probe needs a separate recovery decision. Sweep can
enqueue another Deliver job while one is available. The one-attempt rule
and durable claim still prevent another POST. The shared staff bootstrap can
cascade after a failed fixture cleanup. The final suites used serial
execution on DevCore TEST.

F07 and isolated real inbox validation remain open. This follow-up used the
fake adapter and carries no staging or exact-head independent review evidence.

## Review 2 test gaps

Review 2 of `2c1f834` requested changes for one test gap: the system history target filter had no test, and a mutant that removed it passed 144 tests. It also reported three LOW gaps with no reachable runtime defect: the actor-kind filter on system history, WorkStore's per-action allowlist, and the original-state guards on `:authorize_dispatch`. This follow-up adds tests and changes no runtime behaviour.

- The system history test now creates a second UNKNOWN delivery in another conversation and abandons the first delivery as staff. History for the first delivery must still return only its own system row, to the operator and to the reconciliation scope.
- `WorkStore.owns?/3` now holds the allowlist lookup that `owned?/3` already used. A new test checks that each module owns only its listed actions: for example `Ingress` cannot `return_to_bot`, `Delivery` cannot `abandon`, and `Ownership` cannot append a staff audit row.
- The original-state test now covers `:authorize_dispatch` from PENDING and from an already authorized SENDING row.

| Mutant | Test | Result |
| --- | --- | --- |
| System history without target-id scoping | system history test | Killed, exit 2 |
| System history without the `actor_kind` filter | system history test | Killed, exit 2 |
| `owns?/3` ignores the action | storage ownership test | Killed, exit 2 |
| `:authorize_dispatch` without its state guard | original-state test | Killed, exit 2 |
| `:authorize_dispatch` without its dispatch guard | original-state test | Killed, exit 2 |

Each mutant ran alone with `--seed 0`, failed on an assertion rather than a compile error, and was reverted afterwards. On DevCore TEST, the delivery recovery file passed 55 tests. The full suite on seed 0 passed 358, with 5 skipped and 2 excluded. The webhook and support files on seed 103 passed 111. Format, compile with warnings as errors, `ash.codegen --check` and `git diff --check` exited 0.
