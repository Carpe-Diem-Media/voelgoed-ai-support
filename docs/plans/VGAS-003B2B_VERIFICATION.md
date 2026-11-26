# VGAS-003 B2b verification

Base `86e44a76381787b578cea8540f6500b19cdf5a97` includes B2a from PR #12.
The accepted plan and orchestrator addendum govern the slice. T03 covers
reservation and T08 covers settlement. Amendments A-008, A-010 and A-011
permit local fixture development and retain the external approval gates.
[B2 plan](VGAS-003B2_PLAN.md),
[resource contracts](../spec/VGAS_RESOURCE_CONTRACTS_v1.0.0.md),
[amendments](../spec/VGAS_SPEC_v1.0.0.md).

Implementation commit `968abf0a666362ffcc59e87e68dc57d63de67382`.
The tests and implementation were verified together at
`3005ac20af6d5846baaf6cb139ee3d5e34039ee7`.

## Lifecycle and authority

- TEST issues separate, process-bound search and validation capabilities for
  a qualified inbox, running claim, published assistant pin, requested
  locale and verified applicability. The action rejects a caller-owned
  transaction. The fixed-reply flow continues through its original processing and delivery actions.
- Each search qualifies current ownership, control, assistant configuration
  and eligible knowledge before reserving. T03 commits one RUNNING query
  attempt and one RESERVED hold per run. A reclaim keeps the same one-attempt
  limit. A denied price, cap or transaction rolls back both writes.
- The next transaction rechecks the claim and eligible scope before it
  consumes the dispatch fence. Only the committed dispatch invokes the
  bounded ReqLLM fixture transport. Query text and vectors stay in memory.
- T08 settles correlated integer usage against the frozen origin windows.
  Invalid vectors still charge known usage. A deadline wins an unconsumed
  fence and releases the hold. Dispatch uncertainty moves the attempt and
  reservation to UNKNOWN. A late correlated result can settle the original
  windows after a sweep, without restoring answer permission. Conservative
  closure requires the admin and synthetic approval. Replay leaves one
  settlement. Over-reserve and overflow use the inherited inhibit.
- Exact cosine and `simple` FTS each rank a shared eligible set before their
  ten-row limits. The action compares RRF scores with integer arithmetic and
  returns at most four projections. A validation capability rechecks issued
  citations, approved text, links and policy/index epochs against the current
  rows. A later remote send would need its own revalidation.
- Publisher deadline and stale-request failures now write audit events in
  the same transaction as generation invalidation. The reindex failure
  preserves the active generation. A returned Oban enqueue error aborts the
  final READY change and leaves the pre-existing hold for recovery.

The scoped corpus exposed a B1 serialization error. Jason cannot encode a
list of tuples. The serializer emits ordered two-item arrays for the
applicability pairs and preserves unscoped bytes. The approved fixture
profile remains the same. DEV compiles deny-only retrieval and rollback
request code. TEST compiles the scoped paths and fixture issuer.

## Commands and outcomes

The disposable runner used PostgreSQL 18.7 and pgvector 0.8.7 at
`127.0.0.1:55434`. The application role was NOSUPERUSER and NOCREATEDB.
The runner set `MIX_ENV=test` and `VGAS_VERIFY_PGVECTOR=true`, injected
disposable database credentials, and unset `OPENAI_API_KEY`. Two early
startup attempts reached the container entrypoint's temporary Unix socket.
Subsequent runs used the supplied runner with its readiness probe pointed
at the container's TCP listener:

```sh
bash <(sed 's/pg_isready -U postgres/pg_isready -h 127.0.0.1 -U postgres/' /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh) "$PWD" "$steps" 55434
```

The runner removed the disposable containers and volumes. Verification used
the same image, database allocation and role throughout.

The migration and snapshot files came from
`mise exec -- mix ash.codegen vgas_003b2b_retrieval`, exit 0. The down
guard was added to the generated migration. The following checks exited 0
with the Mise pins, Elixir 1.20.5 and OTP 29.1.2. Runtime tests used
Ash 3.38.1, AshPostgres 2.15.2, ReqLLM 1.31.0, Oban 2.24.2 and
Postgrex 0.23.0.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix deps.get --check-locked
mise exec -- mix hex.audit
mise exec -- mix compile --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 1" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force
ELIXIR_ERL_OPTIONS="+S 2" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix ecto.migrations
mise exec -- mix ecto.rollback --step 1
mise exec -- mix ecto.migrate --strict-version-order
```

The following TEST commands exited 0:

- `mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs` passed
  six tests and excluded the separate predecessor-upgrade probe.
- `mise exec -- mix test test/voelgoed_ai/knowledge/retrieval_test.exs --seed 0`
  passed all 22 retrieval tests on the final test content.
- `mise exec -- mix test test/voelgoed_ai/knowledge test/voelgoed_ai/governance/embedding_accounting_test.exs --seed 0`
  passed 74 tests on the committed candidate.
- `mise exec -- mix test --seed 0` and `mise exec -- mix test --seed 103`
  each passed 440 tests, skipped five inherited feasibility tests and
  excluded the separately seeded upgrade probe.
- An inherited T03 trigger test deliberately causes a synthetic reservation
  commit failure. Its assertions confirm the intended rollback.

`MIX_ENV=dev mise exec -- mix compile` exited 0. The DEV build retained
the inherited fixture-gate warnings in B1 embedding and VGAS-002 support
code. B2a's unused argument warning in Publication and unreachable match
warning in Editorial disappeared. The following DEV beam probe exited 0:

```sh
env -u OPENAI_API_KEY mise exec -- elixir -pa _build/dev/lib/voelgoed_ai/ebin -e '
alias VoelgoedAi.Intelligence.Embedding
alias VoelgoedAi.Knowledge.{Publication, Retrieval}
{:module, Retrieval} = Code.ensure_loaded(Retrieval)
false = function_exported?(Retrieval, :with_fixture, 2)
false = Retrieval.match?(%Retrieval{ref: make_ref()}, %{}, [])
{:error, :disabled} = Embedding.query(make_ref(), "Synthetic FAQ", fn _ -> raise "unexpected callback" end)
{:error, :rollback_disabled} = Publication.rollback_available()
'
```

`git diff --check 86e44a7...HEAD` and
`git diff --exit-code 86e44a7...HEAD -- mix.exs mix.lock config .github`
exited 0. `rg 'authorize\?: false' lib` exited 1 with zero matches.
`mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts="86e44a7..HEAD"`
exited 0 with no leaks. This slice uses the current Compose configuration.

## Migration rehearsal

1. Fresh `mise exec -- mix ecto.migrate --strict-version-order`,
   `mise exec -- mix ecto.rollback --step 1`, and reapply with
   `mise exec -- mix ecto.migrate --strict-version-order` exited 0.
2. A second disposable database migrated through B2a with
   `mise exec -- mix ecto.migrate --strict-version-order --to 20261126090442`.
   `psql -XqAt -v ON_ERROR_STOP=1 -f` loaded the VGAS-001 predecessor and
   both modes of the B1 publication fixture. A synthetic B2a seed added a
   current published revision pointer, a published assistant and grant, and
   a terminal support run. Each seed command exited 0.
   [VGAS-001 fixture](../../.github/scripts/vgas001_upgrade_fixture.sql),
   [B1 publication fixture](../../test/fixtures/vgas_003b1_publication.sql).
3. The seeded upgrade, down and reapply each exited 0. After every change,
   `cmp` exited 0 on digests of ordered JSONB aggregates of the existing
   revisions, pointers, ready vectors, attempts, reservations, ledger,
   spend windows, audit, grants and support history. The digests excluded
   only the new nullable query-attempt columns.
4. The rehearsal inserted a synthetic rejected query attempt and verified
   the partial unique index rejected a second attempt for its support run.
   `mise exec -- mix ecto.rollback --step 1` exited 1 with PostgreSQL
   `P0001` and `B2b rollback refused: query or publisher failure history exists`.
   The query attempt survived. The guard preserves both query attempts and
   publisher failure audit history before removing the newer constraints.

## Mutation checks

The first regression run against B2a exited 2. Thirteen of sixteen tests
passed. The three failures identified the missing retrieval actions, the
missing deadline audit, and the READY transaction that did not handle a
returned enqueue error.

Each mutant ran individually on the committed candidate. The command was
`mise exec -- mix test <locator> --seed 0` using the locators below.
Each mutant exited 2 with the expected failing assertion. The runner
restored `lib` with `git checkout -- lib` and verified empty
`git status --porcelain` after every experiment.

- `test/voelgoed_ai/knowledge/retrieval_test.exs:123` killed four mutants.
  Each branch was tested with eligibility removed and with eligibility
  moved after its limit. Each run failed one test and excluded 21.
- `test/voelgoed_ai/knowledge/retrieval_test.exs:29` killed two mutants.
  One bypassed the current-row revalidation and the other ignored the
  index epoch. Each run failed one test and excluded 21.
- `test/voelgoed_ai/knowledge/retrieval_test.exs:421` killed redispatch
  of an already consumed attempt. One test failed and 21 were excluded.
- `test/voelgoed_ai/knowledge/retrieval_test.exs:503` killed removal
  of the nested ReqLLM retry limit. Six tests failed and 16 were excluded.
- `test/voelgoed_ai/knowledge/retrieval_test.exs:528` killed release
  of a consumed UNKNOWN hold. One test passed, one failed and 20 were excluded.
- `test/voelgoed_ai/knowledge/retrieval_test.exs:356` killed two lock
  mutants. One reversed the day/month order and the other took spend locks
  before the admission row. Each run failed one test and excluded 21.
  The baseline used `pg_blocking_pids` and a third connection's
  `FOR UPDATE NOWAIT` to prove the order independently of the control lock.
- `test/voelgoed_ai/knowledge/publication_test.exs:389` killed
  removal of publication/reindex failure audit. The first script matched
  two call sites, so it applied no mutation. A narrowed edit of `fail/3`
  ran successfully and failed one test with 15 excluded.
- `test/voelgoed_ai/knowledge/publication_test.exs:263` killed rollback
  while reindex was pending. One test failed and 15 were excluded.
- `test/voelgoed_ai/knowledge/publication_test.exs:218` killed checking
  only the capability reference. One test failed and 15 were excluded.
- `test/voelgoed_ai/knowledge/publication_test.exs:205` killed ignoring
  the returned enqueue error. One test failed and 15 were excluded.

All 15 mutants were killed. After restoring the code, TEST compilation
with warnings as errors and the 74-test focused suite exited 0.

## Ranking and lock timing

The seed-0 run used 256 published articles, 192 eligible English variants,
64 scope exclusions, 1,536 dimensions and 20 fresh support runs. Each
ranked query took ten rows per branch and returned four evidence items
after RRF. These timings describe the local fixture workload in
microseconds:

- End-to-end p50 52,340 and p95 55,828.
- Control lock p50 13,063 and p95 16,536. The test measured from the return
  of the control row's `FOR UPDATE` through completion of the ranking
  transaction's commit.
- Cosine branch p50 2,611 and p95 3,792 in the separate `EXPLAIN ANALYZE`
  repetitions.
- Lexical branch p50 3,392 and p95 3,554 in those repetitions.

The redacted plan below reports node types and actual row counts. It omits
bound values, raw content, IDs and expression details.

```text
Eligible CTE                             192 rows
  Nested Loop grant/collection/article/revision/active-variant joins
  Bitmap Heap/Index Scans and Function Scans for variants and applicability
Rank join and projection                  10 rows in this fixture
  WindowAgg -> Limit -> Sort -> CTE Scan  10 / 10 / 10 / 192 rows
  WindowAgg -> Limit -> Sort -> Nested Loop
    CTE Scan, Aggregate, Function Scan   10 / 10 / 10 / 192 rows
  CTE Scan for projection               192 rows
Application RRF                           4 projected evidence items
```

## Recovery and owner decisions

- For uncertain query cost, inspect the durable attempt, dispatch timestamp,
  reservation and original UTC windows. The due sweep releases only a
  proven unconsumed fence. It moves a consumed fence to UNKNOWN and
  preserves exposure across rollovers. Keep the original attempt ID and
  reconcile trusted, correlated provider usage against it. A conservative
  closure is available only to the approved TEST admin fixture.
- For failed publication, inspect the publisher failure event and current
  pointer. After correcting the cause, a reviewer can confirm that pointer
  and request a fresh generation. A failed reindex preserves the previous
  active index subject to its usual eligibility checks.
- Same-profile rollback requires retained complete vectors, the current
  epoch and an evaluation receipt. Restore terminal content through a new
  reviewed revision. Keep automation disabled during restore and reconcile
  outstanding holds before resuming authorised work.
- VGAS-7 owns live provider limits, prices, reconciliation and quality.
  VGAS-11 owns the corpus, applicability vocabulary and public links.
  VGAS-8 carries the inherited release-build and inbox gates. The owner
  still needs to approve real rollback evaluation and sensitive-content
  routing policy.

## Completion assessment

Task type IMPLEMENTATION. VGAS-003 B2b delivers query accounting,
published-knowledge retrieval and evidence validation under a synthetic
support claim, with the four B2a review follow-ups. This is an author
self-assessment.

Seven of seven deliverable criteria verified:

1. A TEST-only process-bound capability qualifies the exact support run,
   inbox, claim and published assistant pin. The DEV gate probe and
   retrieval authorization regressions passed.
2. One reservation and one dispatch per run, trusted settlement, conservative
   recovery and ordered admission/spend locks. The real PostgreSQL,
   ReqLLM fixture, rollover and lock tests passed.
3. Both rank branches use the same eligibility checks before LIMIT.
   Bilingual fixtures, scope and grant exclusions, active vectors and
   deterministic ties passed. The fixture benchmark recorded lock timing.
4. Validation accepts only current issued citations and their approved
   links. Forgery, stale epochs and a real rollback to an earlier generation
   passed their rejection tests.
5. One generated migration with three snapshots and a history-preserving
   down guard. Fresh, seeded upgrade, down/reapply and refusal rehearsals
   passed.
6. Publisher failure audit, stale rollback, capability binding and returned
   enqueue error follow-ups. The positive and mutation tests passed.
7. Both full test seeds, snapshot and dependency checks, compile-order
   checks, diff and secret scans, and the mutation checks passed.

- Implementation Score **10/10** for the assigned local slice
  (requirements 4/4, verification 3/3, correctness 2/2, handoff 1/1).
- Confidence Score **95%** based on the PostgreSQL runs and mutation tests.
  Runtime timing describes a local synthetic workload.
- Verification Status **VERIFIED** for author-side B2b behavior and the
  disposable migration checks. **NOT_VERIFIED_FOR_MERGE** until the
  orchestrator obtains independent exact-head review and hosted CI.
