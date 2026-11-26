# VGAS-18 PR A verification

Base `3090b1f50aef29331df21ff23318a5866f5085ca`. The plan-only commit is
`07377f692fc28a64f4456a351df0c6bdfac4d872` and the executable candidate is
`65abc3530adeaba5acad16b4bd2eb1f341c035f9`. This record is the only change
after that candidate. Authority is the [accepted plan](VGAS-18_PLAN.md),
including addendum rulings 4 and 6.

## Per-item evidence

- **A1.** The cutoff cases at `retrieval_test.exs:531` move the support clock
  to the exact lease or absolute deadline during the embedding settlement
  hook. The separate embedding clock stays fixed. Rank's measurement
  callback sees no statement, search returns empty unavailable, and the
  dispatched attempt still settles 8 nano-USD. Validation denies the
  previously issued citation and its link with zero further wire hits.
  Rank and validation have one-microsecond-before controls.
- **A2.** At `retrieval_test.exs:1153`, the real semantic and lexical branches
  produce opposing ranks for two UUID-ordered revisions. Their RRF scores
  are both 123/3782. The private sort has a TEST-only wrapper so the same
  SQL rows exercise both input permutations. The deletion mutant passed the
  projected-order assertion for the SQL order and failed the permutation
  assertion.
- **A3.** At `retrieval_test.exs:600`, the fixture changes only the embedding
  inhibit after the claim commits. It checks support eligibility and the
  claim independently. The attempt is REJECTED without a dispatch marker,
  the reservation is RELEASED, and there is no ledger charge or wire hit.
  The article control is `editorial_test.exs:490`.
- **A4, partial.** At `retrieval_test.exs:657`, a fake adapter parks after
  wire entry and lets a committed change land before rank. The validation
  cases issue and verify citations first, then reject the original citation
  selection after the change. Mixed sets use an otherwise current citation
  to prove all-or-nothing validation. Cases cover revocation, expiry
  equality, published grant withdrawal, active index generation, index
  epoch, both profile fields, ownership epoch, and signed human takeover.
  The lock test at `retrieval_test.exs:701` observes the separate editorial
  connection blocked by the rank transaction via `pg_blocking_pids`.
  A third connection gets SQLSTATE `55P03` from `FOR UPDATE NOWAIT`.
  The original projection finishes, the editorial transaction commits,
  and validation denies the original linked citation.
- **A5.** At `retrieval_test.exs:30`, a harmless SQL statement proves the
  Repo event handler is active. Search, validation and a failed search
  emit neither retrieval statement events nor the synthetic sentinel.
  The test also scans captured logs without emitting them. On the base
  source the new test failed with exit 2. The final helper opts out of
  telemetry on both the timeout statement and the retrieval statement.
  At `retrieval_test.exs:1036`, the TEST-only process-scoped callback
  performs EXPLAIN inside qualification. It reports plan node types, row
  counts and timings for 20 samples. The control-lock interval runs
  through commit and includes the EXPLAIN time. Both branch limits are
  checked on every sample. Repo telemetry supplies only the control-lock
  and commit timing markers for this measurement.

## Deviations and pending gates

- The isolated current-grant predicate experiment in A4 cannot use the
  proposed raw deletion and preserve the supported version-2 pin.
  `Configuration.current_revision/1` recomputes the hash before the query
  (`lib/voelgoed_ai/support/configuration.ex:427`), and the hash includes
  the current grant list (`configuration.ex:504`, `configuration.ex:521`).
  Qualification also requires the live revision ID to equal the pin
  (`retrieval.ex:374`–`378`), so a deletion removes the row from both
  grant aliases (`retrieval.ex:39`–`41`). The test uses supported grant
  removal and publication. The single-join mutant survived.
  A revised isolation criterion requires an orchestrator decision.
- The revoke action clears the current pointer and invalidates the index
  (`lib/voelgoed_ai/knowledge/editorial.ex:364`–`379`). The revision
  constraint requires revoked rows to have no active index
  (`priv/repo/migrations/20261126090442_vgas_003b2a_publication.exs:23`).
  Removing only the published-status predicate survives these independent
  restrictions. The revocation regression proves denial by the full live
  recheck with the real revoke action.
- The late UNKNOWN vector mutant was run second as requested and survived.
  The existing test at `retrieval_test.exs:1003` also disables support
  automation. The accepted plan assigns the missing valid-support-clock
  proof to PR B1. PR A leaves the settlement guard intact.
- Independent review, hosted exact-head CI, and Plane reconciliation
  remain with the orchestrator. D1 and D2 belong to VGAS-15 under addendum
  ruling 6.

## Commands and results

Mise provided Erlang 29.1.2 and Elixir 1.20.5. The lockfile and each
installed dependency's `mix.exs` agreed on ReqLLM 1.31.0, Req 0.7.5,
Ash AI 1.5.6 and Ecto SQL 3.14.0. The installed Ecto SQL adapter uses
`Keyword.get(opts, :telemetry_event, event_name)` to choose the event
and handles the log option separately. The installed ReqLLM embedding
and Ash AI embedding model source use ReqLLM's embedding caller, while
Req's retry step checks `max_retries`. The existing fake transport
options were preserved.

Every database invocation used the supplied runner with a private
steps file and this command. The runner set `MIX_ENV=test` and created
a disposable PostgreSQL 18.7 instance with pgvector 0.8.7. The first
step in each invocation was
`HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked`, which exited 0.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$vgas_worktree" "$vgas_steps" "$vgas_port"
```

The full suite ran on port 55434 after checking the port before each
run. Both commands and their runner invocations exited 0.

| Command | Passed | Failed | Skipped | Excluded |
| --- | ---: | ---: | ---: | ---: |
| `mise exec -- mix test --seed 103` | 521 | 0 | 5 | 1 |
| `mise exec -- mix test --seed 8125` | 521 | 0 | 5 | 1 |

The five skips are the F04 disposable fixture spike tests. The
predecessor migration lane test is excluded by the normal test helper.
The full suite's synthetic reserve-commit failure log is expected fault
injection.

## Mutation tests

Each mutant ran in a detached checkout of the executable candidate on
port 55435. The first four rows are the PR #13 survivors, in the
requested order. Every trial ran `mise exec -- mix test <locator> --seed 0`,
where `R` below is `test/voelgoed_ai/knowledge/retrieval_test.exs` and
`E` is `test/voelgoed_ai/knowledge/editorial_test.exs`. A wrapper captured
the actual ExUnit exit and restored the original source after each run.
Git status was clean before and after every trial.

| Guard changed | Test | Intended failure or observed survivor | Mix exit |
| --- | --- | --- | ---: |
| Delete the common cutoff comparison | R:531 | Rank must return empty unavailable and validation must return empty denied at equality | 2 |
| Allow late UNKNOWN settlement to return a query vector | R:1003 | Survived. The test still lost support authorization before rank. PR B1 owns the test that holds support authorization valid. | 0 |
| Drop UUID ordering at equal RRF scores | R:1153 | Both permutations must produce the same ascending order | 2 |
| Delete the query dispatch inhibit check | R:600 | Query must be unavailable after inhibit | 2 |
| Accept equality at the common cutoff | R:531 | Reject the exact cutoff at both boundaries | 2 |
| Use the lease as the only cutoff | R:531 | Reject the exact absolute deadline at both boundaries | 2 |
| Use the absolute deadline as the only cutoff | R:531 | Reject the exact lease at both boundaries | 2 |
| Skip the cutoff only in rank | R:531 | Rank must return empty unavailable at the cutoff | 2 |
| Skip the cutoff only in validation | R:531 | Validation must return empty denied at the cutoff | 2 |
| Reverse UUID ordering at equal RRF scores | R:1153 | The ranked projections must use ascending UUIDs | 2 |
| Delete the article dispatch inhibit check | E:490 | Article attempt must be rejected and the hold released uncharged | 2 |
| Accept evidence at expiry equality | R:657 | Rank must return only the decoy and validation must deny the expired citation | 2 |
| Drop the active generation match in the embedding join | R:657 | Rank must return only the decoy | 2 |
| Ignore index epoch in projection equality | R:657 | Validation must deny the citation with the previous epoch | 2 |
| Drop the revision profile match | R:657 | Rank must omit the target and validation must deny the old citation | 2 |
| Drop the embedding profile match | R:657 | Rank must omit the target and validation must deny the old citation | 2 |
| Ignore the current ownership epoch in the support fence | R:657 | Rank and validation must reject the stale claim | 2 |
| Allow any valid citation to qualify the entire set | R:657 | Validation must deny a mixed stale/current set | 2 |
| Remove applicability from the semantic branch and its final projection | R:194 | Expect exactly the two eligible revisions | 2 |
| Apply semantic applicability after LIMIT | R:194 | Expect the eligible semantic-only revision to survive the branch limit | 2 |
| Remove applicability from the lexical branch and its final projection | R:194 | Expect exactly the two eligible revisions | 2 |
| Apply lexical applicability after LIMIT | R:194 | The valid lexical hit must keep its first-place fused rank | 2 |
| Remove Repo telemetry suppression on the retrieval statement | R:30 | No retrieval event may reach the handler | 2 |
| Remove Repo telemetry suppression on the statement timeout | R:30 | No retrieval helper event may reach the handler | 2 |
| Remove the live revision ID filter from the grant join | R:657, R:287 | Survived. The supported pin still requires its matching grant list and the pinned join remains mandatory. | 0 |
| Remove the published-status predicate | R:657 | Survived. Revocation clears the pointer and active index independently. | 0 |
| Remove the expiry predicate | R:657 | Rank must return only the decoy and validation must deny the expired citation | 2 |
| Accept issued citations without requiring their current projection to match | R:657 | Validation must deny the revoked citation and other stale projections | 2 |

Of 28 effective mutations, 25 failed at the expected assertions and
three survived. The first two runs of the four pre-LIMIT operators used
a search string with the wrong heredoc indent. They left the applicability
predicate intact. The results above are from the corrected operators,
which construct the second CTE from the source and require an exact
replacement. For the post-LIMIT variants the final eligibility join
remains in place.

## Restored source checks

The fresh migration, snapshot check and forced TEST compiles below ran
on the restored executable candidate with port 55435. The formatter
also ran successfully outside the runner.

| Command | Exit |
| --- | ---: |
| `mise exec -- mix ecto.migrate --strict-version-order` | 0 |
| `mise exec -- mix ash.codegen --check` | 0 |
| `mise exec -- mix format --check-formatted` | 0 |
| `ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` | 0 |
| `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors` | 0 |
| `HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked` | 0 |
| `mise exec -- mix deps.unlock --check-unused` | 0 |
| `HEX_OFFLINE=1 mise exec -- mix hex.audit` | 0 |
| `git diff --check 3090b1f..HEAD` | 0 |
| `python3 .github/scripts/plan_tests.py` | 0 |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='3090b1f..HEAD' .` | 0 |
| `git diff --exit-code 3090b1f -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots` | 0 |
| `rg 'authorize\?: false' lib` | 1 (zero matches) |
| `cmp docs/plans/VGAS-18_PLAN.md /home/jcschoeman96/.t3/userdata/attachments/VGAS-18_PLAN.md` | 0 |

The advisory command ran separately in offline mode and reported no
retired or security advisory packages in its available data. The
migration and snapshot paths are byte-identical to the base. There is
no new upgrade DDL to exercise.

The supplementary non-TEST compiles used the following commands on
both the candidate and the exact base. Each exited 1 under
`--warnings-as-errors`. The application warning file, line and column
lists matched at each scheduler count. The inherited warnings include
the non-TEST fixture guard comparisons in `support/ownership.ex:96`
and `knowledge/editorial.ex:437`. TEST compilation passed above.

```sh
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
```

The focused commands differed only in the seed. They ran on port
55435 after the mutation checkout was restored.

```sh
mise exec -- mix test test/voelgoed_ai/knowledge/{retrieval,editorial,publication}_test.exs test/voelgoed_ai/governance/embedding_accounting_test.exs test/voelgoed_ai/support/{workflow,delivery_recovery,ingress}_test.exs test/voelgoed_ai/{ash_ai,inference,durable,chatwoot}_feasibility_test.exs --seed "$vgas_seed"
```

| Seed | Passed | Failed | Exit |
| ---: | ---: | ---: | ---: |
| 0 | 304 | 0 | 0 |
| 103 | 304 | 0 | 0 |
| 8125 | 304 | 0 | 0 |

The separate restored article inhibit run,
`mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:490 --seed 0`,
exited 0 with one passed and 32 excluded. The restored runner exited 0
and removed its container and volume.

The decoy remains individually valid after changes limited to the
target article. Grant publication and ownership changes invalidate
the old claim as a whole, so their mixed-citation cases establish
whole-claim denial.

## Corrections from review

- The grant-join mutant leaves three fences that keep SQL parameters
  `$1` and `$2` on the same assistant revision. Retrieval checks the pair in
  `lib/voelgoed_ai/knowledge/retrieval.ex:376`. The valid-run check at
  `lib/voelgoed_ai/support/run_processing.ex:490` also requires the active
  revision. The assistant `security_epoch` fence at
  `lib/voelgoed_ai/support/ownership.ex:103` rejects the old pin after
  publication increments the epoch at
  `lib/voelgoed_ai/support/configuration.ex:233`.
- The `article_revisions_active_index` constraint in
  `priv/repo/migrations/20261126090442_vgas_003b2a_publication.exs:20–34`
  forbids an active generation or profile for every non-published status.
