# Application CI

Application CI runs on pull requests and pushes to main. It audits the locked
Hex dependencies and compiles the test build before running ExUnit. Configure
the branch protection check as **Application CI gate** once the workflow has
run on GitHub.

The planner assigns each `test/**/*_test.exs` file to one of up to eight shards.
It assigns the heaviest files first, each to the shard with the lowest total
weight. Unchanged files can use timings from the latest successful push run
on main when the toolchain, dependencies, workflow and runner image match.
Changed or new files use the median known weight with a five-second floor.
Without tests, the workflow reports zero test shards and still audits and
compiles. Each test shard gets its own PostgreSQL/pgvector service and a
restricted `vgas_test` role. Application tests must read the DevCore
`TEST_DATABASE_*` variables in CI and locally.

The exact dependency cache includes the runner image, architecture, toolchain,
lockfile, manifest and compile-time configuration. The build job writes it on
main pushes, and PR jobs only restore it. A miss fetches the locked dependencies
and compiles them locally.

The workflow follows the whole-file scheduling pattern from
[NewYou PR 322](https://github.com/Carpe-Diem-Media/NewYou/pull/322).
The planner requires the knowledge feasibility test file. Each shard checks
both ExUnit's exit status and a fresh case-level report. The shard that owns
that file runs all five F04/F05 cases with `VGAS_F04_DISPOSABLE=1`. Every
assigned file must report a pass. An unexpected skip, exclusion, failure,
missing report or missing required case fails the job. The only approved
exclusion is the predecessor staff and audit case outside `vgas001-upgrade`.
The timing history remains a separate file.

The gate also requires `mix ash.codegen --check`, all three migration lanes and a
redacted Gitleaks 8.30.1 scan of the candidate commit range. Only the ExUnit
matrix may be skipped, and only when the planner emits `has_tests=false`.
The migration lanes use separate disposable PostgreSQL/pgvector services. The
fresh lane applies the candidate migrations to an empty database. The upgrade
lane checks the foundation file against `aa93104`, applies that file alone,
then applies the candidate. The `vgas001-upgrade` lane checks both immutable
predecessor migrations against `92ef0e3`, applies them, and inserts a synthetic
staff and audit record before upgrading. All lanes check for pending migrations
and verify Oban v14 on the application Repo. Tests use manual Oban and prove that
a separate connection cannot see an uncommitted job and that rollback removes
it. The predecessor lane also verifies the exact staff and audit facts it
inserted. Oban starts with no queues, plugins, peer or stager in this slice.
Each migration lane requires a passing Repo cosine query in its case report.
The optional Proof check is outside the Application CI gate.

Both CI database jobs use the upstream linux/amd64
`pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00`.
Bootstrap installs the extension. The job then connects as the restricted
`vgas_test` database owner and checks PostgreSQL `180007`, vector `0.8.7`,
role privileges and an actual cosine query before running migrations or tests.
Every database job sets `VGAS_VERIFY_PGVECTOR=true`. The runner-private shard
uses loopback port 55434 so F04 cannot run against shared DevCore TEST on 55433.
The migration matrix keeps its runner-private port 55433.

## Disposable local workflow

Run the VGAS-23 migration and vector checks against a throwaway container of
the same public image that CI pins. The commands below do the same bootstrap
as CI. The container, volume and credentials last for one run only. Never use
55432 (shared DevCore DEV) or 55433 (shared DevCore TEST) for this workflow.

```sh
image=pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00
port=55436 # use 55437 for the full suite; must be free
ss -ltn "( sport = :$port )"
name=vgas-disposable-$port
docker run -d --rm --name "$name" -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p "127.0.0.1:$port:5432" "$image"
until docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do sleep 1; done
TEST_DATABASE_PASSWORD=$(openssl rand -hex 24)
docker exec -i "$name" psql -X -q -v ON_ERROR_STOP=1 -U postgres <<SQL
CREATE ROLE vgas_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$TEST_DATABASE_PASSWORD';
CREATE DATABASE vgas_test OWNER vgas_test;
\connect vgas_test
CREATE EXTENSION vector;
SQL
export MIX_ENV=test VGAS_VERIFY_PGVECTOR=true TEST_DATABASE_HOST=127.0.0.1 \
  TEST_DATABASE_PORT=$port TEST_DATABASE_USERNAME=vgas_test \
  TEST_DATABASE_NAME=vgas_test TEST_DATABASE_PASSWORD
bash .github/scripts/verify_postgres.sh 180007
mise exec -- mix ecto.migrate --strict-version-order
VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 0
docker stop "$name" # --rm removes the container and its anonymous volume
ss -ltn "( sport = :$port )"
```

Keep the generated password in the shell environment only. Do not write it to
files or logs. The application runs as `vgas_test`. That role owns the
`vgas_test` database and has no superuser, database-creation or
role-creation privilege. To run a migration lane, start a fresh container for
each lane. Apply that lane's predecessor steps from the workflow before running
the candidate migrations. The F04 guard accepts only loopback on 55434, 55436
or 55437. Before creating fixtures it checks the database, the role, and the
PostgreSQL and vector versions.

The orchestrator's own runs used an approved local helper. It wraps these same
steps, adds cleanup reporting and strips provider keys. Its use is optional.
The exact commands, predecessor pins and recovery evidence are in the
[VGAS-23 verification record](../plans/VGAS-23_VERIFICATION.md).

Check clean rollback and reapply only before protected history exists.
Once query or publisher failure history exists, B2b refuses rollback.
Preserve the history and use a compatible forward fix or a separately
approved, rehearsed restore. A synthetic custom-format `pg_dump` and
`pg_restore --list` check confirm archive readability. Proving recovery
requires a restore into a separately provisioned disposable target.

Shared DevCore rollout is tracked in VGAS-10. Resume the standard
`devcore-project doctor`, `devcore-project run dev -- mix setup` and
`devcore-project run test -- mix test` workflow for authorized work after
VGAS-10 records the rollout and both read-only probes verify the patched
baseline, restricted role and vector access. The shared DEV and TEST
allocations are subject to their own approval for changes and recovery.
