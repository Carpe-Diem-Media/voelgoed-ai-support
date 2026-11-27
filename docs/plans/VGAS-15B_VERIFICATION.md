# VGAS-15 PR B verification

Plane VGAS-15, Roadmap VGAS-004. PR B implements D1 and the PR A review findings NIT-1, NIT-2 and NIT-4. The orchestrator addendum in [VGAS-15_PLAN.md](VGAS-15_PLAN.md) governs. The executable candidate is `61974704d0bb780a21efbf930b9dc759ff211c85` on base `e0a86cfa1f539ed10e69ece1caa9a1dc521cd01e`. This record follows as a documentation-only commit. Plane lists VGAS-15 as In Progress. The orchestrator owns issue state, the PR, and independent review.

## Decision and delivery

- T04 starts from a locked RUNNING run with the original positive claim and watermark. It resolves opaque citations from the process-bound TEST manifest, re-projects the selected revisions against current public eligibility, and compares the full projection with what was issued. The recheck runs inside the transaction that already owns the support locks. The search and standalone validation entry points still require their own transactions.
- Exact replies use the approved answer bytes for the selected locale. Grounded replies carry the bounded, validated `reply_text` from SupportDecision. The validator checks mode, the locale tag against the approved variant, selected IDs, links, secret patterns and verbatim numeric and contact facts. It does not establish semantic entailment. Fixed greeting, decline and handoff decisions require an empty citation list. The existing reason-code allowlist still applies.
- T04 commits the typed decision, minimized references, context digest and either an explicit no-send disposition or a unique public intent with its jobs. The context digest reuses the existing bounded projection commitment, so edits to the included preceding messages also invalidate the reply. A server digest binds the intent to the response bytes and immutable run completion. On stale authority or evidence, no public intent is created. The eligible shadow failure path reuses local handoff. The positive send fixtures use synthetic automatic mode.
- T06 locks the COMPLETED source run before the delivery. The claim uses the run's original fence and absolute deadline. It re-qualifies history and selected evidence before reserving a delivery claim. The dispatch marker commits before the final read. Then the worker reads fresh Chatwoot observation and qualified text outside the transaction, takes the locks again, checks receipts, pending input, ownership, circuit and time, re-projects the references, and returns the digest-matched payload. The legacy fixed renderer still supplies the same bytes.
- The shared qualification SQL and its statement timeout use `log: false` and `telemetry_event: nil`. The control lock serializes editorial changes and grant changes with local authorization. The other locks stay in control, assistant, binding, session, run and delivery order. Receipt reads take row locks under the session and control locks. Transport is outside transactions.
- The owning worker can cancel a proven pre-POST denial. A stale worker leaves the current claim alone. If authorization SQL fails after the marker, the transaction rolls back and leaves the marker for ordinary recovery. There is still a race between final local authorization and remote POST. Chatwoot can change independently of these locks. The existing UNKNOWN policy covers potential writes and the cutoff at dispatch.

## Schema and rollback

Ash 3.38.1 and AshPostgres 2.15.2. The installed source for Ash map casting and embedded storage, Ash action validation, and AshPostgres custom migration statements was checked against `mix.lock`.

- `20261127065646_qualified_support_evidence.exs` adds `support_runs.evidence_refs`, `support_runs.context_digest` and `outbound_deliveries.payload_digest`.
- Generated snapshots are `outbound_deliveries/20261127065647.json` and `support_runs/20261127065648.json`. Check constraints distinguish existing templates, deterministic shadow decisions and evidence-backed decisions. Triggers protect completion and intent fields, including the completed source fence, against later updates. The existing terminal-state guards still apply.
- Operational rollback starts by disabling automation and routing affected conversations to staff. Retain intents, receipts, decisions and UNKNOWN rows so they can be reconciled. The down migration was verified with empty tables and with predecessor-format rows. Keep this additive schema while evidence-backed rows exist. The predecessor check constraints cannot represent those rows.

## Builds, static checks and migrations

Toolchain is Erlang 29.1.2 and Elixir 1.20.5-otp-29 through Mise. Every command ran with `OPENAI_API_KEY` unset. Database steps ran with synthetic data on the provided disposable PostgreSQL 18.7/pgvector 0.8.7 runner. The command was:

```sh
ss -ltn
timeout 600000 env -u OPENAI_API_KEY bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" "$vgas_port"
```

| Command | Exit and observation |
| --- | --- |
| `MIX_ENV=test mise exec -- mix deps.get --check-locked` | 0. Lockfile unchanged. |
| `MIX_ENV=test mise exec -- mix hex.audit` | 0. No retired packages or advisories reported. |
| `MIX_ENV=test mise exec -- mix format --check-formatted` | 0. |
| `mise exec -- mix compile --force --warnings-as-errors`, TEST via the runner | 0. |
| `MIX_ENV=prod mise exec -- mix compile --force --warnings-as-errors` | 1 on both base and candidate. Same 17 application warning locations and messages after dependencies were compiled. VGAS-19 owns those warnings. The comparison used an archive of the exact base, the candidate worktree, the same locked dependencies and the same build path. |
| `MIX_ENV=dev HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors`, repeated with `+S 2` | 1 for each run on both archived revisions with the same 17 application warning locations. |
| `mise exec -- mix ash.codegen qualified_support_evidence` | 0. Reviewed the generated up/down order, constraints, triggers and snapshots. |
| `mise exec -- mix ash.codegen --check` | 0. |
| `mise exec -- mix ecto.migrate --strict-version-order`, `mise exec -- mix ecto.rollback --step 1`, `mise exec -- mix ecto.migrate --strict-version-order` | Each exited 0 on 55435. The fresh foundation test then passed 6 tests with its existing predecessor-only exclusion. |
| `git diff --check e0a86cfa1f539ed10e69ece1caa9a1dc521cd01e...HEAD` | 0. |
| `python3 .github/scripts/plan_tests.py` | 0. Included the new test file. |
| Pinned CI Gitleaks image, command below | 0. Code commit scanned with no findings. |

In all upgrade lanes the predecessor files were copied by `git show REV:priv/repo/migrations/FILE`, or by `git archive e0a86cfa1f539ed10e69ece1caa9a1dc521cd01e priv/repo/migrations` for the complete base. The steps used `mise exec -- mix ecto.migrate --migrations-path "$vgas_base_migrations" --strict-version-order`, then `mise exec -- mix ecto.migrate --strict-version-order`, `mise exec -- mix ecto.migrations` and `mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0`. Each lane exited 0 with no down migrations.

- Foundation upgrade used `20261125141215_foundation_extensions_1.exs` from `aa93104fd476d208206288658e67bfe70e0780cd`.
- VGAS-001 upgrade used that migration plus `20261125205628_add_staff_authorization.exs` from `92ef0e39a7808d4ffa692b37b48ba3ee27a05e30`. Applied `.github/scripts/vgas001_upgrade_fixture.sql` with `psql -X -q -v ON_ERROR_STOP=1 -f` as the disposable TEST role. The foundation command ran with `VGAS_VERIFY_VGAS001_UPGRADE=true`.
- PR A upgrade used the complete base. A further populated lane inserted a synthetic completed legacy reply run, queued run, completed shadow greeting, pending public intent and UNKNOWN handoff. `psql -XAt -v ON_ERROR_STOP=1` dumped the two affected relations as ordered JSON before upgrade and after excluding the three added columns. `cmp` matched all predecessor fields after upgrade and again after rollback. An explicit count found all three runs and both deliveries with null new columns after upgrade. The final re-migration exited 0. This populated check covers the two altered tables. Knowledge and accounting coverage comes from the full suites.

The linked worktree needed its common Git directory mounted at the host path for the CI-pinned scan. The initial scan mounted the worktree alone and scanned 0 commits. The corrected command scanned the code commit.

```sh
vgas_git_dir=$(git rev-parse --path-format=absolute --git-common-dir)
timeout 600000 docker run --rm --user "$(id -u):$(id -g)" \
  --volume "$PWD:$PWD:ro" --volume "$vgas_git_dir:$vgas_git_dir:ro" --workdir "$PWD" \
  ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f \
  git --redact=100 --log-opts=e0a86cfa1f539ed10e69ece1caa9a1dc521cd01e..HEAD --no-banner .
```

The PROD BEAM check exited 0 with `MIX_ENV=prod mise exec -- elixir -pa _build/prod/lib/voelgoed_ai/ebin -e "$probe"`. It checked that `RunProcessing.complete_evidence_fixture/3`, `Retrieval.with_fixture/2` and `Retrieval.at_decision/4` were absent and that `ChatwootAdapter.fixture/0` returned nil and `decision_context/3` returned unavailable.

## PostgreSQL test results

| Command | Exit | Tests |
| --- | --- | --- |
| `mise exec -- mix test test/voelgoed_ai/support/decision_evidence_test.exs test/voelgoed_ai/support/shadow_decision_test.exs test/voelgoed_ai/knowledge/retrieval_test.exs --seed 0` | 0 | 142 passed. |
| `VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 103` | 0 | 657 passed, 0 skipped, 1 inherited predecessor-only exclusion. |
| `VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 8125` | 0 | 657 passed, 0 skipped, 1 inherited predecessor-only exclusion. |

The full runs used port 55434 and the focused runs used 55435. The seed 103 result is from the rerun after the final two fence tests were added. An earlier intermediate focused run had one missing ranked target in a revocation fixture. The repeat focused run and both final full runs passed. The repository's predecessor-only test ran in the VGAS-001 upgrade lane.

### D1 matrix

All 15 required loss cells passed. Stale profile was tested separately from index epoch, bringing the loss cases to 18. The 18 paired controls sent the selected reference's approved bytes once and replay produced no second write.

| Change after rank | After T04 commit, before claim | After marker, before final authorization |
| --- | --- | --- |
| Selected revision revoked. T04 emitted no intent. | Cancelled with no attempt. | Cancelled as dispatch_denied. |
| Expiry at equality. T04 emitted no intent. | Cancelled with no attempt. | Cancelled as dispatch_denied. |
| Grant withdrawn by publishing a replacement assistant revision. T04 emitted no intent. | Cancelled with no attempt. | Cancelled as dispatch_denied. |
| Index epoch advanced. T04 emitted no intent. | Cancelled with no attempt. | Cancelled as dispatch_denied. |
| Stale index profile. T04 emitted no intent. | Cancelled with no attempt. | Cancelled as dispatch_denied. |
| Signed human takeover. T04 emitted no intent. | Cancelled with no attempt. | UNKNOWN preserved after the signed fence consumed the marker. |

The fixtures rank the target and an eligible decoy from different collections. Grant withdrawal preserves the decoy grant on the replacement revision. Takeover denies the entire support session. All loss cases made zero Chatwoot writes, retained the expected completed fence where one existed, and added no second query wire hit or accounting entry. The matrix moves supported editorial and ownership state in committed transactions while the worker is parked. The index/profile fixtures change only the selected row under control because running a second indexing job would change the inference proof. The supported grant change also changes the assistant pin and epoch, so it tests the combined protection. The baseline tests also cover a grounded synthetic paraphrase, denied invented citations and facts, shadow completion without a send intent, T04 enqueue rollback, immutable completion, failed final SQL, edited history and terminal T06 replay.

## Mutation evidence

Each mutation was applied to the committed candidate in isolation, then reverted with `git checkout -- <mutated-file>`. The following commands ran on 55435, each with `mise exec -- mix test <target> --seed 0`. ExUnit exit 2 means the named assertion observed the defect.

The three matrix mutations targeted `test/voelgoed_ai/support/decision_evidence_test.exs:20`. The two NIT mutations targeted `test/voelgoed_ai/support/shadow_decision_test.exs`. Other targets below are in `decision_evidence_test.exs`.

| Mutation | Exit and failing assertion |
| --- | --- |
| T04 returned the selected manifest projection without current SQL and comparison. | 2, 14/18 passed. Revocation, expiry, index epoch and profile persisted a stale decision. |
| Delivery claim skipped `render_evidenced/3`. | 2, 15/18 passed. Revocation, index epoch and profile consumed an attempt after T04. |
| Final gate returned the fixture's exact bytes without `render_evidenced/3`. | 2, 14/18 passed. Revocation, expiry, index epoch and profile reached SENT. |
| Replaced the final worker-claim comparison with a SENDING-state check. `:138` | 2, 0/1 passed. The stale worker sent despite its replaced generation. |
| Required RUNNING at the persisted-reference stage. `:244` | 2, 0/1 passed. Replay test's current COMPLETED-source control made zero writes. |
| Bypassed local policy and ownership validation at the final gate. `:163` | 2, 0/1 passed. The worker sent after the global stop. |
| Accepted citations on fixed decisions. `:43` | 2, 0/1 passed. The cast accepted a nonempty reference list. |
| Removed the shadow-fixture exclusion from the write predicate. `:61` | 2, 0/1 passed. The published shadow revision on an automatic binding satisfied the write predicate. |
| Made the generated completion trigger guard RUNNING instead of COMPLETED. `:244` | 2, 0/1 passed. A completed run accepted a commitment update. This ran on a separate fresh disposable database. |

After restoration, `ash.codegen --check` exited 0 and the 142-test focused command above again exited 0. A restored full run at seed 103 also exited 0 with 657 passed and one inherited exclusion.

The claim-gate expiry case has a second guard. Advancing its fake clock to expiry also reaches the read-freshness cutoff before the marker. Revocation and index/profile changes independently killed claim omission without touching that cutoff. The supported grant withdrawal and signed takeover can also be denied by the current revision and ownership guards. The completed-state test changes the state required by the typed reader to RUNNING. A simple state-check removal at one layer is redundant with the completion constraint and the other state check.

## Final dispatch regression tests

Independent review of `7fb9a49` found two untested paths after the dispatch marker. The worker now has committed tests for observing a human assignee without a webhook and receiving a newer signed customer message without processing its receipt. Both tests use the real Deliver worker and assert `cancelled/dispatch_denied` with zero Chatwoot writes. The correction changes tests and this record only.

The disposable runner on port 55435 reported PostgreSQL 18.7 and pgvector 0.8.7. Locked dependency resolution, format, forced TEST compile with warnings as errors and `ash.codegen --check` exited 0. `VGAS_F04_DISPOSABLE=1 mise exec -- mix test test/voelgoed_ai/support/decision_evidence_test.exs --seed 0` exited 0 with 55 passed. The runner removed its container and volume.

## Grounded amount regression

Independent review of `c8d8ba6` closed both dispatch findings and found that the grounded validator reduced `R25 miljoen` and `R25 per persoon` to the same fact. Its synthetic probe reached the Chatwoot fake. The validator now matches supported Afrikaans and English multiplier words and abbreviations as part of the numeric fact. The original reply bytes still pass through unchanged when the fact matches.

On disposable PostgreSQL 18.7 with pgvector 0.8.7, the negative completion cases at seed 0 initially exited 2. All four new multiplier cases failed on the uncorrected matcher. With the correction, `VGAS_F04_DISPOSABLE=1 mise exec -- mix test test/voelgoed_ai/support/decision_evidence_test.exs test/voelgoed_ai/support/shadow_decision_test.exs test/voelgoed_ai/knowledge/retrieval_test.exs --seed 0` exited 0 with 148 passed, including the existing `R25` dispatch control. Format, forced strict TEST compile and `ash.codegen --check` exited 0. The disposable runner removed its container and volume. A direct render probe accepted the cited `R25 miljoen` and rejected the substituted `R25m` and truncated `R25`.

The next independent review at `a22842f` verified the prior correction and
reproduced `R25 mln` from `R25` and `25 rand` from a bare ticket count in
both locales. All four new completion cases exited 2 on that head. The
matcher now keeps recognized currency labels, signs and scales with the
number. The first corrected run exposed that the English shadow cases
asserted the automatic return shape. The tests now check the persisted
FAILED run, the permitted local handoff intent and zero Chatwoot writes
after the worker processes that intent. The valid `R25` dispatch and
verbatim `40 rand` shadow controls pass.

The same focused command exited 0 on the corrected tests, with 153 passed
at seed 0. Format, forced strict TEST compile and snapshot checks passed.
A direct render probe denied seven unattested forms covering signs,
currency labels and multiplier spacing, then accepted the identical text
when present in the cited evidence. The disposable runner removed its
container and volume. These are literal fact checks. PR D owns semantic
evaluation of the replies.

Independent review at `f0b9e6c` found that a spaced minus and a minor
currency suffix could be omitted from a matched fact. Four bilingual
completion tests reproduced the omissions with ExUnit exit 2. The
corrected matcher keeps the spaced sign and recognized cents or pence
abbreviations with the full amount. All four cases now deny the proposed
decision and produce zero writes, including when the shadow handoff
worker runs. Cited `− 55 rand` and `75c` pass without changing the reply
bytes. The existing `R25` automatic and `40 rand` shadow controls pass.

The focused command above exited 0 at seed 0 with 159 passing tests.
Formatting, forced strict TEST compile and snapshot checks exited 0. The
disposable container and volume were removed. Compatibility was checked
against `e2aa3aa`, which includes the contributor verification PR #24.

The independent review at `aebf001` closed the signed and minor-unit
findings, then reproduced percentages with written units and prices written
in words. Eight new Afrikaans and English completion cases failed on the
old matcher. They cover digit percentages, written and compound prices, and
written percentages. The corrected matcher compares recognized number
words and their currencies or percentage units together, preserving the
verbatim text. The cited `15 percent` and `sixty rand` shadow controls pass.
The denial cases still produce zero fake writes after operational handoff.

The focused command exited 0 with 169 passing tests at seed 0 on disposable
PostgreSQL 18.7 and pgvector 0.8.7. Format, forced strict TEST compile and
snapshot checks passed. A direct render probe denied eight unattested
compound and signed phrases, then accepted each exact phrase when cited.
The disposable container and volume were removed. Independent review and
hosted CI are required for the corrected head.

The independent review at `043904c` confirmed the written-quantity fix and
reproduced gaps in hyphenated percentages, month-name dates and fractional
percentages. Eight new bilingual completion cases failed on that head.
The corrected matcher retains date order, month name, optional ordinal and
year, and the connecting words or punctuation in percentage expressions.
The paired controls for `5-percent`, `30 November 2026` and `one quarter of
a percent` preserve the cited bytes. A direct render probe also checked nine
date and percentage forms with uncited and verbatim cited evidence.

The focused command exited 0 with 180 tests at seed 0. Format, forced strict
TEST compile and snapshot checks exited 0 on disposable PostgreSQL 18.7 and
pgvector 0.8.7. The container and volume were removed. The orchestrator
checked merge compatibility against `2ed8e24`, which adds the independent
editorial correction in PR #25. Exact-head CI and independent review are
pending on the updated candidate.

Independent review of `44764c7` passed the full suite on the merge tree
with 707 passes and one predecessor-only exclusion. It confirmed the
prior literal-fact fixes and reproduced weekday substitution, a discount
range built from separate values, and a fraction with an uncited
denominator. Eight new bilingual completion tests failed on that head.
The matcher now binds the weekday to its date, both endpoints and any
units to the range, and the written denominator to its quantity. The
cited controls for a weekday date, an en-dash range and written thirds
preserve their bytes. An eight-case renderer probe checked additional
numeric dates, range separators and compound fractions against uncited
and verbatim controls.

The focused command passed 191 tests at seed 0 on disposable PostgreSQL
18.7 and pgvector 0.8.7. Format, forced strict TEST compile and snapshots
passed. The container and volume were removed. Exact-head CI and
independent re-review are pending on the corrected candidate.

## Release gates

The verified adapter here is the synthetic TEST fake. VGAS-8 still needs deployed verification of ordered public text, sender/contact qualification and edit/attachment evidence. PR C owns the real generation and reservation caller, and PR D owns wiring, restricted/no-match routing, and labelled semantic evaluation. Live smoke remains `OWNER_AUTHORIZATION_REQUIRED`. This slice made no live provider, embedding, or Chatwoot calls.

Independent exact-head review and hosted CI are pending with the orchestrator. Merge status is `NOT_VERIFIED_FOR_MERGE`.
