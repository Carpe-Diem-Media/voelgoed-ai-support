# VGAS-23 implementation plan

> Implement one scoped PR after the orchestrator reviews the decisions below. Scope is the VGAS-005 pgvector gate. The application uses Phoenix, ExUnit, Ecto and AshPostgres on PostgreSQL 18.7 with pgvector 0.8.7.

Planning base is `c10a7d6b3de2c7fb5c7c74159b779ad8ba6e5956`. G032–G036 and A-010 govern the slice. The ticket supplies the patched database baseline and permits a disposable fallback. The planning pass inspected source and local image metadata. The existing gate shell predicate matched 22 of 22 simulated status cases. Shared endpoints and hosted CI have yet to be verified.

## Acceptance traceability

| Criterion | Current evidence | Change and proof |
| --- | --- | --- |
| 1. Shared DEV/TEST read-only inspection | `.devcore/project.conf:2–10` defines roles, databases and restricted TEST. `.devcore/render-map.tsv:1` renders both profiles. `AGENTS.md:39–44` assigns 55432/55433. `docs/evidence/VGAS-000_REPORT.md:1471–1472` separates disposable evidence from rollout. | Probe both endpoints with their assigned role. Record version, available and installed vector, effective privileges, schema, search path and actual cosine query. Record verified or pending for each endpoint. DevCore source merge `fcfbf750` alone leaves VGAS-10 pending. |
| 2. Reproducible local migrations and queries | `docs/development/application-ci.md:27–51` documents three migration lanes and older port 55434. `knowledge_feasibility_test.exs:7,12–20` requires 55434 and 180007/0.8.7. `test/support/feasibility/entra_store.ex:8–17` also rejects 55437. | Reproduce fresh and both predecessor upgrades on disposable 55436 and full suite on 55437. Record image identity, role, port, counts, cleanup and shared-workflow resumption criteria. |
| 3. Mandatory CI | `.github/workflows/application-ci.yml:13,59–110,119–150,210–221,244–266` requires probes, snapshots and migration lanes but uses the 0.8.4 tag and omits F04 opt-in. The supplied assurance identifies PostgreSQL 18.4. `test/test_helper.exs:3–11` intentionally excludes the seeded-upgrade case in other lanes. | Pin patched DB images, execute all five F04/F05 cases in the required shard that owns their file, and verify observed ExUnit case outcomes. Preserve the snapshot job, three migration lanes, planner and gate. |
| 4. Clean setup, reapply, role and recovery | `repo_foundation_test.exs:107–158` proves transaction isolation, a seeded upgrade and cosine distance. `priv/repo/migrations/20261126104038_vgas_003b2b_retrieval.exs:122–132` guards rollback with history. | Prove repeat migrate, restricted bootstrap, pre-use rollback/reapply and protected-history refusal on disposable data. Record backup/restore boundary. Track shared rollout separately through VGAS-10. |

## One PR

- [ ] `.github/workflows/application-ci.yml`. Resolve registry manifests by digest for both pgvector services and the current Gitleaks version. Probe the pinned DB image at runtime as `vgas_test` for `180007`, installed `0.8.7`, database ownership, restricted role flags and cosine distance. Keep existing provisioning order, wherein disposable bootstrap installs vector before Ecto runs as the app role.
- [ ] `test/voelgoed_ai/knowledge_feasibility_test.exs`. Keep the local opt-in. Require explicit loopback and an approved disposable port (55434 legacy, 55436, 55437) before fixture DDL. Keep exact database, user, server and extension checks and assert the restricted role flags. `test/support/feasibility/entra_store.ex` extends its existing loopback-only disposable branch to 55436 and 55437 with the same identity and vector guards.
- [ ] `test/support/ci_timing_formatter.ex` and new `.github/scripts/verify_test_results.py`. Add a separate results file, preserving timing output and history structure. The formatter records relative file, module, case and final state from `:test_finished`, and writes the report on `:suite_finished`. Use a new report path per run. The verifier exits nonzero for missing or malformed reports, failed/skipped cases, unapproved exclusions, or missing required coverage. Verify the event shapes against installed Elixir 1.20.5 and exercise the verifier with synthetic JSON.
- [ ] `docs/development/application-ci.md`. Add the workflow, exact runner invocation, baseline and rollout evidence expectations, deliberate upgrade exclusion, cleanup and rollback/restore boundaries. Keep `test/test_helper.exs`, the migration files, snapshots and production code intact. Use this plan as working material outside the implementation diff.

## CI behavior and negative proof

- [ ] Use 55436 for sharded CI PostgreSQL. Leave migration CI on its existing port and pin both definitions to the same verified digest. Enable `VGAS_F04_DISPOSABLE=1` only on the shard test step, with `VGAS_VERIFY_PGVECTOR=true` retained for all DB jobs. Check both flags before starting the shard command. Require the feasibility file before emitting the planner output and preserve whole-file assignment and timing upload. CI continues to provision the pinned OTP/Elixir versions with the existing BEAM action.
- [ ] In every shard require a passing result for each assigned file and zero skips. Allow only the specific predecessor test's exclusion outside its seeded lane. For the shard assigned the feasibility file require exactly five successful cases. In each migration lane require the Repo cosine case and zero skips, allow the predecessor test exclusion only on fresh and foundation upgrade, and require its passing result on `vgas001-upgrade`. Keep the existing migration and snapshot status requirements.
- [ ] Run the checker as `python3 .github/scripts/verify_test_results.py "$CI_TEST_RESULTS_OUTPUT" shard "${paths[@]}"` after the existing shard command. For migrations use the lane name in place of `shard` and pass `test/voelgoed_ai/repo_foundation_test.exs`. Make the file list mandatory and keep the check in the same required job as its test command.
- [ ] Demonstrate failure with (a) a temporary F04 skip, even if ExUnit exits 0, (b) an incorrect expected PostgreSQL version and, where a disposable predecessor image is available, the actual legacy image, (c) `env -u VGAS_F04_DISPOSABLE` in the required shard step, and (d) absent or incomplete result report. Repeat the happy path after removing each mutation. Keep negative experiments out of the PR diff.
- [ ] Exercise the exact gate shell predicate with every required dependency set individually to `failure`, `skipped` and `cancelled`. Require a nonzero exit for each, including the test matrix when `HAS_TESTS=true`. With `HAS_TESTS=false`, require the intentional `TEST=skipped` and all other jobs successful. Missing planner output fails. The optional Proof check is outside the application workflow's gate dependency list. Record it separately if it appears on the PR and verify GitHub's required check settings during handoff.
- [ ] On the hosted run compare each expected matrix conclusion with the gate conclusion. If a required lane is skipped or cancelled during verification, use the actual Actions result to confirm it cannot satisfy the required gate. Shell predicate tests establish the behavior for the supplied statuses. Hosted results establish what Actions reports.
- [ ] Record checkout SHA, PR head and base SHAs, and the Actions-tested merge SHA if the pull-request event uses one. On the exact candidate require the successful gate, actual shard and migration reports, snapshots, build and redacted secret scan. Require independent review of the complete diff and evidence before merge consideration.

F04/F05 coverage to preserve in the same test file at the planning base.

1. Line 34 covers independent approval, claim and publication guards.
2. Line 62 covers invalid or stale indexing and preservation of the active publication.
3. Line 108 covers competing publication switches across separate backend connections.
4. Line 146 covers expired/unreserved work and provider dispatch denial.
5. Line 164 covers 28 synthetic revisions and 20 labelled bilingual retrieval queries, ranking fusion and scope/revocation exclusions.

## Shared inspection commands

Run from the repository with shell tracing off. Use only the fixed role and target for each profile. The DevCore render row is `all`, so the TEST wrapper supplies both profiles to the command without displaying them. Keep SQL errors private by discarding raw stderr and record probe exit codes. The only printed database fields are the selected non-secret facts.

```bash
set +x
devcore-project doctor 2>/dev/null
printf 'DevCore doctor exit=%s\n' "$?"
for profile in DEV TEST; do
  devcore-project run test -- bash -c '
    set +x
    case "$1" in DEV) port=55432; role=vgas_dev ;; TEST) port=55433; role=vgas_test ;; *) exit 2 ;; esac
    key=${1}_DATABASE_PASSWORD
    PGPASSWORD="${!key:?missing DevCore credential}" PGOPTIONS="-c default_transaction_read_only=on" \
      psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U "$role" -d "$role"
  ' vgas-inspection "$profile" 2>/dev/null <<'SQL'
BEGIN READ ONLY;
SELECT current_database(), current_user, current_setting('server_version_num'),
       current_schema(), current_setting('search_path'), pg_get_userbyid(d.datdba),
       rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
FROM pg_roles JOIN pg_database d ON d.datname = current_database()
WHERE rolname = current_user;
SELECT default_version, installed_version FROM pg_available_extensions WHERE name = 'vector';
SELECT version, installed FROM pg_available_extension_versions WHERE name = 'vector' ORDER BY version;
SELECT e.extversion, n.nspname, pg_get_userbyid(e.extowner),
       has_schema_privilege(n.oid, 'USAGE'), has_type_privilege(t.oid, 'USAGE')
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
JOIN pg_type t ON t.typnamespace = n.oid AND t.typname = 'vector' WHERE e.extname = 'vector';
SELECT to_regtype('vector') IS NOT NULL AS vector_visible \gset
\if :vector_visible
SELECT '[1,0]'::vector <=> '[0,1]'::vector AS cosine_distance;
\endif
ROLLBACK;
SQL
  printf '%s read-only probe exit=%s\n' "$profile" "$?"
done
```

Record a missing or inaccessible extension as pending. Keep 55432/55433 read-only for VGAS-23 even if both endpoints pass. Resume the standard DevCore bootstrap for future authorized work after VGAS-10 records the owner-authorized rollout and both invariant probes pass. The separate disposable authority covers all migrations here.

## Disposable verification

- [ ] Confirm ports with `ss -ltn '( sport = :55436 or sport = :55437 )'`. Check `docker image inspect devcore-postgres:18.7-vector0.8.7 --format '{{.Id}} {{.Os}}/{{.Architecture}}'`. The planning pass saw Linux amd64 image ID `sha256:c41ec08b3d88535cf84e705cced68f199f40410c60218be157f3435a1544a929`. This local image ID does not identify a public registry manifest. Compare it to the approved image, then record actual runtime versions and verify roles as part of the run.
- [ ] Use a private steps file with one command per line and no credentials. Run `bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55436` on a fresh container per lane. For the full suite use 55437. The helper sets TEST and generates throwaway credentials, mounts one run-owned volume, and cleans up on exit. Disable tracing, strip provider keys from the runner environment, and publish only selected counts and exit codes. Suppress the legacy helper's raw failure excerpts if they cannot be safely reviewed. Verify container/volume removal and the released ports after every run.
- [ ] Fresh steps (one line apiece) run `mise exec -- mix deps.get --check-locked`, `mise exec -- mix setup`, `mise exec -- mix ecto.migrate --strict-version-order`, and `mise exec -- mix ecto.migrations`. Assert no pending migrations and unchanged migration history on reapply. Run `VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 0 test/voelgoed_ai/knowledge_feasibility_test.exs` and require five passes. Run `mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs` for the cosine and Oban checks.
- [ ] Start a fresh 55436 run for each upgrade lane using the predecessor steps below. Run the candidate migrations and repeat the migration listing, reapply, and Repo test commands above. Set `VGAS_VERIFY_VGAS001_UPGRADE=true` only for the seeded lane and require staff/audit preservation.
- [ ] Before adding fixture history, run `mise exec -- mix ecto.rollback --step 1` then `mise exec -- mix ecto.migrate --strict-version-order` on the clean disposable database. Rehearse refusal when B2b's guarded history exists with a synthetic publisher failure audit row matching lines 28–38 and 122–132 of its migration. Require the guard error and unchanged migration version and row. Take a private synthetic-only `pg_dump --format=custom --no-owner --no-acl` and test `pg_restore --list` before considering restore to a separately bootstrapped disposable target. Retain protected history by using a compatible forward fix or a separately approved, rehearsed restore. Shared backups, upgrades and destructive recovery require their own authority.
- [ ] Full lane on 55437 runs `VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 0` with the CI formatters, fresh private timing/results paths, and the checker's `shard` mode using the complete test file list. Also run `mise exec -- mix ash.codegen --check`, `mise exec -- mix format --check-formatted`, and `mise exec -- mix compile --warnings-as-errors`. Run `mise exec -- mix hex.audit` separately. Run `git diff --check` and the workflow's digest-pinned redacted Gitleaks scan. Record exact commands, exit codes, aggregate/pass counts and candidate SHA.

The predecessor steps below mirror `.github/workflows/application-ci.yml:184–209`. Use the applicable pair before the candidate checks. The latter pair creates the synthetic upgrade fixture. The target assertion precedes any fixture insert.

```bash
# Foundation-only run
set -e; mig=priv/repo/migrations/20261125141215_foundation_extensions_1.exs; base=$(mktemp -d); trap 'rm -r -- "$base"' EXIT; git show "aa93104fd476d208206288658e67bfe70e0780cd:$mig" > "$base/${mig##*/}"; cmp "$base/${mig##*/}" "$mig"; mise exec -- mix ecto.migrate --migrations-path "$base" --strict-version-order
mise exec -- mix ecto.migrate --strict-version-order
# Seeded VGAS-001 run
set -e; base=$(mktemp -d); trap 'rm -r -- "$base"' EXIT; for n in 20261125141215_foundation_extensions_1.exs 20261125205628_add_staff_authorization.exs; do git show "92ef0e39a7808d4ffa692b37b48ba3ee27a05e30:priv/repo/migrations/$n" > "$base/$n"; cmp "$base/$n" "priv/repo/migrations/$n"; done; mise exec -- mix ecto.migrate --migrations-path "$base" --strict-version-order
test "$TEST_DATABASE_HOST:$TEST_DATABASE_PORT:$TEST_DATABASE_USERNAME:$TEST_DATABASE_NAME" = 127.0.0.1:55436:vgas_test:vgas_test && PGPASSWORD="$TEST_DATABASE_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55436 -U vgas_test -d vgas_test -f .github/scripts/vgas001_upgrade_fixture.sql && mise exec -- mix ecto.migrate --strict-version-order
```

## Decisions for the orchestrator

1. Keep the five inherited tests in the required shard that owns their file. This closes the gap without changing scheduling or substituting unreviewed coverage.
2. Prefer a maintained upstream pgvector image only if its public amd64 digest executes PostgreSQL 18.7 with vector 0.8.7. If that artifact is unavailable, ask the DevCore owner for an approved pullable pinned build from the accepted source. A new build or publishing workflow needs scope approval. Treat the registry artifact as an implementation prerequisite.
3. Keep the authorized disposable helper external for this PR. Put the exact bootstrap, verification and cleanup steps in the runbook so teammates can reproduce them. Consider a sanitized repository helper only if the owner wants a maintained portable entry point. Never commit the attachment or environment values.
4. Keep VGAS-10 open until read-only checks establish actual shared deployment. Record the distinction in VGAS-23 and request separate owner action for shared rollout or recovery if needed. The ticket's disposable authorization supports independent verification while rollout is pending.

## Orchestrator addendum (2026-11-27, accepted with rulings)

I reviewed the plan against the four Plane VGAS-23 criteria, AGENTS.md and A-010. It is accepted with these rulings, which take precedence where they differ from the plan.

1. **Five cases in the owning shard. Approved.** The required shard that owns `knowledge_feasibility_test.exs` must run all five cases with `VGAS_F04_DISPOSABLE=1` and report exactly five passes. Unexpected skips fail the gate.
2. **Image.**
   - Pulling a public image is read-only and allowed. Use the official upstream `pgvector/pgvector` image for PostgreSQL 18 and pgvector 0.8.7, pinned by its amd64 manifest digest. Before it goes into CI, verify at runtime that it reports `server_version_num` 180007 and installed vector `0.8.7`.
   - If no public artifact passes that check, stop the CI image change. Record it as a blocker that needs an owner-approved pullable build. Do not build or publish any image. Continue with the rest of the PR, including the gate, the result verifier and the guards. The PR must not claim the baseline is aligned.
   - Pin the Gitleaks image by digest as well.
3. **Ports: modified.**
   - Do not move the CI PostgreSQL service ports. The containers are private to the runner, so there is no conflict there. Keep the existing CI port that the fixture guard already accepts (55434).
   - Extend the local guards in `knowledge_feasibility_test.exs` and `entra_store.ex` to also accept loopback 55436 and 55437. Keep the exact database, role, server and extension checks.
4. **Disposable helper.** It stays external. The runbook in `docs/development/application-ci.md` documents how to reproduce it: image, bootstrap, role, port, cleanup and how to resume the shared workflow. Never commit the attachment or any environment values.
5. **Shared rollout.** It stays with VGAS-10.
   - The DEV/TEST probes are read-only only: `default_transaction_read_only`, `BEGIN READ ONLY ... ROLLBACK`, stderr discarded, and only the selected non-secret facts printed.
   - Never print, echo or log credentials or connection strings, and never run tracing.
   - If a probe needs anything beyond a read-only connection, skip it and record the result as pending.
   - Make no change of any kind to the DevCore services, containers, roles or volumes.
6. **Scope.**
   - No production code, migrations, snapshots or `test/test_helper.exs` changes.
   - The new `verify_test_results.py` and the formatter extension stay minimal.
   - Negative experiments stay out of the diff; record them in `docs/plans/VGAS-23_VERIFICATION.md`.
   - Commit this plan as `docs/plans/VGAS-23_PLAN.md`.

**Ruling 3 revision (2026-11-27).**
- The base CI services bind port 55433, not 55434. Do not add a 55433 exception to F04. Move the CI ExUnit shard service to 55434 so the existing guard applies.
- The image-verification runner is approved. Use a private copy, kept outside the repository, of the disposable helper with only the IMG line changed. Use it on 55436 and 55437 only, and delete it afterwards.

**Split-clock test fix approval (2026-11-27).** The orchestrator approved the narrow `knowledge/retrieval_test.exs` change while VGAS-23 was being implemented, and recorded it in Plane VGAS-23 comment `3f211d90`. The two split-clock tests assumed the late month window was absent. From 2026-11-27, that window can already exist, because an earlier editorial test creates it (January 2027). The fix snapshots the window and asserts it is unchanged at both checkpoints. The no-late-charge assertion stays. Production and support files are untouched.
