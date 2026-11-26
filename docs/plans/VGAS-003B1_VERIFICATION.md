# VGAS-003 B1 verification

Plane VGAS-14. Base `cee3cdd423b6485a3536f0b93ef3f7b39cdbb038`.
Implementation candidate `7d6ff8705e1ceb32b8a826378cfcd0fff8513a4e`.
Lockfile SHA-256 `97e956eb45a003ebae63bdbe513d6ecabd187e9fd5a40f68114c732896c71867`.
The authority is the [accepted VGAS-003 plan](VGAS-003_PLAN.md) and the B1/B2
split in the assignment. [PR A evidence](VGAS-003_VERIFICATION.md) covers the
predecessor editorial lifecycle.

## B1 scope and defaults

A scoped reviewer requests publication separately from approval. The request
compares the article pointer, pins the approved hash, profile, collection epoch
and UTC deadline, and commits locale rows and ID-only jobs together. The inference attempt is
created during T03 with the claim and reservation. Local
indexing takes one provider attempt per locale and generation with a 60-second
fixture deadline and at most five seconds for transport. A reviewer can retry a
failed publication with a new generation. Revocation, archival, collection
epoch changes and scope or deadline checks fence pending work. A failed locale
fences siblings. Late evidence can settle money after invalidation.

B1 stops with every approved locale READY and the revision still PUBLISHING.
B2 owns T07 and finalisation, pointer activation, query embedding, same-profile
reindex and rollback, hybrid retrieval, and evidence validation. The staff UI
belongs to PR C. The existing fixed-reply support workflow remains the runtime
path.

The code uses profile version 1 with `openai:text-embedding-3-small`, 1536
dimensions and cosine distance. ReqLLM's direct embedding path exposes the
controlled Req adapter needed to observe request IDs and raw integer usage.
The adapter accepts a bounded, single-locale approved projection. It limits
HTTP to the remaining deadline, disables redirects and uses
`req_http_options: [max_retries: 0, ...]`. The candidate HTTP/1 adapter has no
B1 activation path. TEST alone installs the deterministic fixture map. Its
price is 5 nano-USD per 2 input tokens with a 32,768-token ceiling, and its
global day and month caps are 10,000,000 and 20,000,000 nano-USD. These figures
establish test behavior. The live provider rate, entitlement, input bound and
operating limits still require owner approval. All Mix commands removed
`OPENAI_API_KEY`. Provider responses in this run came from synthetic fixtures.

## Accounting and recovery

The control row serializes changes to global spend. Editorial operations lock
staff before control. Workers lock control, collection, article, revision and
all generation rows by ID, then the attempt and reservation. Ledger changes
precede spend window locks. Windows are locked in day/month order. B1 takes
no support admission counter. The B2 query path must prove the combined
ordering.

A committed reservation is required before dispatch. A second transaction
consumes the one-shot dispatch fence. Only its winner invokes the adapter
outside the transaction. The pre-call check can reject and release a proven
unconsumed fence. A consumed fence counts as uncertain until trusted usage
arrives. The recovery job handles the expired attempt and the bounded sweep
can recover expired RUNNING attempts. An expired hold with a consumed fence
stays in exposure across UTC day and month boundaries. Avoid replay on timeout,
failed settlement, or restore. The next reviewer request must use a fresh
generation and fit the cap with older holds still included.

If trusted usage exceeds the reservation, the ledger keeps the actual
nano-USD and records the discrepancy. A persistent control flag inhibits
new embedding calls. An unrepresentable amount leaves risk held and inhibits
admission. The fixture authorises explicit conservative closure by one current
ADMIN and links the approving staff ID to the ledger. A late correlated result
can add one correction against the original settlement and origin windows.
Live closure policy, evidence collection, and operational reset of the inhibit
need owner approval. A restore rehearsal should verify outstanding holds and
reapply revocations before any later activation.

## Acceptance and evidence

The focused files are
[embedding_accounting_test.exs](../../test/voelgoed_ai/governance/embedding_accounting_test.exs)
and [editorial_test.exs](../../test/voelgoed_ai/knowledge/editorial_test.exs).

- Separate reviewer request, locale rows and durable jobs. `publication is separate from approval and only a reviewer can queue the locales` checks wrong role, stale pointer and internal ID-only jobs.
- T03, lock order, and no wire on failure. `dispatch follows committed reservation and only one worker per locale reaches the wire`, `the control lock precedes variant and reservation writes at the spend cap`, and `missing gate, price, cap or reservation storage denies before the adapter` inspect committed state from separate connections. The storage injection fails at commit.
- T08, pricing and trusted evidence. `price uses integer ceiling and rejects overflow and malformed usage`, `settlement uses frozen trusted usage and inhibits admission on excess`, and `malformed usage or cost overflow holds risk and invalid vectors charge known usage` cover integer precision, frozen price, linked settlement uniqueness, immutable original charges and failure behavior.
- Ambiguity, UTC rollover and recovery. `503 and timeout each hit the actual adapter once and keep the cost held`, `outstanding spend crosses UTC rollover and a late result settles to the origin window`, `committed dispatch risk survives recovery and an authorized closure gets one late correction`, and `a lost process releases only a pre-dispatch reservation and holds after the fence` cover hold, release, lost settlement and correction.
- Profile, vectors and lifecycle. `a vector has exact dimension and a finite nonzero float32 representation`, `disable fences a pre-dispatch claim and revoke cancels the generation`, and `archiving during the wire call preserves settlement and prevents a ready write` cover projection minimality, stale work and final state. The positive dispatch test runs an Oban worker and observes both READY rows with the article pointer still unset.
- Private audit authorization. The existing direct staff authorization matrix now exercises `append_publication_failure` with untrusted actors in a real transaction.

The first pure tests exited 2 on the predecessor with both interfaces absent.
The initial editorial red attempt also exited 2, during fixture setup because
the disposable database and role had different names. It did not establish a
pre-implementation editorial failure. The remaining worker and accounting
integration proofs are baseline and mutant evidence.

## Mutation results

Each mutation ran against the committed implementation on the disposable TEST
database with `mix test --seed 0 <focused test>`. The changed file or disposable
index was restored after each run. The baseline exited 0. Every mutation below
exited 2 at the scoped test.

| Mutation | Location in implementation commit | Observed failure |
| --- | --- | --- |
| Invoke in T03 before reservation commit | `embedding.ex:212–227` and transport permission | A deferred reserve-commit failure still reached the fake adapter. |
| Invoke inside a transaction after dispatch | `embedding.ex:123` | The transport permit refused the request and the wire assertion failed. |
| Remove one-shot dispatch guard | `embedding.ex:338` | The combined claim test no longer had exactly one fence winner. |
| Remove spend serialization lock | `embedding.ex:584` | The contested connection no longer waited for the control lock. |
| Discard holds outside the current day | `embedding_accounting.ex:62,306,309` | The next locale reached the wire after UTC rollover. The first isolated attempt also exposed test startup latency, so this result uses both the dispatch and rollover tests in one run. |
| Release ambiguous cost | `embedding.ex:412` | The failed request no longer retained its UNKNOWN hold. |
| Round non-integer provider usage | `embedding_transport.ex:70–71` | Malformed usage produced a charged result instead of a hold. |
| Use binary floating-point pricing | `embedding_accounting.ex:18` | The expected ceiling above 2^53 changed. |
| Drop unique ledger settlement | `usage_ledger_entries_entry_key_index` | PostgreSQL accepted a second settlement row for the same attempt. |
| Use `retry: false` alone | `embedding_transport.ex:31` | The single-wire-hit test failed. |
| Remove collection epoch check | `embedding.ex:296` | A claim reached the wire after the collection was disabled and re-enabled. |
| Remove expected pointer comparison | `editorial.ex:224` | The reviewer request with a stale pointer passed. |
| Allow result storage after archive | `embedding.ex:494–495` | The archived variant became READY. |
| Leave siblings eligible after failure | `embedding.ex:544` | The sibling stayed queued after an ambiguous failure. |

## Migration rehearsal

[20261126063108_vgas_003_embedding_accounting.exs](../../priv/repo/migrations/20261126063108_vgas_003_embedding_accounting.exs)
was generated by `mix ash.codegen vgas_003_embedding_accounting`. The
reviewed migration adds the native `vector(1536)` column, composite attempt,
pointer and ledger FKs, spend and recovery indexes, the contributor CHECK,
and a rollback guard. It requires a pre-provisioned extension and does not
manage it. The snapshots match the result of `mix ash.codegen --check`.

The disposable container used `devcore-postgres:18.7-vector0.8.7` on
`127.0.0.1:55434` and reported PostgreSQL 18.7 and pgvector 0.8.7. The
application tests used a non-superuser `vgas_test` role and database.

1. Fresh `mix ecto.migrate --strict-version-order` exited 0 on that role after the database owner installed pgvector.
2. Exact `cee3cdd` migrations from `git archive` and both checked-in predecessor fixtures were applied to a separate disposable database. The rehearsal also inserted a predecessor editorial draft with its contributor. Upgrade exited 0. Assistant pointer and hash, support run references, audit ancestry and editorial contributor data matched.
3. `mix ecto.rollback --step 1` and `mix ecto.migrate --strict-version-order` both exited 0 before B1 use. The same seeded values matched after each operation.
4. With synthetic spend present, `mix ecto.rollback --step 1` exited 1 with the expected guard. The spend row survived.

## Commands and results

- `devcore-project plan`, `devcore-project activate`, and final `devcore-project doctor` exited 0. The first doctor identified the missing rendered file.
- In disposable TEST, `mix compile --warnings-as-errors`, `mix ash.codegen --check`, `mix ecto.migrate --strict-version-order`, and `mix ecto.migrations` exited 0.
- Disposable `mix test --seed 0` and `mix test --seed 103` each exited 0 with 394 passed, 5 skipped and 1 excluded. Each seed passed all 31 tests in the two focused files. `VGAS_VERIFY_PGVECTOR=true` included the vector probe. The unseeded VGAS-001 ExUnit probe was excluded. Inherited external feasibility tests remained skipped. Local fixture HTTP tests used loopback.
- Shared DevCore TEST `mix ecto.migrate --strict-version-order` and `mix test --seed 0` and `--seed 103` each exited 1 at the pgvector prerequisite. No ExUnit tests ran there against B1. The shared migration did not apply, and the shared PostgreSQL services and extensions were left in place.
- Development Phoenix liveness returned HTTP 200 and `{"status":"ok"}` on `127.0.0.1:4196/health`, with live calls disabled. A separate optional DEV warnings-as-errors run reported inherited warnings in other modules. TEST warnings-as-errors is the slice gate.
- `mix format --check-formatted`, `mix deps.get --check-locked`, `mix hex.audit`, `python3 .github/scripts/plan_tests.py`, `git diff --check cee3cdd HEAD`, and `git diff --exit-code cee3cdd HEAD -- mix.exs mix.lock` exited 0. `rg 'authorize\?: false' lib` exited 1 with no matches. `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='cee3cdd..HEAD'` exited 0 with no findings.
- Exact-head hosted CI and independent review belong to PR handoff. No PR was opened by this task.

## Owner decisions

VGAS-7 still owns live provider entitlement, usable transport evidence,
verified limits and versioned prices. The owner still needs to set real day
and month caps, indexing deadline and retry policy, the financial reconciliation
and inhibit-reset procedure, and the staff-to-collection mapping. No live
key, routing, publication activation or owner approval is implied by the
fixture checks.
