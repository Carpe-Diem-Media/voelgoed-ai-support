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
