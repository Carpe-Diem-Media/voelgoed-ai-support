# VGAS-23 verification

Base `c10a7d6b3de2c7fb5c7c74159b779ad8ba6e5956`. Local checks ran with
Erlang/OTP 29.1.2 and Elixir 1.20.5. The [accepted plan](VGAS-23_PLAN.md)
contains the shared read-only SQL and predecessor migration commands.
The orchestrator's subsequent ruling moved only the CI shard service
to port 55434 so F04 remains disallowed on shared TEST port 55433.
The CI migration services retain their runner-private port 55433.

## Shared DevCore rollout pending under VGAS-10

The worktree lacked a rendered `.env.local`. The canonical checkout had one
and its committed project and render-map files matched this worktree.
The read-only probes used that checkout's `devcore-project run test` with
tracing off and stderr discarded. The SQL used
`default_transaction_read_only=on` and `BEGIN READ ONLY … ROLLBACK`.
`devcore-project doctor` also used the read-only session default.

- DEV, `127.0.0.1:55432`. Probe exit 0. Database, owner and login
  `vgas_dev`. PostgreSQL `180006`. Schema `public`, search path
  `"$user", public`. The role can log in and has none of the superuser,
  database creation, role creation, replication or RLS bypass flags.
  The available and installed vector queries returned no rows. The type
  was not visible and the conditional cosine query did not run.
- TEST, `127.0.0.1:55433`. Probe exit 0. Database, owner and login
  `vgas_test`. PostgreSQL `180006`. Schema `public`, search path
  `"$user", public`. The role can log in and has none of the superuser,
  database creation, role creation, replication or RLS bypass flags.
  The available and installed vector queries returned no rows. The type
  was not visible and the conditional cosine query did not run.
- `devcore-project doctor` exited 0 for both role and endpoint checks.
  The DevCore source merge `fcfbf750` does not establish a deployed baseline.
  Both shared endpoints remain pending. All migration, test, backup and
  rollback work below used disposable databases.

## Image verification

- The original helper targets `devcore-postgres:18.7-vector0.8.7`.
  `docker image inspect` returned linux/amd64 local image ID
  `sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929`.
- The amd64 manifest for upstream `pgvector/pgvector:0.8.7-pg18` is
  `sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00`.
  After the digest pull, a private copy of the owner-approved helper ran
  on port 55436. `diff -U0` showed this single change:

  ```diff
  -IMG=devcore-postgres:18.7-vector0.8.7
  +IMG=pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00
  ```

  `bash .github/scripts/verify_postgres.sh 180007` exited 0 and printed
  `vgas_test|vgas_test|180007|0.8.7|vgas_test|t|f|f|f|f|f|1`.
  The image reported Debian PostgreSQL package `18.7-1.pgdg12+2`.
  The command with `180006` exited 1. The command with `180007` then
  exited 0 again. The public digest is pinned in both CI database jobs.
- `docker run --rm ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f version`
  reported `v8.30.1`.

## Disposable commands

The focused runs used the original runner on 55436 and a fresh container per
lane. The full suite used the approved private runner copy on 55437 to exercise
the image pinned in CI. Check the port with `ss -ltn` before each invocation.
The commands ran with tracing off and provider credentials removed from the
runner environment. The runner supplied `MIX_ENV=test`,
`VGAS_VERIFY_PGVECTOR=true` and the disposable TEST allocation.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55436
bash "$vgas_private_public_runner" "$PWD" "$vgas_full_steps" 55437
```

For the fresh lane use `HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked`
and `mise exec -- mix setup`. For the upgrade lanes use the pinned predecessor
steps in the plan. Each lane runs
`bash .github/scripts/verify_postgres.sh 180007`,
`mise exec -- mix ecto.migrate --strict-version-order` and
`mise exec -- mix ecto.migrations`. Compare ordered `version, inserted_at`
from `schema_migrations` before and after reapply. Require zero pending
migrations and identical version rows and timestamps.

Use fresh private paths for `CI_TEST_RESULTS_OUTPUT` and, when collecting
timing history, `CI_TIMING_OUTPUT`. For focused migration verification
pass `test/voelgoed_ai/repo_foundation_test.exs` to both commands below and
set the mode to `fresh`, `upgrade` or `vgas001-upgrade`. Set
`VGAS_VERIFY_VGAS001_UPGRADE=true` only for the lane seeded with the
predecessor staff and audit fixture.

```sh
mise exec -- mix test --seed 0 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter "${paths[@]}"
python3 .github/scripts/verify_test_results.py "$CI_TEST_RESULTS_OUTPUT" "$mode" "${paths[@]}"
```

For focused F04/F05 use only `test/voelgoed_ai/knowledge_feasibility_test.exs`,
`VGAS_F04_DISPOSABLE=1` and mode `shard`. For the full suite use the same
flag and mode, omit the ExUnit path arguments, and pass every
`test/**/*_test.exs` path to the verifier.

## Migration and recovery evidence

- Fresh setup applied all 16 migrations. The fresh and foundation-upgrade
  Repo suites each reported 6 passes, including cosine distance, and
  the single approved predecessor exclusion. The seeded VGAS-001 lane
  reported all 7 passes and verified the staff and audit facts.
- All three lane checks found zero pending migrations after reapply and
  compared the same 16 migration versions and insertion timestamps.
- The fresh F04/F05 run reported 5 passes and the verifier confirmed all
  five. The shard shell block returned the same result after the negative
  experiments were removed.
- The recovery rehearsal used `mise exec -- mix ecto.rollback --step 1`
  and `mise exec -- mix ecto.migrate --strict-version-order`. The clean
  rollback removed version `20261126104038` and reapply restored it.
  The protected-history fixture used the synthetic VGAS-001 staff row,
  a disposable collection, article and revision, and a `publisher /
  fail_publication / deadline` audit row with states `publishing` and
  `publish_failed`. The rollback command exited 1 with the B2b guard
  error. A query before and after confirmed the same audit row and the
  continued presence of the migration version.
- With only synthetic data, `pg_dump --no-password --format=custom
  --no-owner --no-acl -h 127.0.0.1 -p 55436 -U vgas_test -d vgas_test
  --file="$dump"` and `pg_restore --list "$dump"` exited 0. The list
  contained `TABLE DATA public audit_events`. The archive and list were
  deleted. An archive listing does not establish successful restore or
  permission to back up or alter a shared endpoint.

## Negative proofs

- A temporary single F04 skip produced 4 passes, 1 skip and ExUnit exit
  0. The verifier rejected the skipped case with exit 1. A missing report
  and a four-case report each failed with exit 1.
- The shard's workflow shell block, with the local Mise prefix, exited 1
  before ExUnit when `VGAS_F04_DISPOSABLE` was unset. It passed with the
  flag and all five cases restored.
- The planner exited 1 when the required feasibility file was absent.
  The Application CI gate's shell block matched all 22 supplied status
  combinations. Each of the six required dependencies individually
  caused exit 1 on failure, skip or cancellation with tests present.
  Success with tests, and the intentional no-tests matrix skip, returned
  0. Missing planner output and a successful test matrix with
  `HAS_TESTS=false` both failed.
- The public image baseline check rejected expected server version
  `180006` with exit 1 and passed again with `180007`.

## Inherited split-clock test defect

The first full run on the public image reported 568 passes, 1 approved
exclusion and 2 failures. On November 27 the retrieval fixture's
`now + 35 days` falls in January 2027. The earlier editorial suite creates
a January global monthly spend window with zero settled usage. Both
split-clock retrieval tests incorrectly required that row to be absent.

The disposable reproduction used `mise exec -- mix test --seed 0
test/voelgoed_ai/knowledge/editorial_test.exs` followed by
`mise exec -- mix test --seed 0
test/voelgoed_ai/knowledge/retrieval_test.exs:1233` against the same
database. The retrieval file matched the base byte for byte. Editorial
reported 36 passes. Both retrieval cases failed with ExUnit exit 2 and
the January row on the left of the equality assertion.

The approved test-only change snapshots late day and month spend rows
and reservation identities, states and amounts before the query. The
existing two checkpoints require the same snapshot. The original
spend and ledger checks still apply to the originating period.

After the test fix, the same editorial-first sequence passed both retrieval
cases. A temporary test mutation added 18 nano-USD to the existing late-month
row just before the final snapshot assertion. Both tests failed at that
assertion with ExUnit exit 2. The mutation was removed before the full
suite and is absent from the diff.

## Full suite and handoff checks

The final run on 55437 used the pinned public digest. ExUnit reported
**570 passes, one approved exclusion, zero skips and zero failures**.
The shard verifier exited 0 and counted all five F04/F05 passes. The
independent timing JSON retained the existing schema and matched the
source digests for all 30 test files.

These checks exited 0:

- `mise exec -- mix format --check-formatted`.
- `mise exec -- mix compile --force --warnings-as-errors` with `MIX_ENV=test`.
- `mise exec -- mix ash.codegen --check`.
- `HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked`.
- `MIX_ENV=test mise exec -- mix hex.audit` in a separate invocation.
  Hex reported no retired or advisory packages.
- `git diff --check c10a7d6..HEAD`.
- `python3 .github/scripts/plan_tests.py`. The planner emitted eight
  shards containing all 30 files and `has_tests=true`.
- `mise exec actionlint@1.7.12 -- actionlint .github/workflows/application-ci.yml`
  and `bash -n .github/scripts/verify_postgres.sh`.

The initial Gitleaks command mounted the linked worktree and scanned zero
commits because its Git metadata lived outside the mount. For the usable
scan, a private standalone clone with the same head was mounted read-only
as `/repo`. The command below scanned the three implementation commits
through `998f4fd54eea43792c397d8825c175b1cea28dee` and found zero leaks.
Use the same procedure for the handoff head, including this evidence commit.

```sh
docker run --rm --user "$(id -u):$(id -g)" --volume "$vgas_scan_repo:/repo:ro" --workdir /repo \
  ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f \
  git --redact=100 --log-opts='c10a7d6..HEAD' --no-banner .
```

The runner reported container and volume cleanup exit 0. Docker reported
no disposable containers or volumes from these runs, and `ss -ltn`
showed no listeners on 55436 or 55437 at handoff.

Hosted exact-head CI and independent review are pending with the
orchestrator. The required Application CI gate aggregates plan, build,
shards, snapshots, migrations and secrets. The optional Proof check
is outside that dependency list. Verify the repository's required
check settings against the hosted run before merge consideration.

## Review 1 corrections

Review 1 of PR #20 on `b0a0b95` was **APPROVE**, with four LOW findings and three NITs. The orchestrator applied the corrections below on top of that head. They touch documentation, a comment and `.gitignore` only, with no change to workflow behaviour.

- **LOW-1, runbook portability.** `docs/development/application-ci.md` now documents the disposable workflow with the public, CI-pinned `pgvector/pgvector@sha256:4bdc1604…6e00` image, using `docker run --rm` and the same bootstrap SQL as CI. The local helper is described as optional. To check the documented block, it was extracted and run verbatim from the correction worktree on loopback 55436 under `env -u OPENAI_API_KEY bash -e`:
  - The run exited 0.
  - `verify_postgres.sh 180007` printed `vgas_test|vgas_test|180007|0.8.7|vgas_test|t|f|f|f|f|f|1`.
  - Migrations applied.
  - `VGAS_F04_DISPOSABLE=1 mix test --seed 0` reported 570 passed and 1 excluded in 76.1 s.
  - Afterwards no container remained and port 55436 was released.
  - The run log contained no generated password.
- **LOW-2, approval traceability.** The split-clock test approval is now recorded in the plan addendum and in Plane VGAS-23 comment `3f211d90`.
- **LOW-3, F08 port 55433 has no hostname check** (`test/support/feasibility/entra_store.ex:12`). This was pre-existing and is outside this PR's acceptance criteria. It is recorded as a non-blocking follow-up in Plane VGAS-24.
- **NIT-1.** `.gitignore` now ignores `__pycache__/`, which local runs of `plan_tests.py` create.
- **NIT-2.** Both pgvector digest pins carry a comment naming the `0.8.7-pg18` tag and the linux/amd64 platform.
- **NIT-3,** the `has_tests=false` branch can no longer be reached. This is harmless and needs no change.

Correction checks:

| Check | Exit |
| --- | --- |
| `mise exec -- mix format --check-formatted` | 0 |
| `python3 -B .github/scripts/plan_tests.py` | 0 |
| `git diff --check` | 0 |
