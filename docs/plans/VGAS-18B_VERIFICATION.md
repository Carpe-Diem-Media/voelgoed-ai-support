# VGAS-18 PR B verification

Base `e7aeca7b534a4e4b325e7a2d8092ebdc25e376d6`. Implementation
commit `f83e0a3b1a372b2983ebc3f4601b079c278a8688`. Branch
`test/vgas-18b-inference-settlement`. The
[accepted plan](VGAS-18_PLAN.md) and its 2026-11-26 addendum govern
B1–B3. The change is confined to tests, test helpers and verification
records. The transport endpoints are deterministic fakes. No live
generation, evidence-bearing decision or delivery is wired in this slice.

## B1. Split-clock query settlement

The query tests align support and embedding clocks through dispatch and
park the adapter before decoding. In the **split-clock UNKNOWN case**,
only the embedding clock moves, by 35 days. The same support authority
still qualifies before both its lease and its absolute deadline, with the
original claim generation and an eligible article. Two sweeps while
the adapter is parked record `deadline` on the attempt and reservation.
They leave the 81,920 nano-USD ceiling held with zero ledger entries.
The response has request ID `req_query_settlement`, seven input tokens
and a vector distinct from the article fixture's vector. There is no
rank callback or returned evidence. A further sweep leaves one
`settlement` entry of 18 nano-USD in the original day and month.
The RUNNING control gets evidence and records the same amount. The
existing rollover regressions run in the same focused set.

The article closure test commits the original `settlement` at
81,920 nano-USD. The later provider response appends one `late-usage`
entry of −81,912 linked to that exact entry ID. The original ledger row
is unchanged and the net charge and origin-window totals are 8 nano-USD.
Repeated closure, recovery and index entry leave both entries intact.

Provider-evidence replay and contradictory evidence are handled by
private `settle/6` clauses in
`lib/voelgoed_ai/intelligence/embedding.ex:601–677`. The only current
article entry claims a queued embedding and calls settlement once
(`embedding.ex:112–148`). A second index invocation cannot submit that
response again. The test repeats the supported public operations. A
direct replay or contradictory-response test would need a new
entry point or a test hook into private settlement. This slice leaves
that direct coverage open.

## B2. Concurrent dispatch and recovery

The test parks caller A after the committed claim. An independent
transaction takes the inference row lock. PostgreSQL reports that A is
blocked by the lock holder and that caller B is blocked by A. A separate
connection attempting `FOR UPDATE NOWAIT` reports SQLSTATE `55P03`.
After release, one authorization and one adapter entry occur, outside a
transaction. The contender returns unavailable.

A sweep before expiry leaves the attempt running. A separate lock wait
shows that when the scan selects a due attempt and the clock is corrected
while recovery is blocked, recovery rechecks the deadline after obtaining
the row lock. A sweep at expiry holds the consumed reservation, preserves
the original attempt, generation, dispatch fence and timestamp, and
prevents a reclaim from sending. The late provider result settles 8
nano-USD and returns no evidence. The separate parked pre-dispatch case
expires and releases with zero wire entries. The T03 admission/day/month
lock-order regression runs in the focused set.

## B3. Wire retries and usage

Query embedding, article embedding and the Ash AI Responses feasibility
path exercise malformed JSON bytes with JSON content type, correlated
usage with an invalid result, HTTP 503 and Req transport timeout. The
fakes return immediately and observe one wire entry and an effective
`max_retries: 0`. A malformed result with trustworthy usage has one
settlement and no usable result. Missing trustworthy usage or ambiguous
transport leaves the ceiling held.

ReqLLM 1.31.0 replaces `retry: false` in
`deps/req_llm/lib/req_llm/step/retry.ex:65–79`. The embedding schema in
`deps/req_llm/lib/req_llm/provider/options.ex:514–518` leaves the nested
Req option effective. Generation uses the generation schema with its
top-level default of three at `provider/options.ex:271–275`.
`providers/openai.ex:850–874` passes those processed options into the
retry step, where they take precedence. Removing the nested option alone
is therefore equivalent for the Ash AI caller with explicit top-level
zero. The effective generation mutant restores the top-level value of
three and keeps the nested zero. The future production caller remains
a VGAS-15 prerequisite.

## PR A review corrections

The rank-measurement callback reports the original failure and
stacktrace to the test process, which raises it after the search.
The production rescue is untouched. Both documentation corrections are
in the [PR A record](VGAS-18A_VERIFICATION.md#corrections-from-review).

## Mutation evidence

Each test command used `mise exec -- mix test <selector> --seed 0`
with port 55435. The helper applied one mutation, ran ExUnit, recorded
its exit and restored the source before returning. The helper itself
exited 0 after recording the test outcome. The first batch reused a
database. An intentional failure left fixtures behind, and subsequent
bootstrap failures in that batch were discarded. The affected
mutations were rerun on fresh databases.

Selectors below are relative to `test/voelgoed_ai/`.
Production file paths in the guard column are relative to
`lib/voelgoed_ai/`.

| Changed guard or write | Selector | Observed assertion or exclusion | ExUnit exit |
| --- | --- | --- | ---: |
| Broaden the query vector clause to UNKNOWN, `intelligence/embedding.ex:681` (the old E:678 survivor) | `knowledge/retrieval_test.exs:1218` | UNKNOWN returns evidence instead of unavailable with an empty result. RUNNING control passes. | 2 |
| Mark consumed UNKNOWN exposure released, `governance/embedding_accounting.ex:115–126` | `knowledge/retrieval_test.exs:1218` | Expected UNKNOWN reservation with full ceiling and no charge. RUNNING control passes. | 2 |
| Use the completion date for the settlement windows, `governance/embedding_accounting.ex:224` | `knowledge/retrieval_test.exs:1218` | Original day and month lack the 18 nano-USD increment. RUNNING control passes. | 2 |
| Overwrite the original charge instead of appending the correction, `governance/embedding_accounting.ex:287–304` | `knowledge/editorial_test.exs:505` | Expected a second ledger row with the linked correction and received none. | 2 |
| Change the correction key from `late-usage`, `governance/embedding_accounting.ex:189` | `knowledge/editorial_test.exs:505` | Expected the `late-usage` key and received `late-correction`. | 2 |
| Use the attempt ID as the correction parent, `governance/embedding_accounting.ex:190` | `knowledge/editorial_test.exs:505` | The write returns `:indexing_storage` before the linkage assertion. The qualified correction FK requires a parent in the same reservation, and the branch sees only the original entry. The mutation is excluded from the assertion-kill count. The baseline checks the parent ID directly. | 2 |
| Omit UNKNOWN from exposure, `governance/embedding_accounting.ex:306–310` | `knowledge/editorial_test.exs:505` | Expected no candidate reservation under the held ceiling and found a new settled reservation. | 2 |
| Double the charge credited to the day, `governance/embedding_accounting.ex:224` | `knowledge/editorial_test.exs:505` | Day shows 163,840 nano-USD where one ceiling charge should produce 81,920. | 2 |
| Permit a second dispatch on a consumed attempt, `intelligence/embedding.ex:522` | `knowledge/retrieval_test.exs:492` | The second consumption should return unavailable and returned an authorization. | 2 |
| Skip the deadline recheck after acquiring the recovery lock, `intelligence/embedding.ex:186` | `knowledge/retrieval_test.exs:527` | The post-lock assertion expects RUNNING and a reserved ceiling. The mutation returns UNKNOWN. | 2 |
| Route the committed marker through release, `intelligence/embedding.ex:189–193` | `knowledge/retrieval_test.exs:527` | The at-expiry sweep should succeed. The application release guard refuses the consumed attempt, returning `:indexing_storage`. | 2 |
| Return a stale vector after recovery, `intelligence/embedding.ex:681` | `knowledge/retrieval_test.exs:1218` | Same operator and test as the former E:678 survivor. Earlier guard checks cannot mask it because the support claim remains valid. | 2 |
| Release the consumed decode failure, `governance/embedding_accounting.ex:115–126` | `knowledge/retrieval_test.exs --only transport_fault:true` | The malformed-JSON case finds RELEASED where UNKNOWN is required. | 2 |
| Remove the nested embedding retry limit, `intelligence/embedding_transport.ex:31` | `knowledge/retrieval_test.exs --only retry_fault:true` | Both 503 and timeout receive a second wire message. | 2 |
| Remove the nested embedding retry limit through article indexing | `knowledge/editorial_test.exs:237` | The article 503 case receives a second wire message. | 2 |
| Remove only the nested generation retry limit, `test/support/feasibility/transport_evidence.ex` | `ash_ai_feasibility_test.exs:317` | All four tests pass with the top-level zero in effect. Equivalent for this caller. | 0 |
| Restore top-level generation retries to the provider default, `test/support/feasibility/inference.ex:38` | `ash_ai_feasibility_test.exs:317` | The 503 and timeout cases receive a second provider hit. Decode cases fail the adapter option assertion. | 2 |

The two generation operators were rerun against the committed test
code. Both forced TEST compiles then exited 0 on restored source.
`mise exec -- mix test test/voelgoed_ai/ash_ai_feasibility_test.exs:317 --seed 0`
exited 0 with 4 passed and 14 excluded. The restored runner exited 0.

The compound foreign key for correction parents is
`priv/repo/migrations/20261126063108_vgas_003_embedding_accounting.exs:530–532`.

## Commands on the restored candidate

Mise reported Erlang 29.1.2 and Elixir 1.20.5-otp-29. The lockfile and
installed package sources agreed on ReqLLM 1.31.0, Req 0.7.5, Ash AI
1.5.6 and Ecto SQL 3.14.0.

The PostgreSQL 18.7 / pgvector 0.8.7 tests used the disposable runner.
Each step file started with
`HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked`, exit 0.
The port was checked with `ss -ltn | grep 5543` before each run. The
focused set and mutations used 55435. Each full suite used a fresh
database on 55434.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$vgas_worktree" "$vgas_steps" "$vgas_port"
```

| Command | Exit |
| --- | ---: |
| `mise exec -- mix format --check-formatted` | 0 |
| `ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` | 0 |
| `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors` | 0 |
| `mise exec -- mix ecto.migrate --strict-version-order` | 0 |
| `mise exec -- mix ash.codegen --check` | 0 |
| `HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked` | 0 |
| `mise exec -- mix deps.unlock --check-unused` | 0 |
| `mise exec -- mix hex.audit` (separate invocation) | 0 |
| `git diff --check e7aeca7..HEAD` | 0 |
| `python3 .github/scripts/plan_tests.py` | 0 |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e7aeca7..HEAD' .` | 0 |
| `git diff --exit-code e7aeca7 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots` | 0 |
| `rg 'authorize\?: false' lib` | 1, zero matches |

The dependency audit found no retired or security advisory packages.
The migration and snapshot paths are byte-identical to the base.
The ordinary fresh migration ran against empty disposable storage.
There is no new upgrade DDL.

The focused set includes both inhibit regressions, T03, the independent
lock tests, and the article rollover and closure cases.

```sh
mise exec -- mix test test/voelgoed_ai/knowledge/{retrieval,editorial,publication}_test.exs test/voelgoed_ai/governance/embedding_accounting_test.exs test/voelgoed_ai/support/{workflow,delivery_recovery,ingress}_test.exs test/voelgoed_ai/{ash_ai,inference,durable,chatwoot}_feasibility_test.exs --seed "$vgas_seed"
```

| Seed | Passed | Failed | Exit |
| ---: | ---: | ---: | ---: |
| 0 | 316 | 0 | 0 |
| 103 | 316 | 0 | 0 |
| 8125 | 316 | 0 | 0 |

The synthetic reserve-commit error emitted during the focused and full
runs is expected fault injection. The focused runner exited 0.

The supplementary non-TEST checks both exited 1 on inherited application
warnings, including `support/ownership.ex:96`. PR A records that the
same non-TEST warnings occurred at its base. The B diff of
`lib`, `config`, `mix.exs` and `mix.lock` is empty, and the non-TEST
compiler excludes `test/support`.

```sh
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors
```

## Full suites

| Command | Passed | Failed | Skipped | Excluded | Exit |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mise exec -- mix test --seed 103` | 538 | 0 | 5 | 1 | 0 |
| `mise exec -- mix test --seed 8125` | 538 | 0 | 5 | 1 | 0 |

Both full-suite runner invocations exited 0 and removed their
containers and volumes. The five skips are the F04 disposable
fixture spike tests. The one exclusion is the predecessor migration
lane test, which the standard test helper excludes.

## Handoff

Independent review and exact-head Application CI remain pending.
This record covers the author-side tests for PR B. The owner-approved
plan assigns the production generation caller and evidence-bearing
decision and delivery checks to VGAS-15.
