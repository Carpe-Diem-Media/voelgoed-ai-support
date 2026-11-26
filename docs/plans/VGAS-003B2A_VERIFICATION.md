# VGAS-003 B2a verification

Base `0b34a9a1a782c5187f72353e51f00a173cdeb3c8`. Application and test candidate
`9f246b99cda6227e0135070718ae5fea3e1a9f6f` on
`feat/vgas-003b2a-publication`. The first commit, `3d7d203`, preserves the
[accepted B2 plan](VGAS-003B2_PLAN.md) byte for byte. The orchestrator owns
Plane and the PR handoff.

## Lifecycle and authority

- The publisher and expiry workers carry only revision IDs and generations.
  A rollback job carries only its audit request ID. The Ash policy checks a
  process-bound capability for the exact action and arguments. The transaction
  qualifies the durable request again. Staff requests still hold the live
  reviewer session lock before the control lock.
- T07 takes control, collection, article, revisions by ID, then embeddings by
  ID. It verifies the expected pointer, collection epoch, profile, approval,
  canonical content, exact locale set and validity under those locks. It
  supersedes the old revision, fences its generations, activates the new one,
  switches the pointer, and writes audit and any expiry job in one transaction.
  An obsolete job is a no-op. A stale current request commits its generation
  fence and returns a typed stale outcome.
- T08 writes the final READY locale and its finalisation job with the attempt,
  reservation, ledger and spend-window settlement. A failed enqueue leaves
  the consumed attempt and original hold available for recovery. A local
  retry cannot invoke a dispatched attempt again.
- Recovery takes independent batches of up to 50 publications, reindexes and
  expiries, each ordered by deadline and ID. A reindex keeps the live generation
  during indexing. A successful switch increases the index epoch and keeps at
  most one prior complete generation. Generation allocation uses the high-water
  mark even after rollback. Revoke, archive, expiry and supersession clear
  active index fields and invalidate every affected vector.
- Rollback requires a matching durable request, current pointer, live scope and
  deadline, matching active generation and epoch, no pending reindex, and a
  complete retained generation with a matching evaluation receipt. Only TEST
  compiles the synthetic issuer and the rollback path. The receipt contains five
  bounded fields, with no free text.

## Commands and outcomes

The disposable harness provisioned PostgreSQL 18.7 with pgvector 0.8.7 and
ran the application as the non-superuser TEST role. It unset
`OPENAI_API_KEY`, set `VGAS_VERIFY_PGVECTOR=true` and cleaned up its
containers and volumes. No shared DevCore database or service was used.
The lockfile pins Phoenix 1.8.17, Ash 3.38.1, AshPostgres 2.15.2, Ecto 3.14.3,
Ecto SQL 3.14.0, Postgrex 0.23.0 and Oban 2.24.2. The implementation uses
the installed Ash generic action, query-lock and return type APIs and
Oban's repository-backed insertion and scheduling.

All Mix commands below ran through `mise exec --`.

- `mix compile --warnings-as-errors --force` in TEST exited 0.
- `mix ecto.migrate --strict-version-order` on a fresh database exited 0.
  `mix ash.codegen vgas_003b2a_publication` generated the migration and two
  snapshots. `mix ash.codegen --check` exited 0 after the review and guard.
- `mix test test/voelgoed_ai/knowledge/publication_test.exs` exited 0 with
  12 tests passed. The lock tests used committed connections and
  `pg_blocking_pids`. Database triggers forced audit, expiry and
  finalisation enqueue failures.
- `mix test --seed 0` exited 0 with 413 passed, 5 skipped and 1 excluded.
- `mix test --seed 103` exited 0 with 413 passed, 5 skipped and 1 excluded.
- `mix format --check-formatted`, `mix deps.get --check-locked`,
  `mix hex.audit`, and `python3 .github/scripts/plan_tests.py` exited 0.
  Hex reported no retired packages or security advisories. The lockfile and
  CI configuration are unchanged.
- `git diff --check 0b34a9a HEAD` exited 0.
  `rg 'authorize\?: false' lib` exited 1 with no matches.
  `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='0b34a9a..HEAD'`
  exited 0 with no leaks in the implementation commits.
- `MIX_ENV=dev mise exec -- mix compile` and a separate
  `elixir -pa _build/dev/lib/voelgoed_ai/ebin` probe exited 0. The probe
  observed `Publication.rollback_available/0` return
  `{:error, :rollback_disabled}` and no exported
  `Publication.record_fixture_evaluation/2`. The DEV build reported
  inherited warnings. TEST compilation is the warnings-as-errors gate.

## Migration rehearsal

Use the disposable pgvector harness from the assignment. Do not run the
rehearsal on a shared database.

1. `mise exec -- mix ecto.migrate --strict-version-order --to 20261126063108`
   exited 0. The migration chain through that version matches the up
   migrations in `0b34a9a`. The sole predecessor edit is the B1 down guard.
2. Load `.github/scripts/vgas001_upgrade_fixture.sql` with
   `psql -XqAt -v ON_ERROR_STOP=1 -f`, then load
   [vgas_003b1_publication.sql](../../test/fixtures/vgas_003b1_publication.sql)
   with the same flags and `-v audit_only=true`. These commands exited 0.
   With only the revoke audit and no publication or accounting data,
   `mise exec -- mix ecto.rollback --step 1` exited 1 with PostgreSQL
   `P0001` and the expected B1 guard message. The revoke row survived.
3. `mise exec -- mix ecto.migrate --strict-version-order`,
   `mise exec -- mix ecto.rollback --step 1`,
   `mise exec -- mix ecto.migrate --strict-version-order`, and
   `mise exec -- mix ecto.rollback --step 1` all exited 0 on the unused B2a
   schema. The existing B1 revoke history remained present.
4. Load the B1 fixture with `-v audit_only=false`. Dump ordered JSONB
   aggregates of revisions, articles, embeddings, attempts, reservations,
   spend windows, ledger and audits before and after
   `mise exec -- mix ecto.migrate --strict-version-order`. Ignore only the
   newly added revision fields. Migration and `cmp` exited 0. Two READY
   vectors still had 1,536 dimensions and 163,840 nano-USD remained held.
   No revision activated during migration.
5. Seed one PUBLISHED revision and its pointer on the disposable schema.
   `mise exec -- mix ecto.rollback --step 1` exited 1 with PostgreSQL
   `P0001` and the expected B2a guard message. The pointer still referenced
   the PUBLISHED revision after the refusal.

## Test sensitivity and development record

Each mutant ran alone on the committed candidate with
`mise exec -- mix test --seed 0 test/voelgoed_ai/knowledge/publication_test.exs:<line>`.
Each command exited 2 with the expected assertion failure, one failed test
and 11 excluded. The script restored `lib` with `git checkout -- lib` after
each run.

- Line 93, remove the expected pointer check. Both requests activated in
  sequence, and the first winner became SUPERSEDED.
- Line 232, remove the exact locale-set comparison. The missing locale
  left the revision PUBLISHING instead of failing its generation.
- Line 205, remove the collection epoch comparison. A request from before
  disable and re-enable activated.
- Line 362, remove the rollback index epoch comparison. An old request
  switched the index after the active generation returned to its old value.
- Line 135, commit before inserting the expiry job. A rejected enqueue
  left the old revision SUPERSEDED.
- Line 362, allocate reindex generations from the active generation. A
  failed reindex led to reuse of generation 2 and blocked the next request.

After restoration, `mise exec -- mix test --seed 0 test/voelgoed_ai/knowledge/publication_test.exs`
exited 0 with all 12 tests passed.

The first focused run found a test barrier that only recognised the original
row-lock holder. The second finaliser can wait behind the first finaliser's
request, so the test now checks for either PostgreSQL blocker. The first full
runs exposed a missing fixture export and stale audit-action enumerations.
Both were corrected. Only the canonical-content regression has a recorded
behavioural RED run immediately before its fix. The original test-first
attempt overlapped compilation of the new resource actions, and the rest of
the regressions did not each receive a before-code run.

A later check on an isolated archive of `0b34a9a` ran
`mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:78`
with a temporary assertion for the finalisation job. It exited 2 at that
assertion. Both bilingual rows were READY and the job count was zero.
The canonical regression exited 2 before the fix at
`mise exec -- mix test test/voelgoed_ai/knowledge/publication_test.exs:297`.
The candidate suite passed the corresponding publication and canonical content checks.

## Recovery and owner decisions

A failed request does not rebase itself. A reviewer can retry the same
approval against the latest pointer with a fresh generation after resolving
the reason. Restore terminal content through a new reviewed revision.
After restore, keep live gates disabled, reapply revocations and confirm
current pointers, index generations and outstanding holds before restarting
work. Leave ambiguous charges held until trusted evidence or authorised
closure. Replay of restored jobs cannot authorise another external dispatch.

The owner still needs to approve an evaluator and retention policy before
enabling actual index rollback, and decide whether to permit indexed
handoff markers for sensitive or `escalate_only` articles. This slice
keeps those articles unpublishable. Ranking measurements and the
admission-before-spend composition belong to B2b. Independent exact-head
review and hosted CI are pending the orchestrator's PR handoff.

## Completion assessment

Scope is VGAS-003 B2a, implementation. This is the author's assessment.

- Verified the unchanged authority commit and exact B1 comparison base.
- Verified publisher and reviewer authorization, including forged actors
  and direct audit storage calls.
- Verified atomic T07 activation, one winner in a same-pointer race, stale
  guards, and rollback on audit and expiry enqueue failures.
- Verified T08 finalisation enqueue atomicity and preservation of the
  pre-existing spend hold if enqueue fails.
- Verified stranded B1 recovery, temporal guards, and revoke, archive and
  expiry fencing.
- Verified reindex success and failure, retention, evaluated rollback and
  replay fencing, monotonic generations and the non-TEST gate.
- Verified one additive migration, snapshot consistency, fresh migration,
  B1 upgrade, unused-schema rollback and both history-sensitive guards.
- Verified the focused and full suites, the six mutants and static checks.
- The per-behaviour test-first sequence was incomplete. The before-fix and
  B1 baseline runs above record the evidence that exists.

Eight of nine criteria are verified. Implementation score is **9/10**
(requirements 3/4, verification 3/3, correctness and risk 2/2, handoff 1/1).
Confidence is **95%** based on the disposable database runs, mutation evidence
and migration rehearsal. Hosted CI and independent exact-head review remain
with the orchestrator. Verification status is **PARTIALLY_VERIFIED** for the
full assignment because of the test-first gap. The runtime and migration
checks listed here passed. Merge status is `NOT_VERIFIED_FOR_MERGE`.
