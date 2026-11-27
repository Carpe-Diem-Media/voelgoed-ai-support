# VGAS-15 PR C verification

The implementation starts at `e3192e491748749879d0bd118ad4a1f262f9cc65`,
tree `d91a7f5fc7a9fe05930081cf1e2e26d9af26ad6c`. The branch is
`well/vgas-15c-typed-ai-generation`. [The accepted plan](VGAS-15_PLAN.md)
governs T03 and T08 for generation under R4, R5, R8, R10 and R11.
The Plane ticket was In Progress when read. PR D owns worker composition
and semantic evaluation. The provider tests use synthetic inputs and a fake
Req adapter. [VGAS-15](https://app.plane.so/symphony-development/projects/8e7e9131-668d-4d99-8bd7-b5847d5f8c8c/issues/ed67676a-b6dd-45b8-85bf-757f3a17e1fd)

## Why Ash AI

The lockfile pins Ash AI 1.5.6, ReqLLM 1.31.0 and Req 0.7.5.
`deps/ash_ai/lib/ash_ai/actions/prompt.ex` wraps the configured response
schema in a one-key `result` object. It calls `generate_object/4` once
when tools are disabled. It extracts the object and casts it before forming
the action result. Missing or invalid output can therefore make usage
unavailable through the action result.

A private Ash action pins the prompt, locale, model and strict schema.
The pinned prompt's SHA-256 is
`2b6a3e7c579098ff36d8a14ba8edcc6f71d21c58cc5d49841ed325f795483859`.
The Req adapter's closure binds a single entry to the attempt, dispatch
fence and capture reference. The adapter extracts only bounded request
and response identifiers, the pinned model's integer token counts and
elapsed time before ReqLLM decodes the result. It checks the actual
`result` wrapper and proposal keys before accepting Ash's cast. Request
or result data never enter the ledger, job args or operational alert.

ReqLLM's `providers/openai/responses_api.ex` defaults to encrypted
reasoning inclusion for this model. The action explicitly passes
`include: []` and `store: false`. The fake boundary checks the final
strict schema, model, 500 output-token cap, locale and stateless request.
The paid-call controls set top-level `max_retries: 0` because
`step/retry.ex` prefers it over the nested limit. ReqLLM enforces the
total timeout from a separate task. The transport clamps its connect,
pool and receive timeouts to the remaining budget immediately before entry.
It forwards full response bodies only within the configured byte bound.
The pinned caller passed the raw-usage and invalid-result proof, so the
direct ReqLLM fallback was unnecessary.

## State and accounting evidence

- T03 qualifies the shadow claim under the existing support lock order.
  It inserts the attempt, reserves the full uncached input plus capped
  output ceiling of 525,375,000 nano-USD, and enqueues recovery in one
  transaction. This is a synthetic profile using the VGAS-18B rates.
  The cap includes the full 1,050,000-token context to account for schema
  and message overhead. The runtime support worker has no generation caller.
- A second transaction checks the current claim and reservation before
  consuming the original fence. The Req fake observes an independently
  committed marker and PostgreSQL reports the caller's checked-out backend
  as idle, with `xact_start IS NULL`, while the adapter is parked.
- The eligible successor retains the original turn reference and can use
  slot 2 after a known outcome in slot 1. The database enforces qualified
  run lineage, slots 1 and 2, and uniqueness across the lineage. An ambiguous
  predecessor blocks a successor call. Held spend also counts against a
  different turn in a new UTC day and month.
- Recovery rechecks expiry after the row lock. It releases the reservation
  if the marker never committed and holds it if the marker committed.
  The marker-to-wire interval remains ambiguous after a process failure.
  If the process dies before T08 commits, captured usage can be lost.
  Scheduled recovery retains the full hold for later reconciliation.
- Trusted usage bills 10 input plus 5 output tokens at 8,750 nano-USD,
  including the 2 reasoning tokens already in output. Invalid typed output,
  refusal and truncation settle trustworthy usage without yielding a proposal.
  Missing usage, wrong model, missing correlation, malformed JSON, 503 and
  timeout leave the full hold. Over-ceiling actuals inhibit future generation
  and emit an alert with internal identifiers and a typed reason.
- Late usage is financial only. If an authorized synthetic staff closure
  already charged the ceiling, the ledger preserves the original settlement
  and appends one linked correction for -525,366,250 nano-USD. Recovery and
  correction leave the support turn and its Chatwoot state alone.

## Rollback and merge criteria

Disable automation or the affected binding through the existing permission
epoch. Keep the recovery worker, migrations, reservation and ledger rows
available to reconcile attempts. A valid provider response after cutoff or
authority loss can settle spend and cannot yield a proposal through the
stale claim. Keep UNKNOWN holds unless trustworthy usage arrives or an
authorized operator closes at the ceiling. Never replay a consumed fence.
The down migration is for predecessor-format data. Once generation rows
exist, retain the additive schema and use a forward-compatible disable or fix.

The orchestrator must obtain independent review of the exact base and head,
resolve findings and confirm required exact-head CI before merge. Paid
inference and Chatwoot writes require separate owner authorization.

## Local commands and results

Mise used Erlang 29.1.2 and Elixir 1.20.5-otp-29. Database commands
ran through the approved disposable runner on PostgreSQL 18.7 with
pgvector 0.8.7. Port 55435 was used for focused, upgrade and mutation
runs. Port 55434 was used for full runs. Each invocation started with
a free port and removed its own container and volume.

```sh
ss -ltn '( sport = :55434 or sport = :55435 )'
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$vgas_worktree" "$vgas_steps" "$vgas_port"
```

These commands exited 0 unless noted. TEST compile used forced
recompilation at both `+S 1` and `+S 2`.

```sh
HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked
mise exec -- mix deps.unlock --check-unused
mise exec -- mix format --check-formatted
ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
mise exec -- mix ash.codegen --check
bash .github/scripts/verify_postgres.sh 180007
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix ecto.migrations
python3 .github/scripts/plan_tests.py
git diff --check
```

The separate `mise exec -- mix hex.audit` invocation exited 0 with no
retired packages or security advisories. There is no dependency or
Compose diff. The non-TEST comparison used
`MIX_ENV=dev HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors`
and repeated with `+S 2`. Both builds exited 1 on the same 17 application
warning locations in the exact base and candidate. VGAS-19 owns those
warnings. In a separate `devcore-project run dev -- mix run --no-start`
probe, the DEV module had no `with_fixture/4` export and the actual
Ash prompt action rejected a forged generation actor.

The focused tests ran as follows.

```sh
mise exec -- mix test test/voelgoed_ai/intelligence/generation_test.exs --seed 0
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs test/voelgoed_ai/governance/embedding_accounting_test.exs --seed 0
```

The generation file passed 27 cases. Editorial and accounting passed 41
cases. Their synthetic reserve-commit failure log is expected. An earlier
full run caught a regression for a missing embedding price. Restoring
validation before accessing its fields fixed the regression in the 41-case
run. An intermediate full run also failed the new locale assertion while
the code and test were changing. The final focused run loaded the
matched code and tests.

### Populated upgrade and rollback

The fixture [vgas_15c_predecessor.sql](../../test/support/fixtures/vgas_15c_predecessor.sql)
installed 14 observed rows across control, runs, delivery, knowledge,
attempts, reservations, ledger and spend windows. The settled article
attempt and UNKNOWN query attempt use the predecessor accounting fields.
The candidate migration adds nullable generation fields and a default-false
generation inhibit. It preserves the existing query foreign key.

The base migrations came from `git archive e3192e491748749879d0bd118ad4a1f262f9cc65 priv/repo/migrations`.
The fixture ran with `psql -XqAt -v ON_ERROR_STOP=1 -f` as the disposable
TEST role. The ordered `to_jsonb` projections omit only the new columns.
The following commands and both byte comparisons exited 0.

```sh
mise exec -- mix ecto.migrate --migrations-path "$vgas_base_migrations" --strict-version-order
mise exec -- mix ecto.migrate --strict-version-order
cmp "$vgas_before" "$vgas_after"
mise exec -- mix ecto.rollback --step 1
cmp "$vgas_before" "$vgas_rolled_back"
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0
```

Foundation tests passed 6 cases with the predecessor-only test excluded.
The candidate's migration and five snapshots came from
`mix ash.codegen vgas_15c_generation_accounting`. Fresh migration and
snapshot consistency passed. The predecessor migration fixture needed the
existing author and owner fields before it could seed. The final populated
comparison ran after both fixture corrections.

### Mutation checks

The isolated candidate used one modified guard per run. Each test ran
with `mise exec -- mix test test/voelgoed_ai/intelligence/generation_test.exs:<line> --seed 0`
on a fresh disposable database, then the original source was restored.
The baseline's adapter observes an effective retry limit of 0.

- Line 120. Restoring top-level retries to 3 failed all ten transport
  cases at the final adapter option assertion. The latch continued to
  prevent another wire entry even with the regressed retry setting.
- Line 164. Releasing a consumed reservation left a RELEASED reservation
  where the test required an UNKNOWN hold.
- Line 223. Returning typed output from a recovered UNKNOWN attempt
  yielded the proposal after the support claim's clock was restored.
- Line 257. Reallocating slot 1 on a successor prevented a qualified
  second call. The database's unique turn-slot index blocked the reset.
- Line 238. Skipping the post-lock deadline recheck moved a still-current
  RUNNING attempt to UNKNOWN after a clock correction.
- Line 373. Removing the adapter latch let a second invocation return a
  response where the test required a transport denial.
- Line 484. Removing the generation lineage foreign key let a generation
  attempt change to a turn outside its owning run.
- Line 211. Holding an actual caller transaction around
  `ReqLLM.generate_object/4` after the action policy check let the adapter
  enter. The independent connection observed `false, "idle in transaction"`
  where the test required `true, "idle"`.

Each intentional failure exited 2. The transaction proof uses a query
inside the injected transaction to make the caller's state observable.

The foundation-only Application CI upgrade lane used the immutable file
from `aa93104fd476d208206288658e67bfe70e0780cd`. It finished with all
migrations up and 6 passing foundation cases. The VGAS-001 upgrade lane
compared and installed the two immutable migrations from
`92ef0e39a7808d4ffa692b37b48ba3ee27a05e30` and applied
`.github/scripts/vgas001_upgrade_fixture.sql`. With
`VGAS_VERIFY_VGAS001_UPGRADE=true`, all 7 foundation cases passed.
Both lanes exited 0.

## Final test results

Both full runs used a fresh database. Each ran the five F04 cases and
excluded only the predecessor-only test, which passed in its own lane.

```sh
VGAS_F04_DISPOSABLE=1 ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test --seed 103
VGAS_F04_DISPOSABLE=1 ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test --seed 8125
```

Each full suite exited 0 with 803 passed, zero failed, zero skipped and
one excluded. The broader focused suite exited 0 with 483 passed.

```sh
ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test test/voelgoed_ai/support test/voelgoed_ai/knowledge test/voelgoed_ai/governance test/voelgoed_ai/ash_ai_feasibility_test.exs test/voelgoed_ai/intelligence/generation_test.exs --seed 0
```

All eight mutants failed at their stated checks on the final source.
After restoration, strict TEST compile, snapshot consistency, fresh
migration and all 27 generation tests passed again. The secret check
uses Gitleaks 8.30.1 against the staged candidate and exact commit range.

```sh
mise exec gitleaks@8.30.1 -- gitleaks git --staged --redact=100 --no-banner .
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e3192e491748749879d0bd118ad4a1f262f9cc65..HEAD' --no-banner .
```

An early diagnostic copied the runner and added filtered assertion output.
The recorded verification used the approved runner directly. The final
code matches the source used for the tests. Independent review and
required CI remain the orchestrator's merge steps.

## PR #26 review correction

The correction is based on the published PR head
`487149def51fb10a7db785bab8898e57770554ea`, whose parent is
`e3192e491748749879d0bd118ad4a1f262f9cc65`. The local branch
`well/fix-governed-generation-review-findings` fast-forwarded to that head
before the tests and correction. The support worker remains disconnected.

### Reproduction and regression evidence

The first run added seven synthetic cases and ran them against the
published implementation before editing production code.

```sh
ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test test/voelgoed_ai/intelligence/generation_test.exs --only review_regression --seed 0
```

ExUnit exited 2 with 2 passed, 5 failed and 27 excluded. The initial
cases were:

- `ReqLLM exception telemetry redacts http_failure`, `nested_failure` and
  `decode_failure`. The tests subscribe to the actual
  `[:req_llm, :request, :exception]` event and search the serialized metadata
  for synthetic request and response markers. The original implementation
  failed the marker check in each case. The HTTP 503 carried a synthetic
  provider message. The nested API failure supplied the marker in its cause,
  headers and provider code. Malformed JSON exercised Req's decoder error.
  The final suite also exercises a raised provider decoder error after valid
  usage capture. It expects the fixed decode diagnostic and a single
  8,750 nano-USD settlement with the attempt marked failed.
- `frozen output cap with 500 correlated output tokens` and the paired
  501-token case. The original 501-token call settled at 380,750 nano-USD
  and returned a proposal. The 500-token case passed. The corrected cases
  check 380,000 and 380,750 nano-USD respectively in the original UTC
  windows, and verify that recovery and another invocation produce zero
  additional wire calls or ledger entries.
- `adapter entry after committed marker with automation disable true` and
  its enabled control. The barrier is the synchronous ReqLLM request-start
  event in the timed request task. The test sees the committed marker and
  reservation on another connection, then commits the disable before
  releasing the task. The original code entered the synthetic wire once.
  The corrected case requires zero entries and an UNKNOWN hold for the
  full ceiling. The enabled control requires one entry on that task,
  observes no open transaction there or on the caller's backend, and
  accepts the proposal with the exact settlement.

### Pinned request path and lifecycle

OpenAI's ReqLLM 1.31.0 `providers/openai.ex:850–879` appends the provider
decoder and installs `step/error.ex` before `step/telemetry.ex`.
`providers/openai/responses_api.ex:169–185` places the response body in the
non-200 exception. `step/error.ex:56–120` can copy the provider reason,
headers and cause into the next exception, and takes `request_body` from
the Req request when needed. `telemetry.ex:471–491,584–611` includes the
error independently of the optional payload fields. In Req 0.7.5,
`lib/req/request.ex:1057–1104` runs returned adapter and response-step
errors through `error_steps`. Its JSON decoder can return a Jason exception
that carries the data it tried to decode.

The generation adapter converts non-200 responses before provider parsing.
It adds an error step ahead of ReqLLM's wrapper and clears the request body
on that path so the wrapper cannot reattach it. The step constructs a fresh
exception with a fixed diagnostic and, when available, a bounded HTTP
status. The named provider decoder converts raised exceptions to the same
error path. ReqLLM's total timeout emits its own fixed timeout exception
from `timeout_budget.ex`. The adapter still captures bounded correlated
usage before decoding a 200 response. The existing valid, invalid,
wrong-locale, refusal and truncation cases check the resulting financial
and proposal outcomes.

The consumed marker stays durable. The one-shot adapter closure checks the
current control and inhibition, assistant revision, binding and session
authority, claim and deadline, exact attempt and fence, committed marker
and reserved hold. It reuses the dispatch lock order and exits the short
transaction before wire entry. The transport clamps timeouts to the
earlier of the current and frozen cutoffs after lock waits. An authority change
committed before this check prevents I/O. An authority change after the
check can still overlap wire entry because the database locks end before
I/O. The post-result qualification still suppresses a proposal after such
a change. Denial at adapter entry after a marker retains the full hold and
prohibits replay. Trusted late evidence can still reconcile money through
the original fence.

The frozen reservation's `max_output_tokens` is a proposal guard independent
of the total amount charged. Correlated usage over that token limit settles
as an invalid proposal at its exact price. An amount over the reservation
still follows the existing inhibition and alert path. No new accounting
state or schema change is needed.

For rollback, disable automation and preserve recovery, the reservation
and the ledger. The correction can be reverted at the code level without
rolling back the PR C schema. Keep automation disabled if reverted, since
the original runtime would reintroduce the findings. Independent review
and CI on the corrected head remain pending at local handoff.

### Correction verification commands

All database tests ran via the approved `vgas_disposable_pg.sh` runner.
`bash .github/scripts/verify_postgres.sh 180007` verified PostgreSQL 18.7,
pgvector 0.8.7, the role and database owner, role restrictions and vector
distance on both approved loopback ports. Port 55435 hosted the focused
and migration runs. Port 55434 hosted the full run. The runner owns and
removes its container and volume. The shared DevCore allocation stayed
outside these tests.

```sh
export ELIXIR_ERL_OPTIONS="+S 4"
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix compile --force --warnings-as-errors
mise exec -- mix ash.codegen --check
mise exec -- mix test test/voelgoed_ai/intelligence/generation_test.exs test/voelgoed_ai/governance/embedding_accounting_test.exs test/voelgoed_ai/knowledge/editorial_test.exs test/voelgoed_ai/support/delivery_recovery_test.exs test/voelgoed_ai/repo_foundation_test.exs --seed 0
```

These TEST commands exited 0. The focused run passed 147 cases, including
all 35 generation tests and the tests for the eight previous D2 invariants.
It excluded the predecessor-only VGAS-001 test. The prior candidate's
mutation runs remain historical evidence. The populated upgrade used the
same predecessor migration path and fixture documented above. All 22
predecessor row projections matched after upgrade, rollback and reapply.

```sh
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=prod ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked
mise exec -- mix deps.unlock --check-unused
mise exec -- mix hex.audit
mise exec -- mix format --check-formatted
python3 .github/scripts/plan_tests.py
git diff --check
```

DEV and PROD strict compile each exited 1 at the same 17 application
warning locations, matching the inherited count tracked under VGAS-19.
The TEST build exports `Generation.with_fixture/4`. Inspection with
`:beam_lib.chunks/2` confirmed that DEV and PROD omit that export. The
dependency, advisory, format, test plan and diff checks exited 0.

```sh
VGAS_F04_DISPOSABLE=1 ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test --seed 103
```

The serial full run exited 0 with 811 passed, zero failed and one excluded.
An earlier run exited 2 with publication and retrieval failures while a
forced TEST compile rewrote the same build directory. That run reported
missing compiled modules. The serial rerun used a fresh disposable database
and exclusive use of the TEST build directory.

```sh
mise exec gitleaks@8.30.1 -- gitleaks git --staged --redact=100 --no-banner .
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e3192e491748749879d0bd118ad4a1f262f9cc65..HEAD' --no-banner .
```

The staged and commit-range scans reported no leaks.
