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
Coverage relies on complete file assignment and ExUnit's exit status.

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

Use DevCore for local bootstrap and keep DEV and TEST separate. The workstation
TEST role cannot install server extensions. On a pgvector-enabled TEST target,
run the vector probe with `VGAS_VERIFY_PGVECTOR=true`. CI sets this flag in
every shard and all migration lanes, so missing pgvector fails the gate.

The VGAS-003 embedding accounting migration requires a pre-provisioned
`vector` extension. Use a disposable pgvector instance on `127.0.0.1:55434`
with TEST database and role `vgas_test` and `VGAS_VERIFY_PGVECTOR=true` when
the workstation allocation lacks the extension. The Entra feasibility
fixtures accept this explicit loopback target as well as the standard TEST
endpoint. Shared DevCore credentials remain in DevCore.
