# VGAS-28 reply retention

The synthetic scope follows G029–G031, G037, the
[implementation spec](../spec/VGAS_IMPLEMENTATION_SPEC_v1.0.0.md) and the
[resource contracts](../spec/VGAS_RESOURCE_CONTRACTS_v1.0.0.md). The
[VGAS-28 owner ruling](https://app.plane.so/symphony-development/projects/8e7e9131-668d-4d99-8bd7-b5847d5f8c8c/issues/8057300d-2619-4fe5-801f-1ae9e9517682)
is comment `88405d2b-ebd7-4787-9c7a-088fb6264b44`. Reviewed base
`528eac994db73d3dcb5855a7a672554311828584` has tree
`a156c69d4813d9af24f598e67a12a73fd4418039`.

## Storage and expiry

- A completed grounded reply or clarification with stored text starts PRESENT.
  Cleanup can purge it at `finished_at + 7 days <= fixture time`. Active runs,
  pending input or delivery, SENDING or UNKNOWN delivery, unresolved inference
  and reservations, or open or in-review gaps defer purge. The dependency
  check spans every generation of the fully qualified conversation.
- A current admin session must match the configured synthetic approval's
  action, token, target and prior occurrence. Hold preserves the bytes.
  Release returns HELD to PRESENT while young or needed, or purges it when
  eligible. Every successful transition advances its occurrence, so an old
  hold or release cannot apply to a later occurrence. PURGED is terminal.
- Purge removes only the decision's JSON `reply_text` key. The missing key
  distinguishes purge from an originally null reply. Decision kind still counts
  against the clarification limit. Locale, reason, ordered evidence references
  and context digest remain. The in-memory purge flag denies both evidence and
  template rendering. Version-one reply digests keep the original term format.
- The application retains qualified receipts and run input coverage, misuse and
  cooldown dispositions, delivery intent identity, template or payload digests,
  dispatch and reconciliation history, and idle markers and ownership epochs.
  Receipt, processing, recovery and delivery replays use those existing facts.
- Inference attempts, original reservations, settlement and correction entries,
  spend windows, editorial approval history, gap transitions and other audits
  remain. The same global control lock serializes the dependency checks with
  their writers. Staff approval takes the staff lock first. Work then takes
  control, assistant, qualified binding, source and latest session, and run locks.
- Admission expiry is a separate bounded operation. It locks expired keys in
  admission's `window_type, scope, starts_at` order under the control lock. Only
  exact fixture scopes qualify. Account-wide keys require a single fixture
  binding in the account. The clock is read after the lock so new admission
  uses the active window. Active counts and all durable cooldown facts remain.

## Execution and audit

Oban queues and automatic scheduling stay disabled by default. DEV and PROD
builds deny fixture retention. TEST requires the restricted disposable test
connection and an explicit current capability for the exact synthetic inbox.
The schedule test starts a dedicated named Oban instance with only the
retention queue and a synthetic cron entry. Jobs carry the capability ID and,
for continuations, a run ID. Every job is bounded to at most 25 counter rows
and 25 candidate runs. Keyset continuation advances past deferred rows.
A future scheduled scan can reconsider deferred work.

Each committed transition appends a typed run-target audit in the same
transaction. The audit stores event, reason, actor kind and internal staff ID
when applicable, target ID, prior and resulting state and occurrence, UTC time
and correlation. If the append fails, PostgreSQL rolls back the payload
transition. Counter expiry is independent. This authorization covers synthetic
reply text and counters. Live retention and legal hold require separate approval.

## Rollback and VGAS-30 restore input

Pause execution and preserve the database before any downgrade. The migration
classifies predecessor bytes without modifying their decision JSON. It refuses
to downgrade once a hold, release or purge has been recorded. After that point
use a forward fix or a separately approved restore rehearsal. Prior snapshots,
transaction logs and archives have their own retention controls.

VGAS-30 needs a trusted post-backup source for the ordered transition facts
above. Use the target ID and prior/result occurrence to verify the chain.
A repeated result occurrence is idempotent. Preserve terminal purge, and never
restore reply bytes from an earlier generation or backup. Reapply authorized
holds and releases in occurrence order. A hole or conflict in the evidence
keeps the affected scope inhibited. Start with execution paused and quarantine
restored jobs. Require fresh scoped authority for any new execution. Reconcile
qualified receipt, operation and dispatch identity, sticky ownership, uncertain
delivery and original-window spend before lifting inhibition. VGAS-30 owns
the restore rehearsal. Production policy requires separate approval.

## Local evidence

The [disposable test procedure](../development/application-ci.md#disposable-local-workflow)
uses PostgreSQL 18.7 and pgvector 0.8.7. Focused and migration checks use
`55436`. The full result report uses `55437` with `VGAS_F04_DISPOSABLE=1`
and `VGAS_VERIFY_VGAS20_UPGRADE=true`. Both use loopback and the restricted
`vgas_test` role. The migration rehearsal runs only on the dedicated
disposable lane:

```sh
mix ecto.migrate --strict-version-order
VGAS_VGAS28_REHEARSE=1 mix test --seed 0 .github/scripts/vgas28_migration_probe_test.exs
```

The rehearsal creates a synthetic grounded reply through the app, reaches
the populated predecessor schema by clean rollback, reapplies the migration,
compares the original facts and proves the rollback guard after purge.

With Mise's Erlang 29.1.2 and Elixir 1.20.5, the following checks exited zero:

- `mise exec -- mix deps.get --check-locked` and, separately,
  `mise exec -- mix hex.audit`. Hex reported no retired packages or advisories.
- `mise exec -- mix format --check-formatted` and
  `mise exec -- mix format --check-formatted .github/scripts/release_runtime.exs .github/scripts/vgas28_migration_probe_test.exs`.
- `MIX_ENV=dev mise exec -- mix compile --warnings-as-errors`,
  `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors --no-deps-check`,
  and `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`.
- `MIX_ENV=test mise exec -- mix ash.codegen --check` with a loopback
  placeholder connection on port 1. It required no database connection.
- `bash .github/scripts/verify_postgres.sh 180007` against each disposable role
  and `mise exec -- mix ecto.migrate --strict-version-order` on each fresh database.
- `VGAS_VGAS28_REHEARSE=1 mise exec -- mix test --seed 0 .github/scripts/vgas28_migration_probe_test.exs`.
  One pass. The downgrade refused protected history and left the version and
  purged result intact.
- `mise exec -- mix test --seed 0 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter test/voelgoed_ai/support/retention_test.exs`
  and `python3 .github/scripts/verify_test_results.py <report> shard test/voelgoed_ai/support/retention_test.exs`.
  Ten passes, zero exclusions. The two delivery cases, frozen version-one digest
  and open-gap case each passed in a separate four-case focused run.
- `docker build --platform linux/amd64 --tag vgas28-release:final .` and
  `bash .github/scripts/verify_release.sh vgas28-release:final`.
  The packaged runtime denied retention and the BEAM import inspection confirmed
  the retention module lacks mutation dependencies. Fresh and upgrade migrations,
  default endpoint denial, health and clean shutdown passed on the private network.

The first `devcore-project doctor` found the worktree's `.env.local`
missing. `devcore-project plan`, `devcore-project activate`, and a second
doctor check succeeded. Activation rendered the local file and reapplied the
canonical role settings on the shared DEV and TEST clusters. The slice's
migrations, fixtures, and cleanup ran on the disposable databases.

The full run used `mise exec -- mix test --seed 0 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter`.
It exited zero. The same result verifier in `shard` mode over all tracked test
paths confirmed 950 passes and two approved exclusions. The exclusions were
the live provider smoke and the separate VGAS-001 upgrade case.

Exact-range secret scan command for the committed candidate:

```sh
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 \
  --log-opts='528eac994db73d3dcb5855a7a672554311828584..HEAD' --no-banner .
```

## Completion assessment

VGAS-28 is an implementation task. This is an author self-assessment of
the local candidate. Seven implementation criteria passed:

1. Synthetic authorization, current staff revalidation and direct-action
   and release-build denial.
2. Inclusive cutoff, both hold race orders, stale approvals, terminal purge
   and rollback on audit rejection.
3. Active and unresolved work, financial and delivery evidence, approvals,
   ownership and gap history preservation.
4. Rendering denial, clarification accounting, frozen digest compatibility
   and replay with zero additional outbound writes or accounting entries.
5. Bounded scheduled continuation and admission expiry under contention.
6. Fresh and populated predecessor migration with protected rollback.
7. Restore handoff and reproducible local verification commands.

Implementation score 9/10. Requirements 4/4, observed verification 3/3,
correctness and operational risk 1/2, handoff 1/1. The deduction records the
DevCore role refresh during verification setup. Confidence 95% based on
the disposable suite and packaged release controls. Independent review and
hosted exact-candidate CI remain pending. Verification status `VERIFIED`
for the local implementation. Merge readiness `NOT_VERIFIED_FOR_MERGE`.
