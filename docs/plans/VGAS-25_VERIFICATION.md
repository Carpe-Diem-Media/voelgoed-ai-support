# VGAS-25 verification

Base `3090b1f50aef29331df21ff23318a5866f5085ca` (merged PR #15).
Branch `fix/vgas-25-staff-control-accuracy`. This is the follow-up to
[VGAS-003 C2](VGAS-003C2_VERIFICATION.md).

## Findings and fixes

- **LOW-1.** The review control uses `Content.reviewable?/1`, the same
  source check as the submit action. The hint also checks stored snapshot
  integrity with the action's hash predicate. It already checked draft
  status, the editor's collection scope, and active collection and article
  status. The locked action still checks the submitted version and hash
  against the latest row. The draft with no sources tells the editor to
  add a source reference. A forged submit with a current token leaves the
  status and edit version intact. The staff runbook describes the notice.
- **LOW-2.** The forms tests check that approved revisions in internal
  collections and approved `escalate_only` revisions have neither
  `#request-publish` nor `#publication-notice`. The approve action
  refuses sensitive content with `:approval_denied`. The sensitive
  revision test covers the reachable `:in_review` state, the denied
  approval, and the absence of approval and publication controls and the
  publication notice.
- **NIT-3.** A forged Draft form token carries otherwise valid edits.
  The test checks the reload message and the persisted status, edit
  version, content hash, and content.
- **NIT-4.** Both publication date fields reject malformed stored values
  with `{:error, :stale_request}`. Eligibility still requires zero-offset
  timestamps, as stored by the normal write path. Staff notices compare
  valid offsets as UTC instants. Editorial reads and the revision
  template handle non-string timestamps without raising. Tests bypass
  the write parser to store integers, garbage strings and offset strings.

## Local checks

Database steps ran in TEST on PostgreSQL 18.7 and pgvector 0.8.7 through
the disposable helper. Each steps file began with locked dependency
resolution. Commands used the repository's Elixir 1.20.5 and OTP 29.1.2.
The suites bound TLS on 4205. The browser capture bound TLS on 4204.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55434
```

The pre-fix focused run below exited 2 with 48 passed and four failures.
The failures covered the missing-source control, stale hash, malformed
dates and offset ordering. Dependency resolution and the fresh
migration step exited 0. The helper exited 1 on the expected test failures.

```sh
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_forms_test.exs test/voelgoed_ai/knowledge/editorial_test.exs --seed 0
```

The verification lane ran these commands.

```sh
mise exec -- mix deps.get --check-locked
mise exec -- mix format --check-formatted
ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --warnings-as-errors --force
ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --warnings-as-errors --force
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 0
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 8125
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 43117
mise exec -- mix test --seed 0
mise exec -- mix test --seed 8125
```

Every step exited 0. Each of the three staff runs passed 89 tests.
Each full run passed 501 tests, with
five skipped and one excluded. The exclusion is the opt-in VGAS-001
upgrade assertion, which also ran in the seeded staff upgrade lane.
Both full runs exercised the expected synthetic reservation commit
failure.

### Predecessor migrations

The two upgrade lanes reused the commands in the
[C2 verification record](VGAS-003C2_VERIFICATION.md#full-tests-and-upgrade-lanes).
Each extracted the predecessor files with `git show`, compared them with
`cmp`, applied them using
`mise exec -- mix ecto.migrate --migrations-path "$vgas_base_migrations" --strict-version-order`,
and then ran `mise exec -- mix ecto.migrate --strict-version-order` and
`mise exec -- mix ecto.migrations`. The staff lane loaded the synthetic
`.github/scripts/vgas001_upgrade_fixture.sql` using
`psql -X -q -v ON_ERROR_STOP=1` with the disposable TEST connection.

```sh
mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs
VGAS_VERIFY_VGAS001_UPGRADE=true mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs
```

Each upgrade step and helper exited 0. Both reported zero pending
migrations. The foundation lane passed six tests with one excluded.
The seeded staff lane passed all seven tests. A separate disposable
check counted 16 applied migrations in the output of
`mise exec -- mix ecto.migrations` after a fresh migration and exited 0.

## Mutations

The implementation commit was `8028418f31c82b97328793e038d54cfb2c7bafde`
before mutation. Each run used `mise exec -- mix test <target> --seed 0`
inside the disposable helper. The selected test in each mutant exited 2
with one failure. After each mutation, `git checkout -- lib test config`
and `git diff --exit-code` exited 0.

| Mutation | Target | Cause of failure |
| --- | --- | --- |
| Submit hint skips `Content.reviewable?/1` | `staff_knowledge_forms_test.exs:20` | A draft without a source shows Submit for review. |
| O6. Publish hint ignores collection audience | `staff_knowledge_forms_test.exs:215` | The internal collection's revision shows Request publication. |
| O7. Draft save skips the token check | `staff_knowledge_forms_test.exs:168` | The forged save writes and redirects. |
| Embedding parser accepts non-binary inputs | `editorial_test.exs:38` | The integer reaches the ISO parser and raises. |
| Editorial ordering omits the non-binary fallback | `editorial_test.exs:38` | The stored integer makes `read_revision` raise. |
| Editorial ordering matches only zero-offset dates | `editorial_test.exs:49` | The stored offset does not match the date comparison clause. |

The initial mutant wrapper expected the old ExUnit summary format and
exited 1 despite each selected test failing as expected. The corrected
wrapper recognized `Result: 0/1 passed`. Its six steps exited 0, with
six mutants killed. The final restored run of the two targeted test
files exited 0 with 52 passed at seed 0. The corrected helper exited 0.

## Hallmark and accessibility

The temporary authenticated TLS capture ran
`mise exec -- mix test test/vgas_25_capture_temp.exs --seed 0` and
exited 0 with one passed test. The fixture used a synthetic FAQ and
removed scripts, staff and form tokens, hidden inputs and answer text
from the capture. The capture used the existing staff stylesheet.
The helper removed the temporary test on exit.

The notice appeared in both the initial HTML and the connected
LiveView. The browser verified reduced-motion layout at 320 px and
1280 px, visible focus on Refresh status, keyboard activation and
17.24:1 notice text contrast. The desktop and mobile renders place the
notice above Edit draft and the withdraw form.

```sh
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope page --render
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope app --render
```

Both commands exited 0 against the sanitized `capture-missing-source`
directory. Each rendered five screenshots and reported zero FAIL,
REFLEX or WARN findings. Both reported the existing F23 answer for
private staff pages. No waiver was needed.

## Repository checks

```sh
git diff --check
git diff --check 3090b1f
git diff --exit-code 3090b1f -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots
mise exec -- mix deps.unlock --check-unused
HEX_OFFLINE=1 mise exec -- mix hex.audit
python3 .github/scripts/plan_tests.py
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='3090b1f..HEAD' --no-banner .
ss -ltn '( sport = :4204 or sport = :4205 or sport = :55434 )'
git status -sb
```

The checks exited 0. The dependency audit found no retired packages or
known advisories in the local cache. The planner emitted eight shards.
The redacted Gitleaks scan found no leaks in the implementation commit.
Compose validation is outside this diff. The checkout used the disposable
port 55434 for all database work. The teardown check found ports 4204,
4205 and 55434 free, and the tracked worktree was clean after mutation
restoration.

The following scans exited 1 with zero matches.

```sh
rg -n 'authorize\?: false' lib
rg -n 'start_async|assign_async|stream_async|Task\.(async|start)|spawn(_link)?\(' lib/voelgoed_ai_web/knowledge_live
```

## Completion assessment

VGAS-25, BUG_FIX. Author self-assessment. Seven of seven local criteria
passed. There were zero failed, unverified or unfinished local
criteria.

1. Missing-source submit hint, notice and forged event refusal.
2. Audience and response restrictions in the staff forms, including
   the reachable sensitive review state.
3. Forged Draft token refusal with the original stored revision intact.
4. Total stored date handling, offset ordering and refused eligibility.
5. Pinned-file and code-ban checks.
6. Required suites, compile and codegen checks, six killed mutants and
   the rendered Hallmark checks.
7. Verification record and staff runbook.

Implementation Score **10/10** (requirements 4/4, observed verification
3/3, correctness and risk 2/2, handoff 1/1). Confidence **95%**, based on
the repeated PostgreSQL suites, mutation failures, and authenticated
render. Hosted CI and independent review remain for the orchestrator.

Verification Status **VERIFIED** for the local VGAS-25 scope. Merge
status `NOT_VERIFIED_FOR_MERGE`. The exact command logs and sanitized
render are in the local evidence directory `/tmp/vgas-25.Ht8OXb`.
