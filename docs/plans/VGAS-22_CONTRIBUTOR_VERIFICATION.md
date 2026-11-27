# VGAS-22 contributor migration verification

This proof covers the contributor migration criterion in [VGAS-22](https://app.plane.so/symphony-development/projects/8e7e9131-668d-4d99-8bd7-b5847d5f8c8c/issues/554f2a8d-e434-43b3-a0fc-9f4ca4124e4a).
The application base is `ed1d10a0ed336cb309345875f666a40d1c793683`.
[G016, G030 and G034](../spec/VGAS_IMPLEMENTATION_SPEC_v1.0.0.md) govern approval,
staff actions and scoped verification. [T07](../spec/VGAS_RESOURCE_CONTRACTS_v1.0.0.md)
governs the separate publication transaction. The approval proof checks that
denials leave the revision, its audit rows and the Oban job count intact.
The [VGAS-003 rehearsal](VGAS-003_VERIFICATION.md#migration-rehearsal-for-review-1)
and [B1 verification](VGAS-003B1_VERIFICATION.md) record the prior manual proof.

## Run the proof

Use the [disposable local workflow](../development/application-ci.md#disposable-local-workflow)
and its pinned public image. For this proof set the loopback port to **55434**.
Start a new container and volume for each lane and remove them before starting
the next lane. Confirm the listener is free with `ss -H -ltn '( sport = :55434 )'`.
Use the restricted `vgas_test` owner and a generated password. The proof checks
the loopback endpoint, TEST profile, role privileges, database ownership,
PostgreSQL `180007`, vector `0.8.7`, a cosine query, and an empty public schema
before running any migration. Use the Mise pins and unset `OPENAI_API_KEY`.

Run one of these commands in each container's disposable environment.

```sh
bash test/verification/vgas_22_contributors.sh fresh
bash test/verification/vgas_22_contributors.sh clean
bash test/verification/vgas_22_contributors.sh upgrade
```

The script contains the exact SQL and Mix commands. The upgrade lane loads
[the synthetic predecessor fixture](../../test/fixtures/vgas_22_contributor_predecessor.sql)
at `20261126053035`, checks `20261126060400` before and after its guarded
rollback, then checks the constraints at B1 `20261126063108` and applies the
remaining migrations. It runs the
[approval proof](../../test/verification/vgas_22_backfilled_approval.exs) after
the full upgrade. That test depends on the seeded rows and runs only in this
lane. Ordinary ExUnit discovery does not select it.

On the fresh container after the fresh script succeeds, run the existing Ash
checks and snapshot check.

```sh
mise exec -- mix test \
  test/voelgoed_ai/knowledge/editorial_test.exs:880 \
  test/voelgoed_ai/knowledge/editorial_test.exs:1105 \
  test/voelgoed_ai/knowledge/editorial_test.exs:1126 \
  test/voelgoed_ai/knowledge/editorial_test.exs:1158 --seed 0 --trace
mise exec -- mix ash.codegen --check
```

## Observed results

All three final runs exited 0 with Erlang/OTP 29.1.2, Elixir 1.20.5-otp-29
and `ERL_FLAGS='+S 4'`. The image was
`pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00`.
Every identity check printed
`vgas_test|vgas_test|180007|0.8.7|vgas_test|t|f|f|f|f|f|1`.

- **Fresh.** All 17 migrations applied in strict order. No migrations were
  pending. The contributor column had the expected UUID array type, non-null
  constraint and empty default. The Repo suite reported 6 passed and the
  expected predecessor-only exclusion. The four selected Ash checks passed,
  including forged storage capability denial and creator, editor and
  submitter self-approval checks. The other 34 cases were outside the
  selectors. `mix ash.codegen --check` exited 0.
- **Clean rollback.** `mix ecto.rollback --step 1` exited 0 and removed the
  contributor version and column. Strict reapply restored both and the
  revision table remained empty.
- **Populated upgrade.** Revision ID ending in `0021` retained creator
  `0003` and gained the ordered contributor suffixes `0001, 0002, 0003`.
  The duplicate edit produced one entry. Revision `0022` retained creator
  `0003` as its sole contributor. Its unrelated audit actor `0004` did not
  join the array. Every predecessor revision field and all four complete
  audit rows matched immediately after backfill. Rollback exited 1 with
  `P0001` and the contributor history message. The migration version and
  insertion time, column metadata, complete revisions and audits survived.
  The full upgrade kept the exact contributor sets and audit rows. The
  seeded Ash proof reported 1 passed. Both backfilled reviewers needed
  explicit self-approval. The attested submitter succeeded and wrote the
  `self_approval_attested` audit reason.
- **B1 negative writes.** Each psql command exited 3. An absent creator
  present in the array failed `23503` on
  `article_revisions_created_by_id_fkey`. Removing the existing creator and
  adding a null element while keeping the creator each failed `23514` on
  `article_revisions_contributors`.

The final runs used containers `51fd40d96d59`, `646a6ae22529` and
`d0f5d77176c88`, in lane order. Removal of each container and its own volume
was verified with Docker inspections, and `ss` showed no listener after
each lane. The first run exposed a test expectation error. PostgreSQL
reported the empty default as `ARRAY[]::uuid[]`. It also exposed a race
between stopping the auto-removing container and inspecting it. A later
inspection confirmed the initial resources were gone. The final runs used
explicit removal of the run-owned containers and named volumes.

The following checks exited 0. The forced compile completed under TEST
warnings-as-errors. The first build also printed compiler warnings from
locked dependencies while building those dependencies.

```sh
HEX_OFFLINE=1 MIX_ENV=test ERL_FLAGS='+S 4' mise exec -- mix deps.get --check-locked
env -u HEX_OFFLINE -u OPENAI_API_KEY MIX_ENV=test ERL_FLAGS='+S 4' mise exec -- mix hex.audit
env -u OPENAI_API_KEY MIX_ENV=test ERL_FLAGS='+S 4' mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=test ERL_FLAGS='+S 4' mise exec -- mix format --check-formatted
bash -n test/verification/vgas_22_contributors.sh
shellcheck test/verification/vgas_22_contributors.sh
python3 .github/scripts/plan_tests.py
git diff --check ed1d10a0ed336cb309345875f666a40d1c793683 HEAD
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --no-banner \
  --log-opts='ed1d10a0ed336cb309345875f666a40d1c793683..HEAD' .
```

The planner included 32 ordinary test files across eight shards. The proof
also rejected port 55433 with exit 1 before connecting. The first Gitleaks
attempt used the CI container, whose mount could not reach this linked
worktree's Git metadata. The scan used the same pinned version through Mise
on the host.

## Integrity boundary

The contributor proof pins `PGHOSTADDR` to the checked `TEST_DATABASE_HOST`
and clears `PGSERVICE` before either libpq invocation. PostgreSQL documents
that `hostaddr` can supply the connection address even if `host` is set.
[PostgreSQL 18 libpq connection parameters](https://www.postgresql.org/docs/18/libpq-connect.html#LIBPQ-CONNECT-HOSTADDR)

Independent review of `19be5af` reproduced inherited address and service
overrides with the disposable listener stopped and no SQL execution. After
the correction, all three lanes exited 0 on fresh containers from the pinned
public image with a conflicting loopback address in the environment or a
synthetic service file. To repeat, define a temporary libpq service named
`vgas22-regression` with `hostaddr=127.0.0.2` and export its path as
`PGSERVICEFILE`. With a fresh disposable container for each command, run:

```sh
PGHOSTADDR=127.0.0.2 bash test/verification/vgas_22_contributors.sh fresh
PGSERVICE=vgas22-regression bash test/verification/vgas_22_contributors.sh clean
PGHOSTADDR=127.0.0.2 PGSERVICE=vgas22-regression bash test/verification/vgas_22_contributors.sh upgrade
```

The corrected runner removed all three run-owned containers and volumes.
Port 55434 was free after cleanup. Bash syntax and ShellCheck passed.

PostgreSQL requires an existing staff row for `created_by_id`, a non-null
UUID array containing that creator, and no null elements. SQL permits a
privileged writer to add a UUID with no staff row or remove a noncreator.
Per-element referential integrity and contributor history therefore depend
on the supported editorial boundary. That path derives the staff ID from
the authenticated actor, applies role and collection checks, and records
the contributor change and audit event in the same transaction under the
revision lock. Approval compares the exact reviewed snapshot and requires
explicit attestation from an approving contributor. The storage policy
rejects unminted capabilities. No wider SQL constraint was required for the
supported path demonstrated here.

C2 action hints and publication regressions, mixed workload measurements, and
the audit history cost and indexing-status follow-ups remain under VGAS-22.
Independent review and exact-candidate CI evidence are pending.
