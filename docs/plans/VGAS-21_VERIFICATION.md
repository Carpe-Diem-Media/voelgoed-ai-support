# VGAS-21 verification

The implementation is at `8e4e2df7ce87fc26d0d3260b90de0653f65f1ef7` on
`fix/vgas-21-privacy-proof`, based on `50e3f03`. The final record commit
adds evidence only. PR #20 is merged. PR #21 remained a draft when checked.
The [accepted plan](VGAS-21_PLAN.md) records the four Plane acceptance
criteria and the controlling addendum.

## Acceptance criteria

### AC1. Staff transport and private diagnostics

- The joined Bandit TLS test uses the encrypted cookie, cookie-backed
  CSRF and signed page tokens. It joins, patches to an authorized collection
  and refreshes after sign-out. Admin disable denies the next event, stale
  direct Ash mutation, protected HTTP request and new socket. The redirect
  and debug log capture omit the session and input probes.
- The staff test lanes replay wrong role, Origin, effective port, CSRF,
  expiry, disabled routes and public liveness. C1/C2 crash tests cover
  HTTP, TLS join and mount, params, event, upload and export. They assert
  fixed notices, capture metadata, check upload cleanup and exercise a
  public 404 in the same process as a staff request. The route and crash
  mutants below probe the controls separately.
- The portable download test compares the whole decoded document against
  the allowed schema, content and hash. Wrong role, mixed collection IDs
  and withdrawn scope return the generic denial without an attachment.
  The diagnostic events below carry operational fields only.

### AC2. Subscriber and retrieval SQL boundaries

- The synchronous inventory covers Phoenix and LiveView loggers and rejects
  unreviewed events, IDs and callbacks, including span exceptions. It rejects
  Repo/app subscribers and a callback swapped under a reviewed framework
  handler ID. The denial test projects count, bounded reason and generated
  correlation UUID. The existing support integration test verifies the
  typed ambiguous-delivery alert and suppression on replay.
- The SQL capture exercises lexeme generation, eligibility, rank and
  revalidation, with an ordinary Repo event as a positive control. The
  deterministic transport error exercises the unavailable path. A separate
  lock barrier on `article_embeddings` forces a real 750 ms statement
  timeout, which returns unavailable without private Repo events or app
  logs. The existing fixture-volume timing checks still report projected
  statistics. The boot inventory enumerates every attached handler with
  `:telemetry.list_handlers([])`, so no exporter or unreviewed subscriber
  on any event is registered at application boot.
- PostgreSQL 18.7 with pgvector 0.8.7 had `logging_collector=off`,
  `log_statement=none`, `log_min_error_statement=error`,
  `log_parameter_max_length=-1` and `log_parameter_max_length_on_error=0`.
  A label-only search of the container log found cancellation and the
  static eligibility SQL. It found no synthetic query marker. This
  server-side statement exposure is independent of the Ecto flags.
  It is recorded on VGAS-21 for VGAS-8/VGAS-24 to verify the hosted settings
  and collectors before activation.
- The [staff telemetry rule](../runbooks/staff-knowledge.md#telemetry-subscribers-and-export)
  specifies the handler review, allowlist and negative-capture requirements.

Verified pinned source for Phoenix 1.8.17 socket, transport and logger,
LiveView 1.2.15 channel, utility, diff and logger spans, Ecto 3.14.3,
Ecto SQL 3.14.0's independent event and log decisions, Postgrex 0.23.0
bindings and errors, and Ash 3.38.1's typed action entry. The local crash
probes exercise Bandit 1.15.0 and the OTP 29.1.2 primary filter.

### AC3. Portable eligibility and transfer

- Before the production edit, the date-only control passed and the
  timestamp failed in the parser, both direct import actions and connected
  upload preview. The fix masks only validated standalone minute timestamps
  in the digit scan. The email scan reads the original text. Typed dates,
  identifier character and digit limits, and hash version 1 are preserved.
- The direct and connected paths deny mixed batches with synthetic email,
  phone and ID patterns. They deny sensitive identifiers, raw mailbox text
  under a JSON filename and JSON with an extra mailbox field. Denials omit
  the input marker and leave no articles or editorial audit entries.
  Malformed timestamps and digit-adjacent substrings still fail. The
  inherited heuristic can miss numbers with consecutive separators
  between digit groups. A 12-digit number written exactly as a valid
  standalone `YYYY-MM-DD HH:MM` timestamp is also accepted by design.
  Both formats need a VGAS-11 policy decision.
- The direct preview and connected preview leave the collection empty.
  A valid apply creates one draft with no published pointer. The scoped
  export returns the exact canonical bilingual prose and content hash.
  Existing tests cover authority fields, stale tokens, replacement upload,
  scope loss, matching draft replay and selection of an existing revision.

### AC4. Staff lifecycle and retention

- Ordinary sign-out expires the local cookie. The joined tab and a copied
  cookie retain access until expiry or administrative revocation. The
  fixture observes already delivered content before the next event.
  On denial the view redirects and stops projecting private state.
  Previously delivered browser content can remain visible while idle.
- A role change that retains editor permission invalidates the previous
  generation. A fresh session after reactivation can reconnect while
  the old cookie continues to fail. Existing Accounts tests exercise
  distinct connections, a waiting privileged change, and idempotent
  management. The idle expiry test checks disconnect at the original
  deadline. Existing editorial tests cover sensitive approval, the link
  allowlist and fixture membership gates.
- Knowledge keeps canonical editorial revisions and bounded audit facts.
  Preview documents stay in private socket state and temporary upload
  storage. Sign-in and lifecycle records retain staff IDs and security
  history. G029 governs recovery payloads, holds and purge, and requires
  minimum dedupe and unresolved delivery references to survive.

## Historical evidence

GitHub reports PRs #10, #13, #14, #15, #16 and #17 merged at the heads
listed in the plan with their historical checks green. The retrieved
GitHub comment and review queries in the planning pass were empty.
The historical independent review dispositions come from VGAS-14 Plane
comments, as cited in the plan. PR #13's TEST query-event finding was
corrected by PR #17. C1 and C2 preserve the primary filter, route isolation,
private upload cleanup and separately scoped portable export. VGAS-25
added form controls. The relevant regression tests were run on this
candidate. Prior review and CI apply to the historical heads.

## Owner decisions and closure

- VGAS-9 owns the authorized test tenant, registration, TLS ingress,
  real F08 and the decision on immediate invalidation of connected or
  copied sessions at sign-out. Check the A-011 authentication pins and
  advisories before live verification and again before production.
- VGAS-11 owns membership, source verification, public links,
  applicability and sensitivity policy, independent editorial review
  and handoff rules. The membership and public-link paths use TEST
  fixtures. Sensitive approval stays denied pending authority.
- The information owner approves retention periods, hold and release,
  audit and restore handling, privacy redaction and permitted destinations.
  The seven- and 90-day proposals are design inputs. Scheduled cleanup,
  backup and restore proof carry into VGAS-24. The release owner separately
  approves staff or automation activation, live data and exporters.
- The orchestrator owns the PR, independent review and exact-head CI.
  Plane remains in progress pending that handoff. The author-side evidence
  below does not authorize merge or activation.

## Reproduction and commands

Elixir 1.20.5/OTP 29.1.2 and the locked dependencies were used. Each
database lane used an independent invocation of the supplied runner.

```sh
env -u OPENAI_API_KEY ERL_FLAGS='+S 4' bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$worktree" "$steps_file" "$port"
```

Port 55436 was used for focused, migration and mutant lanes. Port 55437
was used for the full suites. The TLS fixtures used 4205. No shared
DevCore database was used.

The pre-fix command exited 2 with all three selected tests failing and
47 excluded. The direct test called both Ash actions before its label-only
outcome assertion.

```sh
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:1032 test/voelgoed_ai_web/staff_knowledge_portable_test.exs:108:128 --seed 0
```

On the earlier implementation candidate, focused seed 0 exposed two
test fixture errors and the inherited consecutive-separator phone
limitation. The fixtures now use unique article references and a
phone format covered by the existing heuristic. A concurrent forced
compile invalidated the next focused seed-0 run while BEAM modules
were being loaded. Its corrupted build result was discarded. The
first seed-8125 focused run and seed-103 full run after that used
`provision` for an existing disabled identity. Both exited 2 with
one failing test. The reactivation probe now calls
`Accounts.reactivate/4`. The final runs below use this corrected probe.

### Migration lanes

- Fresh lanes ran `mise exec -- mix ecto.migrate --strict-version-order`
  and the focused lane ran `mise exec -- mix ash.codegen --check`.
  Both commands exited 0.
- Foundation upgrade used `git show aa93104:priv/repo/migrations/20261125141215_foundation_extensions_1.exs`.
  The staff upgrade added `git show 92ef0e3:priv/repo/migrations/20261125205628_add_staff_authorization.exs`.
  Both extracted migrations matched the current files via `cmp`.
  In each lane the predecessor migration and candidate upgrade exited 0.
  The seed SQL and both migration status checks exited 0. The foundation
  test passed 6 with the seeded assertion excluded. The staff upgrade
  passed all 7.

```sh
mise exec -- mix ecto.migrate --migrations-path "$vgas_base_migrations" --strict-version-order
# Seeded staff lane only
PGPASSWORD="$TEST_DATABASE_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$TEST_DATABASE_HOST" -p "$TEST_DATABASE_PORT" -U "$TEST_DATABASE_USERNAME" -d "$TEST_DATABASE_NAME" -f .github/scripts/vgas001_upgrade_fixture.sql
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix ecto.migrations | awk '/down/{exit 1}'
mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0
# The seeded staff lane uses this invocation in place of the previous test command
VGAS_VERIFY_VGAS001_UPGRADE=true mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0
```

### Build, dependencies and repository checks

The following commands exited 0. Dependency audit and test planning
also exited 0 on `50e3f03`. The candidate planner produced eight shards
with 31 test files and `has_tests=true`. Gitleaks 8.30.1 reported no leaks.

```sh
HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked
mise exec -- mix deps.unlock --check-unused
mise exec -- mix hex.audit
mise exec -- mix format --check-formatted
MIX_ENV=test ERL_FLAGS='+S 1' ELIXIR_ERL_OPTIONS='+S 1' mise exec -- mix compile --force --warnings-as-errors
MIX_ENV=test ERL_FLAGS='+S 2' ELIXIR_ERL_OPTIONS='+S 2' mise exec -- mix compile --force --warnings-as-errors
python3 .github/scripts/plan_tests.py
git diff --check 50e3f03...HEAD
git diff --exit-code 50e3f03...HEAD -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots .github lib/voelgoed_ai/support lib/voelgoed_ai/intelligence lib/voelgoed_ai/governance
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts="$(git rev-parse 50e3f03)..HEAD" --no-banner .
```

The separately requested non-TEST check
`env -u OPENAI_API_KEY MIX_ENV=dev ERL_FLAGS='+S 4' mise exec -- mix compile --force --warnings-as-errors`
exited 1 on the candidate and base. A comparison of the application
warning locations was identical, with 17 locations in
`intelligence/embedding.ex`, `knowledge/editorial.ex`,
`support/{chatwoot_adapter,configuration,ingress,ownership,recovery,run_processing}.ex`
and `voelgoed_ai_web/chatwoot_webhook.ex`. VGAS-19 owns the clean
non-TEST build. The cold DEV dependency build also printed dependency
warnings before the application compile. There were no Compose or
visual changes.

### Mutants

Each row runs `mise exec -- mix test <selector> --seed 0` in the
disposable mutant worktree. The mutation script applied one change,
ran the selected test and restored its original source in a
`finally` block. It verified a single match for each patch. Exit 2
means the single selected test failed. The runner exits 1 in this
lane because it propagates the expected failing test steps.

- Omit OTP primary filter installation. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:22` exited 2 (killed).
- Ignore the Bandit staff crash. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:22` exited 2 (killed).
- Allow the Phoenix error renderer to log the staff failure. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:22` exited 2 (killed).
- Ignore the staff channel pool crash fallback. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:124` exited 2 (killed).
- Ignore the transport join fallback. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:124` exited 2 (killed).
- Restore debug router dispatch logging. `test/voelgoed_ai_web/staff_knowledge_live_test.exs:231` exited 2 (killed).
- Restore staff request logging. `test/voelgoed_ai_web/staff_knowledge_live_test.exs:231` exited 2 (killed).
- Bypass the encoded staff-path guard. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:58` exited 2 (killed).
- Disable cookie-backed WebSocket CSRF. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:18` exited 2 (killed).
- Disable the Phoenix Origin check. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:138` exited 2 (killed).
- Bypass the endpoint effective-origin guard. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:114` exited 2 (killed).
- Remove the connected expiry timer. `test/voelgoed_ai_web/staff_knowledge_live_test.exs:222` exited 2 (killed).
- Skip the generation comparison with the support-only role transition. `test/voelgoed_ai_web/staff_knowledge_live_test.exs:415` exited 0 (survived this test).
- Skip staff marker cleanup before a public request. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs:85` exited 2 (killed).
- Restore Ecto telemetry on the timeout setup statement. `test/voelgoed_ai/knowledge/retrieval_test.exs:30` exited 2 (killed).
- Restore Ecto telemetry on the private SQL statement. `test/voelgoed_ai/knowledge/retrieval_test.exs:30` exited 2 (killed).
- Force debug logging on the private statement. `test/voelgoed_ai/knowledge/retrieval_test.exs:30` exited 2 (killed).
- Restore the date false positive by scanning the original digits. `test/voelgoed_ai/knowledge/editorial_test.exs:1032` exited 2 (killed).
- Skip all PII checks for text with a timestamp match. `test/voelgoed_ai/knowledge/editorial_test.exs:1049` exited 2 (killed).
- Mask timestamps without standalone-token boundaries. `test/voelgoed_ai/knowledge/editorial_test.exs:1049` exited 2 (killed).
- Skip free-text email detection. `test/voelgoed_ai/knowledge/editorial_test.exs:1049` exited 2 (killed).
- Skip free-text contact-digit detection. `test/voelgoed_ai/knowledge/editorial_test.exs:1049` exited 2 (killed).
- Skip the apply confirmation token check. `test/voelgoed_ai_web/staff_knowledge_portable_test.exs:271` exited 2 (killed).
- Accept extra portable entry fields. `test/voelgoed_ai_web/staff_knowledge_portable_test.exs:245` exited 2 (killed).
- Allow a partial result for a mixed export selection. `test/voelgoed_ai_web/staff_knowledge_portable_test.exs:47` exited 2 (killed).
- Skip the generation comparison while the staff member retains editor permission. `test/voelgoed_ai_web/staff_knowledge_live_test.exs:196` exited 2 (killed).

The initial stale-generation mutation survived the support-only role
transition. Removing the generation check left the role denied by
`StaffSession.knowledge_access/1`, and the protected editorial read
also requires an appropriate role. The follow-up kept the editor role
and changed the generation, isolating the session check. That test
killed the same mutation without weakening a role guard. The SQL
mutants ran the normal Repo telemetry control before the privacy
assertions. Focused baseline results after restoration follow below.

### PostgreSQL log check

The runner used the following steps after the focused timeout test. Each
exited 0. Output was limited to settings and probe labels.

```sh
PGPASSWORD="$TEST_DATABASE_PASSWORD" psql -X -At -v ON_ERROR_STOP=1 -h "$TEST_DATABASE_HOST" -p "$TEST_DATABASE_PORT" -U "$TEST_DATABASE_USERNAME" -d "$TEST_DATABASE_NAME" -c "SELECT 'Result: ' || name || '=' || setting FROM pg_settings WHERE name IN ('log_statement','log_min_error_statement','log_parameter_max_length','log_parameter_max_length_on_error','logging_collector') ORDER BY name"
pg_container=$(docker ps -q --filter "name=vgas-disposable-$TEST_DATABASE_PORT-")
for marker in 'STATEMENT:  WITH eligible AS MATERIALIZED' 'canceling statement due to statement timeout' 'syntheticretrievaltimeout'; do
  if docker logs "$pg_container" 2>&1 | rg -Fq "$marker"; then
    printf 'Result: PostgreSQL log matched label %s\n' "$marker"
  else
    printf 'Result: PostgreSQL log did not match label %s\n' "$marker"
  fi
done
```

### Candidate test results

The full suites used the following steps on 55437. Both test
commands exited 0 with 580 passed and one excluded. The exclusion
was the seeded predecessor check, which passed in its own lane.
The suites included the disposable F04 and local F08 checks.

```sh
VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 103
VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 8125
```

The focused lanes used the following commands on 55436 after
restoring the mutations.

```sh
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/accounts test/voelgoed_ai/knowledge/{editorial,retrieval,publication}_test.exs test/voelgoed_ai/telemetry_privacy_test.exs --seed 0
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs test/voelgoed_ai_web/chatwoot_webhook_test.exs test/voelgoed_ai/accounts test/voelgoed_ai/knowledge/{editorial,retrieval,publication}_test.exs test/voelgoed_ai/telemetry_privacy_test.exs --seed 8125
```

Both focused commands exited 0 with 262 passed and no exclusions.

### Cleanup

The runner reported `container=0 volume=0` for the focused, full,
migration and mutant invocations. The Docker container and volume
inventories showed no disposable resources for ports 55436 or 55437.
`ss -H -ltn '( sport = :55436 or sport = :55437 or sport = :4205 )'`
returned no listeners. The base and mutant worktrees were removed.
Before removal, the restored mutant tree matched the implementation
commit. The private steps and runner transcripts were removed at handoff.

## Review 1 corrections

The independent review of `c88ed95` returned CHANGES_REQUIRED, with one
MEDIUM finding. The boot inventory listed handlers under 12 fixed prefixes
only. A boot handler on `[:oban, :job, :stop]` survived as mutant T2, and a
replacement on `[:phoenix, :socket_drain]` survived as mutant T3. That left
the exporter claim above unenforced.

The inventory now enumerates `:telemetry.list_handlers([])` and allowlists
exactly the 16 reviewed framework tuples. That includes Phoenix's
`socket_drain` logger, which already attached at boot. The negative test now
also attaches on `socket_drain`, `[:oban, :job, :stop]` and an arbitrary
event.

The review's other findings are handled as follows:

- **LOW**, the timestamp-shaped 12-digit number: recorded above for VGAS-11.
- **NIT**, the sign-out assertion: now commented as current behaviour owned
  by VGAS-9.
- **NIT**, the TLS event-hook recheck isolation: no change. The forms and
  portable tests kill that mutant.

The correction was verified on disposable PostgreSQL 18.7 with pgvector
0.8.7 at port 55436:

- A forced TEST compile with warnings as errors exited 0.
- `telemetry_privacy_test.exs` and `staff_knowledge_live_test.exs` at seed 0
  gave 17 passed.
- With a boot handler on `[:oban, :job, :stop]` (T2) or
  `[:phoenix, :socket_drain]` (T3) added to `application.ex`, the inventory
  tests fail: 1/4 passed in each case. Each mutant was restored before the
  next step.
- The inventory file passed with `--repeat-until-failure 10` and exit 0.
