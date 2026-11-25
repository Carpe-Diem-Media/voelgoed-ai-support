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
