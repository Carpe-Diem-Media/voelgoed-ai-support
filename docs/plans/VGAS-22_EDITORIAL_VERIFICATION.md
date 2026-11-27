# VGAS-22 editorial integrity and isolated fixtures

This record covers section 2 of the accepted VGAS-22 plan. The base was
`e2aa3aa1cdc08060b0df381522a0260d39a8ad18`, after PR #24. The related
contributor migration proof is [recorded separately](VGAS-22_CONTRIBUTOR_VERIFICATION.md).

## Editorial behavior

Edit and Submit for review require an active draft, the scoped editor role and
a matching stored content hash. Submit also requires a reviewable source.
Withdraw requires an active draft or in-review revision, a scoped editor or
reviewer and a matching stored hash. The write actions still compare the
displayed version and hash with the locked row. The regression opens an intact
draft, confirms Edit and Withdraw are present, changes the stored content and
refreshes the page to check that both controls disappear.

The malformed-date regression mounts an approved revision whose stored
effective date is a JSON number. It checks the neutral value next to
"Effective from", the publication-unavailable status and the absent publish
control. The existing offset-date cases still reject publication and use UTC
instants to select the notice.

The C2 regressions cover the contributor whose approve hint is true and whose
self-approval flag hides the form, the independent approval and explicit
publication sequence, the displayed pointer and sensitive-content denial.
The stale review, forged approval and stale pointer tests compare revision
fields, audit counts and job counts before and after refusal.

## Rollover reproduction

Each lane used a fresh container on `127.0.0.1:55434` with the public
`pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00`
image. The [disposable workflow](../development/application-ci.md#disposable-local-workflow)
provided the restricted TEST owner and installed pgvector. The baseline and
strict migration checks exited 0 before the test command in each lane.
PostgreSQL reported 18.7 and pgvector 0.8.7. Commands used Mise with
Erlang 29.1.2, Elixir 1.20.5 and `ELIXIR_ERL_OPTIONS='+S 4'`.

```sh
bash .github/scripts/verify_postgres.sh 180007
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:304 --seed 0
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:304 --seed 1
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:313 --seed 0
mise exec -- mix test test/voelgoed_ai/knowledge/editorial_test.exs:313 --seed 1
```

Both base runs at line 304 exited 2 on the three-second wire assertion.
A temporary seed 0 trace captured the committed dispatch at 71 ms, local
catalog load at 75 ms, original wait expiry at 3,034 ms and fake adapter
entry at 3,585 ms. At expiry the worker and embedding were running and the
81,920 nano-USD reservation was held. The diagnostic-only extended wait
allowed that lane to finish. The committed test resolves the pinned embedding
profile through ReqLLM before starting the worker. Both candidate runs at line
313 exited 0 with one test passed. The three-second assertion, transport
fixture, reservation and origin-window settlement assertions are the original
ones.

## Test commands

```sh
editorial=test/voelgoed_ai/knowledge/editorial_test.exs
forms=test/voelgoed_ai_web/staff_knowledge_forms_test.exs
live=test/voelgoed_ai_web/staff_knowledge_live_test.exs
publication=test/voelgoed_ai/knowledge/publication_test.exs
auth=test/voelgoed_ai_web/staff_knowledge_auth_test.exs

# Base C2 selectors
mise exec -- mix test "$forms:73" "$forms:119" "$forms:196" "$forms:236" --seed 0

# Candidate
mise exec -- mix test "$editorial:893" "$editorial:1118" "$editorial:1139" "$editorial:1171" --seed 0 --trace
mise exec -- mix test "$live:432" --seed 0
mise exec -- mix test "$live:432" --seed 1
mise exec -- mix test "$editorial" "$forms" "$live" "$publication" "$auth" --seed 0
mise exec -- mix test "$editorial" "$forms" "$live" "$publication" "$auth" --seed 8125
VGAS_F04_DISPOSABLE=1 mise exec -- mix test --seed 0
```

The four C2 selectors passed on the base, and the four contributor selectors
passed on the candidate. The isolated staff index-status test
passed at both seeds, and the five-file regression group passed all 91 tests
at seeds 0 and 8125. The historical index-status failure did not recur in
these runs and its cause remains open. The full run passed 614 tests with one
predecessor-only exclusion. It emitted the existing standalone backfill
fixture discovery warning and warnings from the Chatwoot feasibility tests.
The editorial regression group also logged its expected synthetic reservation
commit failure.

The stale draft LiveView regression failed on the base because Edit was still
present after refresh. The malformed date already mounted on the base. Both
regressions passed on the candidate.

Each temporary mutation ran
`mise exec -- mix test "$forms:78" --seed 0` and exited 2. Removing the
contributor condition from the form made the Approve control visible.
Removing the locked action's attestation comparison let the forged approval
transition the revision. After restoring the source, the contributor,
stale-draft and malformed-date selectors passed together at seed 0.

## Hallmark and accessibility

The repository has no `DESIGN.md`. The revision template and existing staff
stylesheet define the render used for this check. A temporary synthetic
LiveView fixture captured the intact draft, stale draft and malformed-date
revision after removing scripts, session attributes and form tokens. The
installed renderer accepts HTML and CSS files, so the capture provided the
render target. It needed no HTTP server.

```sh
CHROME_PATH=/opt/google/chrome/chrome HALLMARK_PUPPETEER=/tmp/vge-hallmark \
  node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs \
  "$capture_directory" --scope page --render
CHROME_PATH=/opt/google/chrome/chrome HALLMARK_PUPPETEER=/tmp/vge-hallmark \
  node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs \
  "$capture_directory" --scope app --render
```

Both scopes rendered five screenshots per state. The intact and stale
drafts reported zero FAIL, REFLEX or WARN findings. F23 used the stylesheet's
existing private-page answer. The malformed-date capture exited 1 in both
scopes on both base and candidate. Rule 19 flagged the same neutral timestamp
glyph in the base and candidate markup. The change introduces zero FAIL or
REFLEX findings and needs no REFLEX waiver.

Chrome 158 verified tab order, visible focus and keyboard activation of
Refresh status in the captured HTML at 320 and 1280 px. Each captured state
fit its viewport and honored reduced motion. The neutral timestamp and
unavailable notice had 17.24:1 text contrast. LiveView tests exercised
connected mounts, refresh and form submissions.

## Repository and database checks

```sh
mise exec -- mix deps.get --check-locked
mise exec -- mix format --check-formatted
MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force
MIX_ENV=test mise exec -- mix ash.codegen --check
MIX_ENV=test mise exec -- mix ecto.migrations
HEX_OFFLINE=1 mise exec -- mix hex.audit
python3 .github/scripts/plan_tests.py
bash -n .github/scripts/verify_postgres.sh
shellcheck .github/scripts/verify_postgres.sh
git diff --check e2aa3aa1
git diff --exit-code e2aa3aa1 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots .github
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e2aa3aa1..HEAD' --no-banner .
ss -H -ltn '( sport = :55434 or sport = :4190 or sport = :4205 )'
```

Locked dependencies, formatting, forced TEST compilation, snapshot
consistency, the cached dependency audit, planning and shell checks exited 0.
The fresh migration lane reported 17 applied migrations with none pending.
Two separate fresh containers rehearsed upgrades with the workflow's
predecessors `aa93104fd476d208206288658e67bfe70e0780cd` and
`92ef0e39a7808d4ffa692b37b48ba3ee27a05e30`. Each predecessor file matched the
candidate byte for byte and was applied using
`mise exec -- mix ecto.migrate --migrations-path "$predecessor_migrations" --strict-version-order`.
The staff lane then loaded `.github/scripts/vgas001_upgrade_fixture.sql`
with `psql -X -q -v ON_ERROR_STOP=1` as the disposable owner.
Both ran strict candidate migrations and ended with all 17 applied and none
pending. The foundation suite
`mise exec -- mix test test/voelgoed_ai/repo_foundation_test.exs --seed 0`
passed six tests with one excluded on the foundation upgrade. The staff
upgrade repeated that command with `VGAS_VERIFY_VGAS001_UPGRADE=true` and
passed seven tests.

All 11 run-owned containers and their anonymous volumes were removed.
Ports 55434, 4190 and 4205 were free after verification. The runner used the
disposable database for migrations and tests and the temporary capture test
was removed from the worktree. Redacted local logs and sanitized render
captures are in `/tmp/vgas22-section2.YAVfhE`. Exact-head hosted CI and
independent review belong to the PR handoff.
