# VGAS-15 PR D verification

Base `1cf422596aaed4c1620ef82340135c5049919f25`, tree
`ebdd205d9cea073aebf2a0131af764da7e386348`, on
`well/vgas-15d-shadow-worker`. PRs B and C were merged at this base.
Plane VGAS-15 was In Progress when read. This record covers the local D
candidate under the [accepted plan](VGAS-15_PLAN.md), including R4, R5,
R7, R10 and R11. No Plane or GitHub state changed.

## Implementation and boundaries

- The normal signed receipt, ProcessEvent and ProcessRun path runs the
  single shadow workflow in TEST. Its authority is a private worker
  capability tied to covered receipts, the qualified destination, the
  assistant's current revision, the claim and the shadow gate. Direct
  retrieval and generation fixture capabilities cannot issue that worker
  authority. Outside TEST the current integration gates deny this path.
- Deterministic greeting, explicit human request, clarification and known
  off-topic refusal take precedence. The worker uses an empty applicability
  scope and requires a unique normalized authored FAQ title or alternative
  question. The comparison trims surrounding space, folds case and ignores
  terminal question and exclamation marks. No match or unhandled conditions
  route locally. Mixed current messages go to staff unless a deterministic
  path applies. Identical questions in a bounded regroup can share one intent.
- Retrieval uses the existing indexed publication and hybrid rank. The worker
  pins the candidate before query embedding and never substitutes a decoy.
  It rechecks the selected revision before the proposal reservation, before
  generation dispatch, at Req adapter entry and at T04. T04 also rechecks
  the current public projection, covered receipts, pending input, epochs
  and cutoff. Exact uses the approved answer bytes. Grounded uses the typed,
  deterministically validated proposal. Shadow completion records no public
  intent. Where it still owns the session, context or evidence loss stages
  the existing local handoff. Loss of ownership suppresses the old decision.
- The two provider paths use committed dispatch markers and reservations
  outside HTTP. The original deadline covers the predecessor and its one
  successor. UNKNOWN or still-running predecessor work blocks another
  query. Generation's existing slot rules cap generation separately.
  Trusted late usage still settles after revocation, deadline or a global
  stop. The existing conservative closure and correction rules are unchanged.
- The query adapter redacts ReqLLM exception bodies. A 503 fixture first
  reproduced a public query in exception telemetry with payload capture
  disabled. The shadow query path now uses the pinned generation adapter's
  error sanitization and screens non-200 bodies before provider decoding.
- T06 fake-only positive controls remain in the B tests. D adds a fixed
  version-one encoding vector and simulates a digest mismatch both at claim
  and after the dispatch marker. The before-claim route uses the existing
  `stale_policy` reason. The post-marker route uses `dispatch_denied`.
  Both deny the fake write and replay.
- There is no D migration, resource snapshot or lockfile change. Rollback
  uses the global epoch fence and compatible B/C schema. See the
  [shadow runbook](../runbooks/vgas-15-shadow.md).

## Labelled synthetic results

All 22 cases matched their expected route and evidence. The nearest-rank p95
was 219.6 ms for the first worker execution. This timing includes local
SQL and fake transport, and excludes fixture setup and replay.

Subsets passed 4/4 supported, 2/2 greeting, 2/2 clarification, 2/2 off topic, 3/3 unanswerable, 2/2 human request, 2/2 restricted, 5/5 adversarial.
There were 8 query-embedding hits and 6 generation hits.
Trusted usage totalled 74 input tokens and 25 output tokens, for
43,814 synthetic nano-USD. One generation contributed an UNKNOWN
hold of 525,375,000 nano-USD and supplied no trusted usage. The matrix and
its delivery/recovery checks recorded zero reply and status writes.
Human semantic review is pending for all cases.

Each line gives the locale, subset, severity, observed outcome, selected
fixture, first-worker latency, query/generation hits, trusted input/output
tokens, charge and held nano-USD. The observed outcome and fixture match
the expected values in each case.

- D01 af-ZA, supported, normal. `answer_exact/supported`, target evidence, 219.6 ms, 1/0 hits, 3/0 tokens, 8 charged and 0 held.
- D02 en-ZA, supported, normal. `answer_exact/supported`, target evidence, 146.9 ms, 1/0 hits, 3/0 tokens, 8 charged and 0 held.
- D03 af-ZA, supported, normal. `answer_grounded/supported`, target evidence, 243.7 ms, 1/1 hits, 13/5 tokens, 8,758 charged and 0 held.
- D04 en-ZA, supported, normal. `answer_grounded/supported`, target evidence, 204.7 ms, 1/1 hits, 13/5 tokens, 8,758 charged and 0 held.
- D05 af-ZA, greeting, normal. `greeting/greeting`, none evidence, 27.9 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D06 en-ZA, greeting, normal. `greeting/greeting`, none evidence, 22.9 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D07 af-ZA, clarification, normal. `clarify/ambiguous`, none evidence, 23.4 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D08 en-ZA, clarification, normal. `clarify/ambiguous`, none evidence, 23.2 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D09 af-ZA, off topic, normal. `decline/off_topic`, none evidence, 27.3 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D10 en-ZA, off topic, normal. `decline/off_topic`, none evidence, 23.1 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D11 af-ZA, unanswerable, normal. `handoff/missing_evidence`, none evidence, 55.7 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D12 en-ZA, unanswerable, normal. `handoff/missing_evidence`, none evidence, 50.1 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D13 af-ZA, human request, critical. `handoff/human_requested`, none evidence, 27.9 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D14 en-ZA, human request, critical. `handoff/human_requested`, none evidence, 31.0 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D15 af-ZA, restricted, critical. `handoff/account_specific`, none evidence, 25.7 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D16 en-ZA, restricted, critical. `handoff/account_specific`, none evidence, 28.0 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D17 af-ZA, adversarial, critical. `failed/history_changed`, none evidence, 192.6 ms, 1/1 hits, 13/5 tokens, 8,758 charged and 0 held.
- D18 en-ZA, adversarial, critical. `failed/history_changed`, none evidence, 214.9 ms, 1/1 hits, 13/5 tokens, 8,758 charged and 0 held.
- D19 af-ZA, adversarial, critical. `handoff/unavailable`, none evidence, 207.1 ms, 1/1 hits, 13/5 tokens, 8,758 charged and 0 held.
- D20 en-ZA, adversarial, critical. `handoff/unavailable`, none evidence, 190.6 ms, 1/1 hits, 3/0 tokens, 8 charged and 525,375,000 held.
- D21 en-ZA, adversarial, critical. `failed/history_changed`, none evidence, 26.8 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.
- D22 af-ZA, unanswerable, critical. `handoff/conflicting_evidence`, none evidence, 54.9 ms, 0/0 hits, 0/0 tokens, 0 charged and 0 held.

The lifecycle cases outside this matrix observed a generation deadline
hold of 525,375,000 nano-USD before a late response settled 10 input and
5 output tokens for 8,750 nano-USD. A timed-out predecessor query held
81,920 nano-USD with no trusted usage and no new calls in its successor.
A non-200 query likewise held 81,920 nano-USD and routed locally without
generation. The rollback case settled the original trusted charge after
the global stop and retained no eligible answer.

## Commands and outcomes

Used the approved disposable runner at
`/home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh`
with `"$PWD" "$steps_file" "$port"` after checking
`ss -ltn '( sport = :55434 or sport = :55435 )'`. Port 55435 hosted
focused, migration and mutation checks. Port 55434 hosted full suites.
The TEST role owned the disposable database and lacked superuser, database
creation and role creation privileges. The version and cosine probe
`bash .github/scripts/verify_postgres.sh 180007` exited 0. The runner
removed each completed container and volume.

```sh
MIX_ENV=test HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked
MIX_ENV=test ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix hex.audit
MIX_ENV=test ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix format --check-formatted
git diff --check
python3 .github/scripts/plan_tests.py
```

Each exited 0. The lockfile was unchanged. Hex reported no retired or
security advisory packages. The CI planner assigned the smoke file to a shard. The report verifier
requires its explicit case-level exclusion.

The focused runner recorded these commands with exit 0.

```sh
ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 4" VGAS_SHADOW_EVAL=1 mise exec -- mix test --no-compile test/voelgoed_ai/support/shadow_workflow_test.exs test/voelgoed_ai/support/decision_evidence_test.exs test/voelgoed_ai/intelligence/generation_test.exs --seed 0
ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix ash.codegen --check
```

The three-file run passed 233 tests with zero exclusions. It includes the
independent idle PostgreSQL backend observation during both wire calls,
T04 context changes and evidence loss, T06 payload mismatch, accounting
across a bounded successor, late settlement, and the R4 correction tests
from PR C. It includes the paused-call rollback test. The first larger
focused run passed 527 of 528 selected tests and had one explicit smoke
exclusion. Its pre-claim mismatch test initially expected the wrong
reason code. The observed state was cancelled/stale_policy with zero
claim attempts. The corrected assertion and later focused run passed.

The local migration checks ran the Application CI fresh, foundation
upgrade and staff-history upgrade sequences on separate disposable
databases. All exited 0. The upgrade runs extracted and compared
`20261125141215_foundation_extensions_1.exs` from `aa93104` and both
that file and `20261125205628_add_staff_authorization.exs` from
`92ef0e3`, respectively. The latter loaded
`.github/scripts/vgas001_upgrade_fixture.sql` with `psql -X -q -v ON_ERROR_STOP=1`
as the disposable TEST role. The sequences used:

```sh
mise exec -- mix ecto.migrate --migrations-path "$base_migrations" --strict-version-order
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix ecto.migrations
mise exec -- mix test --no-compile test/voelgoed_ai/repo_foundation_test.exs --seed 0 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter
python3 .github/scripts/verify_test_results.py "$CI_TEST_RESULTS_OUTPUT" "$lane" test/voelgoed_ai/repo_foundation_test.exs
```

The fresh and foundation-only lanes verified six passes and one approved
predecessor exclusion. The staff-history lane set
`VGAS_VERIFY_VGAS001_UPGRADE=true` and verified seven passes. There were
no pending migrations. A separate empty-history rehearsal ran
`mix ecto.migrate --strict-version-order`, `mix ecto.rollback --step 1`
and `mix ecto.migrate --strict-version-order`, all through Mise with
`ELIXIR_ERL_OPTIONS="+S 4"`, all exit 0. The application rollback retains
the existing B/C migrations.

```sh
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=prod ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix compile --force --warnings-as-errors
```

Each non-TEST strict compile exited 1 with the same 17 inherited
fixture-gate warnings. The count and warning sites match the PR C
record. VGAS-19 owns that cleanup. The compiled DEV and PROD BEAM probes
exited 0. They required the absence of `Retrieval.with_shadow/8`,
`Retrieval.with_fixture/2`, `Generation.propose/5`, `Generation.with_fixture/4`
and `RunProcessing.complete_evidence_fixture/3`. They also required
`ChatwootAdapter.fixture/0` to return nil and
`ChatwootAdapter.decision_context/3` to return `{:error, :unavailable}`.

## Mutation checks

Each mutation used a temporary source copy and the disposable database on
55435. Each named command exited 2 on the mutated source. The changed
file was restored after each execution.

- Claim accepted the shadow binding mode without the evaluation predicate.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_decision_test.exs:180 --seed 0`.
  The default-off route failed its expected legacy no-send state.
- Public context accepted a private staff note.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs:16 --seed 0`.
  D21 failed the expected history-loss outcome.
- T04 used its selected manifest without revalidation.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs:27 --seed 0`.
  The revoked selection produced a grounded decision.
- The pre-generation check accepted the original selection after ranking.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs:117 --seed 0`.
  The test observed a result outside its safe handoff expectation.
- The query attempt used the direct fixture lineage mode.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs:218 --seed 0`.
  An UNKNOWN query with spare budget allowed a successor to generate a
  grounded decision. The earlier generation-UNKNOWN mutant passed because
  the independent embedding spend cap already denied a new reservation.
- The successor replaced the original deadline with a new 45-second window.
  `mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs:213 --seed 0`.
  Both successors failed the inherited deadline assertion.
- T06 checked only for a digest value.
  `mise exec -- mix test test/voelgoed_ai/support/decision_evidence_test.exs:637 --seed 0`.
  The corruption tests observed a send at both boundaries.

## Full suite and report checks

The full suites used `ELIXIR_ERL_OPTIONS="+S 4"` and
`VGAS_F04_DISPOSABLE=1` on the disposable database at 55434. The final
application code passed 849 tests at seed 8125 with two expected
exclusions. That seed loaded the tests before the isolated UNKNOWN-query
mutation case was added. The earlier attempt at overlapping a forced
compile and a full test process in the same build directory failed to load
BEAM modules. The reruns used the strict compiled TEST build and
`--no-compile`.

```sh
mise exec -- mix test --no-compile --seed 8125
CI_TEST_RESULTS_OUTPUT="$results" mise exec -- mix test --no-compile --seed 103 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter
python3 .github/scripts/verify_test_results.py "$results" shard $(rg --files test -g '*_test.exs' | sort)
MIX_ENV=test ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix xref graph --format stats
```

The static dependency graph and Python syntax checks passed. A direct
report-verifier test accepted the exact smoke exclusion and rejected it
when the report omitted it or marked it passed or skipped. The approved
exclusions are the live provider smoke and the predecessor-only case.

After restoring all mutations, this focused run exited 0 with 268
passes and zero exclusions.

```sh
ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test --no-compile test/voelgoed_ai/support/shadow_workflow_test.exs test/voelgoed_ai/support/shadow_decision_test.exs test/voelgoed_ai/support/decision_evidence_test.exs test/voelgoed_ai/intelligence/generation_test.exs --seed 0 --warnings-as-errors
```

The final test tree passed 850 tests at seed 103 with two expected
exclusions. The case-level verifier exited 0. The log includes the
intentional synthetic reserve-commit failure from the rollback test.
The final database container and volume were removed.

The candidate secret checks use pinned Gitleaks 8.30.1 with redaction.

```sh
mise exec gitleaks@8.30.1 -- gitleaks git --staged --redact=100 --no-banner .
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='1cf422596aaed4c1620ef82340135c5049919f25..HEAD' --no-banner .
```

The staged check exited 0 with no findings. The exact-range check is a
post-commit handoff check.

## Author completion assessment

Task VGAS-15 PR D. Implementation and author self-assessment. Scope is
the signed, default-off shadow worker and local synthetic verification.

Nine local criteria verified.

1. Qualified single-binding authority and default-off non-TEST gate.
2. Signed intake, bounded public context, deterministic and local routes.
3. T04 evidence requalification, immutable completion and context loss.
4. T06 fake-only commitment check, mismatch denial and replay protection.
5. Actual governed generation and query paths with correlated usage.
6. Deadline and budget preservation, recovery and UNKNOWN lineage protection.
7. Bilingual labelled evidence, timings, wire counts and zero Chatwoot writes.
8. Tested rollback and explicitly gated, independently capped smoke entry.
9. Strict TEST compile, focused and full suites, migration, mutation and
   repository checks on disposable infrastructure.

Implementation Score 9.5/10. Requirements 4/4, verification 3/3,
correctness and risk 1.5/2, handoff 1/1. The coverage check intentionally
requires an authored match. The automated literal-fact checks leave
semantic entailment and behavior on differently worded questions open.
Confidence 95% in the local mechanics, based on the end-to-end,
negative and mutation results. Staging behavior remains unobserved.

Verification Status `VERIFIED` for the local synthetic scope.
Hosted exact-head CI and independent candidate review are pending.
Merge readiness is `NOT_VERIFIED_FOR_MERGE`. The orchestrator owns those
checks. The owner must separately authorize VGAS-7 and VGAS-8 work.
The source owner and staff reviewers own VGAS-11 and semantic review.
The provider smoke remained excluded. Release and production activation
are outside this handoff.
