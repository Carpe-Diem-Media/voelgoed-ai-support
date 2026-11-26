# VGAS-003 PR A verification

Base `4e5feb40524db4458bc542dc33cc4c40c434bb0e`. Tested source and test candidate
`546b2370f28d4d7f55b973c4b16a0f24aaf7a419`. Plane VGAS-14 remains In Progress
for the three-PR slice. The accepted plan is [VGAS-003_PLAN.md](VGAS-003_PLAN.md).
The application lockfile SHA-256 is
`97e956eb45a003ebae63bdbe513d6ecabd187e9fd5a40f68114c732896c71867`.

## AC1 coverage for PR A

Tests below are in [editorial_test.exs](../../test/voelgoed_ai/knowledge/editorial_test.exs)
unless a different file is named. The first nine scenarios ran before
implementation with seed 0 and exited 2 with 0 of 9 passing. The publication
lock-order regression ran again before the lock fix and reproduced PostgreSQL
`55P03` while trying to take the collection lock.

| Case | Test and observed evidence |
| --- | --- |
| Collection authority and epochs | `collection lifecycle requires live ADMIN authority and advances epochs`. Create starts disabled. Enable, disable and retire advance the epoch. Terminal retirement and stale sessions deny. |
| Role and scope checks | `editorial actions deny unrelated, unscoped, stale and direct storage actors`. The test attempts the public actions with live wrong roles, ADMIN without editorial roles, anonymous callers, stale sessions, forged support scopes and missing collection grants. A forged storage capability fails inside a real transaction. |
| Withdrawal and audit history | `scoped editors and reviewers can withdraw without granting ADMIN content access`. Editors and reviewers withdraw in their allowed states. Audit reads check collection membership. `VoelgoedAi.Governance.AuditEvent.append_knowledge denies direct calls with untrusted actors` and the corresponding `knowledge_rows` test cover private audit storage in [direct_staff_authorization_test.exs](../../test/voelgoed_ai/accounts/direct_staff_authorization_test.exs). |
| Review snapshot, approval and rollback | `review guards the exact snapshot and rollback keeps the prior state`. A reviewed revision rejects edits and a different hash. Request changes returns the row to draft. Forced audit failure rolls approval back. Approval creates zero jobs. |
| Real PostgreSQL race and edit side effects | `concurrent edits and approvals serialize on real connections`. The test observes the competing connection waiting through `pg_blocking_pids`. Only one editor and one reviewer win on the same snapshot. The edit leaves the job count unchanged. |
| Canonical hash | `canonical hash sorts locale keys and scope and preserves answer text`. Locale and applicability ordering and equivalent offsets yield equal hashes. Scope changes and a change to answer bytes yield different hashes. |
| Self-approval and sensitive content | `self-approval requires the reviewer role and explicit attestation` checks generation revocation, reviewer attestation and the audit reason. `sensitive approvals stay pending and archive fences editing` verifies denial pending an owner-approved sensitive review policy. |
| Grant ceiling and freezing | `grants reject internal scope and freeze at publication`. The public assistant rejects an internal grant. Publication rechecks collection status, includes the grant IDs in the v2 hash, and denies post-publication removal. Replacing the revision with an empty grant set changes the hash. |
| Lock order on replacement | `assistant publication locks its previous revision before collections`. The replacement waits for the previous revision on another connection while the collection remains free to lock. |
| Current pointer integrity | `the current pointer cannot reference a revision of another article`. PostgreSQL rejects the foreign article pointer via `articles_current_revision_fkey`. |
| Draft-only portability | `portable import rejects tampering, PII and collisions and round trips a draft`. Valid preview, apply, reapply, export and reimport succeed. Wrong roles, states embedded in documents, PII with a matching hash, cross-collection identity collisions and conflicting slugs deny. A revised snapshot requires explicit selection and keeps the original approval untouched. |
| Predecessor audit and hash | The [predecessor fixture](../../test/fixtures/vgas_003_predecessor.sql) adds a published fixed-reply assistant revision, qualified support run, staff configuration audit and worker audit to the VGAS-001 fixture. The migration rehearsal compares all seeded rows and the active pointer. |

## Mutations

Each mutant ran alone with `mix test test/voelgoed_ai/knowledge/editorial_test.exs --seed 0`.
The implementation and tests were committed before any mutation. The first hash
mutant survived because the test also passed a stale edit version. The revised
test passes the correct edit version and changes only the hash. The table
records the rerun against the candidate above. Each edit was restored before the
next run. Baseline and final restored exit codes were 0.

| Mutant | File and line at candidate | Assertion that failed | Exit |
| --- | --- | --- | --- |
| Remove the draft-state guard on edit | `knowledge/editorial.ex:215` | Reviewed content rejects edits | 2 |
| Remove comparison with the supplied review hash | `knowledge/editorial.ex:209` | Approval denies a different hash with the current edit version | 2 |
| Remove the editor requirement for edit | `knowledge/editorial.ex:55` | A scoped reviewer without the editor role cannot edit | 2 |
| Allow an unminted storage capability | `knowledge/storage.ex:17` | Forged storage reads fail inside a transaction | 2 |
| Enqueue on edit | `knowledge/editorial.ex:517` | Job count stays fixed after the winning edit | 2 |
| Enqueue on approval | `knowledge/editorial.ex:517` | Job count stays fixed after approval | 2 |
| Make approval attempt a published state | `knowledge/editorial.ex:252` | Valid approval must succeed and return APPROVED | 2 |
| Accept a surplus import entry key | `knowledge/portable.ex:60` | An imported `status` key must reject the document | 2 |

## Commands and results

Commands that used the shared database ran serially through
`devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix`.
The loopback liveness check used the development profile. The separate
PostgreSQL 18.7 rehearsal used generated credentials. No provider keys or raw
Mix logs are retained.

| Command or check | Exit | Evidence |
| --- | --- | --- |
| `devcore-project plan`, `activate`, `doctor` | 0 each | Confirmed the local TEST allocation on 55433, PostgreSQL 18.6. |
| `mise exec -- mix deps.get --check-locked` | 0 | No dependency changes. |
| `mix ash.codegen vgas_003_editorial` | 0 | Generated one migration and six resource snapshots. |
| `mix format --check-formatted` | 0 | All formatted. |
| `mix compile --warnings-as-errors` | 0 | TEST compile. |
| `mix ash.codegen --check` | 0 | Resource snapshots match. |
| `mix ecto.migrate --strict-version-order`, `mix ecto.migrations` | 0 each | Shared TEST schema current. |
| `mix test test/voelgoed_ai/knowledge/editorial_test.exs --seed 0`, `--seed 103` | 0 each | 12 passed on each seed, including the restored seed 0 baseline. |
| `mix test --seed 0`, `mix test --seed 103` | 0 each | 372 passed, 5 skipped and 2 excluded on each seed. |
| `mix hex.audit` | 0 | Locked dependencies passed the Hex audit. |
| `python3 .github/scripts/plan_tests.py` | 0 | Shard planner included the new ExUnit file. |
| `git diff --check 4e5feb4 HEAD` | 0 | No whitespace findings. |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='4e5feb4..HEAD'` | 0 | No findings. |
| `rg 'authorize\?: false' lib` | 1 | No matches. |
| `git diff --exit-code 4e5feb4 HEAD -- mix.exs mix.lock` | 0 | Both dependency files match the base. |
| `VGAS_VERIFY_PGVECTOR=true mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0` | 2 | Shared TEST has no `vector` extension. The opt-in vector probe ran on the separate vector-enabled rehearsal target instead. |
| `PORT=4192 devcore-project run dev -- env -u OPENAI_API_KEY mise exec -- mix phx.server`; `curl --fail http://127.0.0.1:4192/health` | 0 | HTTP 200. The server stopped and port 4192 was free. |

The first full suite run reported two audit action inventory failures. The
regression tests now include the new actions and exercise direct denial for the
two storage actions. The table records the final runs. The five skips are the
F04 disposable feasibility tests. The shared suite excludes the opt-in vector
and historical upgrade probes. The disposable rehearsal covers both contracts.

## Migration rehearsal

The generated [migration](../../priv/repo/migrations/20261126053035_vgas_003_editorial.exs)
adds three Knowledge tables, assistant revision grants, the assistant hash
version and new audit foreign keys and CHECK branches. The current article pointer
references the unique `(article_id, id)` key in `article_revisions`. The migration
leaves predecessor files intact. The predecessor has no way to interpret v2
assistant hashes or retain editorial history, so rollback refuses once editorial
data or v2 hashes exist. Rehearse rollback on a pre-use database. After use,
restoration requires an approved backup and a recovery decision.

The disposable `devcore-postgres:18.7-vector0.8.7` target at `127.0.0.1:55434`
reported PostgreSQL 18.7 and vector 0.8.7. No shared extension was modified.

1. Fresh database with vector pre-provisioned. `mix ecto.migrate --strict-version-order` and `mix ecto.migrations` exited 0.
2. Upgraded a database migrated with files extracted from exact base `4e5feb4`. Loading both predecessor fixtures and `mix ecto.migrate --strict-version-order` exited 0. The assistant pointer, version 1 hash, support run and all three audit rows matched the predecessor.
3. `mix ecto.rollback --step 1` exited 0 on the seeded predecessor without PR A data. Reapply exited 0. The same rows and relationships matched at each step.
4. The focused cosine-distance probe exited 0 with vector 0.8.7. A rollback attempt after inserting a synthetic collection exited 1 with the expected guard message. The collection remained present. The disposable container was removed and port 55434 was free. Anonymous storage removal was not verified.

## Decisions and remaining work

- Editorial membership comes from a server-owned map of fixture collection IDs to editor and reviewer IDs in TEST. Production membership defaults to denial pending an owner decision.
- Content version 1 uses exact answer bytes, sorted object keys, locale ordering, sorted applicability sets and UTC timestamps. The FAQ category and link allowlist are fixture choices. The import parser rejects unknown and duplicate keys, common contact and numeric PII patterns, conflicting identities and unknown links. Source review still has to check for personal data that a pattern cannot detect.
- Export supports a selection of up to ten active articles for a scoped reviewer. It includes the latest local snapshot, including drafts, as portable content. It carries source revision metadata. Imports require at least one article and always create drafts or return an existing matching draft.
- Confirm production collection assignments, approved source owners and FAQ coverage, permitted category and applicability identifiers, public link rules, and the independent sensitive-content review policy. Real staging material stays behind VGAS-11 and the staff Entra gate.
- PR B adds accounted indexing, publication, evidence retrieval and revalidation. Provider entitlement, verified bounds, budgets, retry policy and ranking thresholds still require owner evidence. PR C adds staff routes, LiveView socket and forms, and Hallmark and accessibility verification. No frontend or Compose files changed in PR A.
- PR B or C should revisit the global `AutomationControl` row lock on
  read-only editorial actions. It serializes those reads with support ingress.
  The current order is staff, then control, then targets.
- Editors declare sensitivity pending the owner decision on the sensitive
  review policy. The PII numeric pattern `(?:\+?\d[ .()\-]?){10,}` can reject
  date and time text. Both are follow-ups.
- Removed the unused private `KnowledgeCollection.collection_by_slug` action
  after confirming it had no callers.
- The orchestrator owns independent review, PR creation and exact-head CI. VGAS-004 owns wiring evidence into support decisions. The fixed-reply support path remains in use.

## Review 1 fixes

Review 1 assessed `0f1eaa0b60b343ac94cc74593d08e8bca6996d8a`. The new
tested application and test head is `f0b06c90022542fab4d590cfed88a49278193541`.
The commit containing this section changes only the verification record.

1. A revision now records the staff IDs that created, edited or submitted it.
   Import uses the same creation path and records the importing staff member.
   Edit and submit update the set under the revision lock in the same transaction
   as the audit. The tests reject an editor or submitter who attempts to approve
   without attesting. They also verify the `self_approval_attested` reason for
   an editor and importer, and the `source_verified` reason for an uninvolved
   reviewer. The original creator self-approval test still passes.
2. The configuration test stores a published v1 revision with a hash computed
   using the predecessor field order and encoding. It verifies
   `Configuration.current_revision/1` and `render_fixed_reply/3`.
3. A published v2 revision with one grant verifies successfully. A second grant
   inserted directly through SQL makes the same revision fail with `stale_policy`.
4. Tests confirm that a disabled collection returns `inactive_scope` when
   creating an article or adding a draft revision, and when editing,
   submitting or approving a revision.
5. The import test changes only the hash of a valid document and expects
   `invalid_portable_document`.
6. Knowledge history returns the newest 100 events, ordered by occurrence
   time and then ID, both descending. The test inserts 101 newer events and
   checks the exact IDs and order. There is no new index for the three
   knowledge target columns. PR A has a bounded staff preview workload and
   no measured evidence of query latency that warrants an index.

The corrected pre-fix regression run exited 2 on seed 0. It reproduced the two
attestation bypasses and the audit history ordering failure. The tests for
existing hash, import and inactive-scope behavior passed on the original code.
The combined editorial and configuration test files passed after the fix
and again after restoring the mutants.

### Mutation results

The reviewer mutations B4, B5, B6, B11 and B12 ran individually after the fix and
tests were committed. Each run used `mix test <test-file> --seed 0`. The
configuration file was the target for the v1 case. All other runs targeted the
editorial file. Source was restored after every run.

| Change to the committed code | Failing assertion | Exit |
| --- | --- | --- |
| Use the v2 encoding for the v1 hash | The legacy revision must verify against its published hash | 2 |
| Omit grants when verifying a v2 hash | The intact revision with a grant must verify | 2 |
| Remove the collection-active check from revision transitions | Editing a draft in a disabled collection must fail | 2 |
| Remove the collection-active check from article creation | Creating a draft article in a disabled collection must fail | 2 |
| Accept any string as an import hash | A valid document with a wrong hash must be rejected | 2 |
| Use creator-only self-approval detection | An editor or submitter cannot approve without attesting | 2 |
| Restore oldest-first history | The returned IDs must match the newest 100 in order | 2 |

### Commands and results for review 1

Mix commands ran serially against DevCore TEST through
`devcore-project run test -- env -u OPENAI_API_KEY MIX_ENV=test mise exec -- mix`.
The migration rehearsal used its own loopback PostgreSQL. Mix logs were
filtered and deleted. Elixir 1.20.5 and Erlang/OTP 29 were used.

| Command | Exit | Observed result |
| --- | --- | --- |
| `devcore-project plan`, `devcore-project activate`, `devcore-project doctor` | 0 each | Rendered the checkout's ignored environment and verified both allocations. Used TEST on port 55433 for application database checks. |
| `mix ash.codegen vgas_003_editorial_contributors` | 0 | Generated the additive migration and article revision snapshot. |
| `mix format --check-formatted`, `mix compile --warnings-as-errors` | 0 each | Formatting and TEST compilation passed. |
| `mix ash.codegen --check`, `mix ecto.migrate --strict-version-order` | 0 each | Snapshots match and the shared TEST schema is current. |
| `mix test test/voelgoed_ai/knowledge/editorial_test.exs --seed 0`, `--seed 103` | 0 each | 17 passed on each seed. |
| `mix test --seed 0`, `mix test --seed 103` | 0 each | 378 passed, 5 skipped and 2 excluded on each seed. The two optional database probes ran on the disposable target. |
| `mix test test/voelgoed_ai/knowledge/editorial_test.exs test/voelgoed_ai/support/configuration_test.exs --seed 0` | 0 | 28 passed after restoring all mutants. |
| `mix deps.get --check-locked`, `mix hex.audit` | 0 each | Separate invocations. Dependencies match the lockfile and the audit passed. |
| `python3 .github/scripts/plan_tests.py` | 0 | The test shard plan generated successfully. |
| `git diff --check 4e5feb4 HEAD`, `git diff --exit-code 4e5feb4 HEAD -- mix.exs mix.lock` | 0 each | No whitespace errors or dependency file changes. |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='4e5feb4..HEAD'` | 0 | No leaks found. |
| `rg 'authorize\?: false' lib` | 1 | No matches. |

### Migration rehearsal for review 1

[The contributor migration](../../priv/repo/migrations/20261126060400_vgas_003_editorial_contributors.exs)
is additive so checkouts with the original PR A migration already applied can
upgrade normally. It adds a non-null UUID array with an empty default and
backfills creator, editor and submitter IDs from the revision and its audit
events. The original PR A rollback guard remains in place. The new migration
also refuses to drop contributor history after a revision exists.

The disposable `devcore-postgres:18.7-vector0.8.7` container bound only to
`127.0.0.1:55434` and reported PostgreSQL 18.7 and vector 0.8.7.

1. Fresh `mix ecto.migrate --strict-version-order` and `mix ecto.migrations`
   exited 0. `VGAS_VERIFY_PGVECTOR=true mix test test/voelgoed_ai/repo_foundation_test.exs --only requires_pgvector --seed 0`
   exited 0 on the fresh database.
2. Upgrade from migrations extracted from `4e5feb4`, with both predecessor
   fixtures loaded, exited 0. The staff, assistant, active pointer, v1 hash,
   binding, session, support run and three audit records matched before and
   after the upgrade. The hash version was 1.
   `VGAS_VERIFY_PGVECTOR=true VGAS_VERIFY_VGAS001_UPGRADE=true mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0`
   exited 0 on the upgraded database.
3. `mix ecto.rollback --step 2` and `mix ecto.migrate --strict-version-order`
   both exited 0 before editorial use. Both predecessor fixtures matched at
   each step.
4. A separate pre-use `mix ecto.rollback --step 1` exited 0. After inserting
   a revision and prior edit and submit audit events in that schema, the
   additive migration exited 0 and recovered the three distinct staff IDs.
   A subsequent `mix ecto.rollback --step 1` exited 1 with the contributor
   history guard. The contributor IDs survived and the container was removed.
   Port 55434 was free after cleanup.
