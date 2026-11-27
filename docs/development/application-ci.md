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

Run the VGAS-23 migration and vector checks with the owner-approved
`vgas_disposable_pg.sh` attachment. It starts a fresh loopback instance
of `devcore-postgres:18.7-vector0.8.7` and preinstalls vector using the
container bootstrap role. The application runs as `vgas_test`, which owns
the `vgas_test` database and has no superuser, database creation or role
creation privilege. The runner generates throwaway credentials and passes
them through the environment. Keep them out of steps files and logs.

```sh
ss -ltn '( sport = :55436 or sport = :55437 )'
docker image inspect devcore-postgres:18.7-vector0.8.7 --format '{{.Id}} {{.Os}}/{{.Architecture}}'
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55436
```

Use a private steps file with one command per line. Use a fresh 55436
run for each migration lane and 55437 for the full suite. Confirm the
runner reports `cleanup: container=0 volume=0` and check port release
with `ss -ltn` after each run. The runner removes its own container
and volume on exit. The F04 guard accepts only loopback on 55434, 55436
or 55437 and checks the database, role, PostgreSQL and vector versions
before creating fixtures. The local commands, predecessor pins and
recovery evidence are in the [VGAS-23 verification record](../plans/VGAS-23_VERIFICATION.md).

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
