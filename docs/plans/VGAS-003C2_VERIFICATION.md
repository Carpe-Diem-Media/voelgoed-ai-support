# VGAS-003 C2 verification

Plane VGAS-14. Base `58ed481ed61f1b68da16ea5f6f87ab008ceab567`. Runtime candidate
`5d8033eb8a96098566de6f3e5ab9a7e77c8acc6f` on
`feat/vgas-003c2-staff-knowledge-forms`. This record covers C2 of the
[accepted plan](VGAS-003C_PLAN.md) and the C2 follow-ups from the
[C1 review record](VGAS-003C1_VERIFICATION.md).

## Scope and acceptance criteria

1. Collection administration and assistant draft grants use the existing
   scoped actions. Draft forms use the approved FAQ schema, preserve exact
   answer text and keep the displayed snapshot on the server.
2. Review and publication are separate confirmations. The control omits
   contributor approval. The action denies a forged independent
   attestation. The publication action still checks the displayed pointer
   and the retry uses the approved revision.
3. Import accepts one JSON file through LiveView. Apply requires a preview
   of the same server-held inputs. Scope loss, imported authority and
   invalid uploads are denied. Export uses CSRF, the 4 KiB body limit,
   explicit article selection and private download headers.
4. Staff transport remains default-off. Mutation targets and role
   rechecks use the existing cookie session and Ash authorization.
5. Staff crash tests cover form events, unexpected messages, upload cleanup,
   the export controller and the same-process public request after a staff
   404. Staff views start no async tasks. The pinned telemetry allowlist is
   the same as C1.
6. The application compiles with the locked dependencies and no schema
   changes. Staff and full regression suites, migration lanes and targeted
   mutations are recorded below.
7. Authenticated browser and Hallmark evidence covers the staff forms,
   import, export and approval states.
8. The [staff knowledge runbook](../runbooks/staff-knowledge.md) records the
   gate, editorial actions, transfer limits, log policy, rollback and
   VGAS-9 decisions.

## Execution

All database checks used TEST on the disposable PostgreSQL 18.7 server
with pgvector 0.8.7. The helper received `"$PWD" "$vgas_steps" 55434`
and each steps file started with `mise exec -- mix deps.get --check-locked`.
The shared DevCore databases were outside the verification. The real TLS
fixture used port 4205. The commands used Elixir 1.20.5 and OTP 29.1.2.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55434
```

The commands below exited 0 in the fresh lane.

```sh
mise exec -- mix deps.get --check-locked
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --warnings-as-errors --force
ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --warnings-as-errors --force
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 0
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 8125
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_*_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 43117
```

All three staff runs passed 77 tests. The fresh lane applied 12 migrations.
The forced compiles used the TEST configuration supplied by the helper.

```sh
mise exec -- mix deps.unlock --check-unused
mise exec -- mix hex.audit
python3 .github/scripts/plan_tests.py
git diff --check
git diff --check 58ed481
git diff --exit-code 58ed481 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='58ed481..HEAD' --no-banner .
```

These checks exited 0. Hex found no retired packages or advisories.
The planner produced eight shards. Gitleaks reported no leaks.
`rg -n 'authorize\?: false' lib` exited 1 with no matches.
Compose files are outside the C2 diff.

### Full tests and upgrade lanes

`mise exec -- mix test --seed 0` and `mise exec -- mix test --seed 8125`
each exited 0 with 486 passed, five skipped and one excluded. The
seeded VGAS-001 upgrade assertion accounts for the exclusion. Both full runs
reached the expected synthetic reservation commit failure in its rollback
test.

The two upgrade lanes reused the predecessor procedure in the C1 record.
Each step exited 0. Commands and exit codes are in the private evidence
directory listed below.

- Foundation upgrade. Extract
  `priv/repo/migrations/20261125141215_foundation_extensions_1.exs` via
  `git show` at `aa93104fd476d208206288658e67bfe70e0780cd`, compare via
  `cmp`, and run `mise exec -- mix ecto.migrate --migrations-path "$vgas_base_migrations" --strict-version-order`.
  Then apply the current migrations with
  `mise exec -- mix ecto.migrate --strict-version-order`, check
  `mise exec -- mix ecto.migrations` for pending rows, and run
  `mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs`.
  Six tests passed and one was excluded.
- Staff upgrade. Extract and compare the same foundation migration and
  `20261125205628_add_staff_authorization.exs` at
  `92ef0e39a7808d4ffa692b37b48ba3ee27a05e30`. Apply those migrations in order
  with the same command. Load `.github/scripts/vgas001_upgrade_fixture.sql`
  with `psql -X -q -v ON_ERROR_STOP=1` using the runner's TEST connection,
  then apply and check the current migrations. Run
  `VGAS_VERIFY_VGAS001_UPGRADE=true mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs`.
  Seven tests passed.

### Mutation checks

Each mutation ran on the committed runtime candidate with
`mise exec -- mix test test/voelgoed_ai_web/<target> --seed 0`.
The tests compiled. Each selected test failed with exit 2. The runner
restored `lib test config` with `git checkout -- lib test config` after each
case and checked the restoration with `git diff --exit-code -- lib test config`.
The imported-authority mutation script initially missed its source anchor
and exited 13. The corrected mutation ran one test and exited 2. After
restoration, the portable suite passed all eight tests at seed 0.

| Mutation | Target | Test assertion that failed |
| --- | --- | --- |
| Omit the displayed review snapshot check | `staff_knowledge_forms_test.exs:18` | A changed draft requires reload |
| Omit comparison with the saved publication pointer | `staff_knowledge_forms_test.exs:136` | A stale pointer requires reload |
| Apply the uploaded bytes without a preview | `staff_knowledge_portable_test.exs:81` | An unpreviewed file is refused |
| Discard the imported publication state before validating portable entries | `staff_knowledge_portable_test.exs:107` | Imported authority is rejected before preview |
| Ignore the contributor flag when rendering approval | `staff_knowledge_forms_test.exs:45` | The contributor has no approve control |
| Drop the locked action's self-approval comparison | `staff_knowledge_forms_test.exs:45` | A forged independent attestation leaves the revision in review |
| Accept any uploaded file type | `staff_knowledge_portable_test.exs:150` | A text upload fails with the uniform file error |
| Bypass collection scope during export | `staff_knowledge_portable_test.exs:44` | Another collection gets the generic denial |
| Omit export CSRF protection | `staff_knowledge_portable_test.exs:60` | A bad token returns 403 |
| Remove the export selection cap | `staff_knowledge_portable_test.exs:19` | Eleven selections fail at the controller with 400 |
| Pass draft form crash reports to Logger | `staff_knowledge_crash_log_test.exs:176` | The debug capture excludes draft text |
| Leave the staff marker in place before a public call | `staff_knowledge_crash_log_test.exs:85` | The public 404 logs its conversion |

### Hallmark and accessibility

The C2 preflight retained C1's Almanac palette, system typography, staff
top bar, scoped tables and indexing beside the reviewed FAQ. The new
screens use labelled field groups and inline confirmations on that same
sheet. Runtime captures use synthetic FAQs and role fixtures.

Node 26.2.0, Puppeteer Core 24.43.1 and Chrome 158.0.8127.88 used the real
loopback Bandit TLS listener. The final capture ran through the disposable
helper and exited 0 with one test passed.

```sh
VGAS_C2_EVIDENCE="$(cat /tmp/vgas-c2-dir)" mise exec -- mix test test/vgas_c2_capture_temp.exs --seed 0
```

Chromium checked HTTP 200, the expected heading and form for each screen,
and the absence of the denial message. It exercised keyboard review,
approval, publication, retry and import confirmation, including visible
focus. The native export form sent its current CSRF field and selected
ID to the real POST route. The capture verified the date error's linked
summary and field association. Each captured state was checked at 320 px
and 1280 px with reduced motion. The static new-article form had disabled
controls. Contrast calculated from the CSS tokens is 17.28:1 for body text,
8.02:1 for the primary button, 6.12:1 for disabled button text and at least
5.06:1 for the focus ring against the adjacent sheet and paper.

The 24 captures cover collection creation, administration and editorial
links, article actions, new article, new revision and edit forms with date
errors, independent and contributor review, approved and publishing
states, failed publication and retry, export selection, and import entry,
preview, result and upload rejection. The capture removed scripts, CSRF and
hidden fields, signed LiveView tokens and draft answer text before saving.
It copied the real staff stylesheet into each capture.

Both commands ran for each directory matching `capture-*`.

```sh
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope page --render
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope app --render
```

The final 48 renders had zero FAILs and WARNs. Thirty-eight exited 0.
Ten exited 1 for 14 instances of REFLEX 49b. The early 39a finding was fixed
with separate disabled fill, ink and cursor. The form caret now uses the
accent token. The F23 answer from C1 still applies to the private routes.

- The collection and export captures wrap the synthetic article slug at
  320 px. A slug is the stable staff-facing article label. The whole label
  stays visible and actionable when the column is narrow.
- The new article, new revision and edit error captures wrap one or two
  linked instructions at 320 px. The instructions give the required date
  format and distinguish the primary language title. Reflow preserves the
  guidance and the link to the affected field at narrow widths.

The private evidence directory is `/tmp/vgas-c2.3j4Mic`. It contains
`browser-exact.log`, `chromium-results.log`, `hallmark.log`, the capture script and fixture, the
per-screen `page.log` and `app.log`, and the screenshots under
`capture-*/.hallmark/shots/`. The browser fixture file was removed from the
worktree after capture. The final page review inspected the import preview
on mobile and the draft errors on desktop.

### Completion assessment

IMPLEMENTATION, author self-assessment. Criteria 1–8 are implemented and
locally verified by the actions, targeted regressions, safe crash probes,
render checks and runbook above. The documented REFLEX findings were
waived within the app review.

Implementation score **9/10**. Requirements 4/4, observed verification 2/3,
correctness and risk 2/2, and handoff 1/1. Hosted CI and independent
review of the pushed candidate remain for the orchestrator. Confidence
**91%** based on the three staff seeds, the two full seeds, fresh and
predecessor databases, the mutation results and the real TLS browser flow.
The pinned framework logging and upload behavior will need rechecking on
dependency upgrades.

Verification status **VERIFIED** for the local C2 scope.
Merge status `NOT_VERIFIED_FOR_MERGE`. The release owner still owns live
Entra, trusted ingress, production membership and link policy, sign-out
revocation and staff enablement under VGAS-9. VGAS-11 owns staging content.

### Changed files

```text
docs/plans/VGAS-003C1_VERIFICATION.md
docs/runbooks/staff-knowledge.md
lib/voelgoed_ai/knowledge/editorial.ex
lib/voelgoed_ai_web/endpoint.ex
lib/voelgoed_ai_web/knowledge_export_controller.ex
lib/voelgoed_ai_web/knowledge_live/article.ex
lib/voelgoed_ai_web/knowledge_live/auth.ex
lib/voelgoed_ai_web/knowledge_live/crash_log.ex
lib/voelgoed_ai_web/knowledge_live/draft.ex
lib/voelgoed_ai_web/knowledge_live/forms.ex
lib/voelgoed_ai_web/knowledge_live/import.ex
lib/voelgoed_ai_web/knowledge_live/index.ex
lib/voelgoed_ai_web/knowledge_live/revision.ex
lib/voelgoed_ai_web/router.ex
priv/static/staff/knowledge.css
priv/static/staff/knowledge.js
test/support/staff_knowledge_fixture.ex
test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs
test/voelgoed_ai_web/staff_knowledge_forms_test.exs
test/voelgoed_ai_web/staff_knowledge_live_test.exs
test/voelgoed_ai_web/staff_knowledge_portable_test.exs
docs/plans/VGAS-003C2_VERIFICATION.md
```

## Review 1 corrections

PR #15, Plane VGAS-14. Review head
`ac3c8011d322e58ec4030d991ffd5924d0d68775`. The correction code, tests
and runbook are in `3afe97c7a276ec4be84f68090548fc6eda971d48`.

- **MEDIUM-1.** Publish, retry and reindex hints now require the same
  `Embedding.publication_deadline/1` result as the actions. That check
  reads the clock and gate and validates content without enqueuing or
  calling a provider. The reviewer sees the effective date, an expiry
  notice or a publishing-unavailable notice in place of the action.
  Rollback uses the existing current-index guard. It reuses a retained
  generation and its request does not require an open embedding gate.
- **LOW-2.** The regressions submit a decision with a pre-refresh token,
  export a duplicate article ID and apply an import with a pre-preview
  token. They verify the original draft state, HTTP 400 and an empty
  collection, respectively.
- **LOW-3.** Runbook step 4 records the inclusive start, exclusive expiry
  and embedding-gate conditions, and describes the notice staff see.
- **NIT-4.** Progress for a replacement upload clears the old server-held
  bytes and preview. Apply also checks that there is no upload entry. A
  regression verifies the old apply control disappears during progress.

### Commands and results

The disposable helper supplied `MIX_ENV=test` and PostgreSQL 18.7 with
pgvector 0.8.7 on port 55434. Every steps file started with locked
dependency resolution. The suites used TLS port 4205, and the temporary
browser capture used 4204. No shared DevCore database or paid provider
was used.

```sh
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_steps" 55434
```

Each of these steps exited 0.

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

Fresh migration applied 12 migrations. Each staff run passed 84 tests.
Each full run passed 493, with five skipped and one excluded. The
exclusion is the seeded VGAS-001 upgrade test from the earlier C2
record. Both full runs exercised the expected synthetic reservation
commit failure.

The bootstrap compile with
`ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix compile --warnings-as-errors`
exited 0. Before the code change,
`ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_forms_test.exs test/voelgoed_ai_web/staff_knowledge_portable_test.exs --seed 0`
exited 2 with 16 passed and five failed. The failures were the four
publication and reindex control checks and the upload replacement check.
After mutation restoration, the same two test files ran at seed 0
without the scheduler override and exited 0 with 21 passed.

### Mutation checks

Each mutation compiled against the committed correction and ran
`mise exec -- mix test test/voelgoed_ai_web/<target> --seed 0`.
Each exited 2 with one assertion failure. After each run,
`git checkout -- lib test config` and `git diff --exit-code` exited 0.
The mutant runner exited 0 with seven killed.

| Mutation | Target | Failed assertion |
| --- | --- | --- |
| Publish hint skips the deadline | `staff_knowledge_forms_test.exs:174` | A future revision exposes Request publication |
| Retry hint skips the deadline | `staff_knowledge_forms_test.exs:187` | An expired failed revision exposes Retry publication |
| Reindex hint skips the deadline | `staff_knowledge_forms_test.exs:219` | A closed embedding gate leaves Request reindex visible |
| M2, skip the decision token check | `staff_knowledge_forms_test.exs:75` | The stale submission moves the draft into review |
| M3, skip the export duplicate check | `staff_knowledge_portable_test.exs:19` | Duplicate IDs return 401 instead of 400 |
| M7, skip the apply token check | `staff_knowledge_portable_test.exs:134` | The pre-preview token imports an article |
| Retain the preview on replacement progress | `staff_knowledge_portable_test.exs:152` | Apply stays visible during the replacement upload |

The reindex mutant drops the added deadline check. The existing
current-index guard already checks date eligibility, so closing the
gate isolates the missing condition.

### Hallmark and accessibility

The browser capture read the authenticated revision routes with scripts
disabled and with LiveView connected. It verified HTTP 200, the synthetic
English FAQ, each notice and the absence of its publish or retry control.
The keyboard refresh retained visible focus and restored its normal
label. The capture checked 320 px and 1280 px with reduced motion and
removed scripts, CSRF and LiveView tokens, hidden inputs and answer text
before saving HTML with the copied staff CSS.

```sh
VGAS_C2_EVIDENCE="$vgas_evidence" mise exec -- mix test test/vgas_c2_review1_capture_temp.exs --seed 0
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope page --render
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope app --render
```

The first capture exited 2 with one failed test because its title selector
read the Afrikaans variant. The locale-specific selector passed, and
the final capture also waited for refresh to finish. The final capture
exited 0 with one test passed and three sanitized states. The helper
removed the temporary fixture after each invocation.

Each render command ran against `capture-not-yet-effective`,
`capture-expired` and `capture-gate-closed`. All six exited 0 with
zero FAILs, REFLEX findings or WARNs. Each reported the existing F23
answer for the private staff routes and wrote five screenshots.
The desktop and narrow captures show the notices above the remaining
revoke form.

The private evidence directory is `/tmp/vgas-c2-review1.xoCbB6`. It
contains the steps and logs for bootstrap, the pre-fix run, verification,
the capture and mutations, the restored run and the final capture.
`hallmark-final.log`, the per-state logs and the screenshots under
`capture-*/.hallmark/shots/` record the rendered results. The pre-fix helper
and the first combined verification/capture helper exited 1 due to the
test failures above. The bootstrap, capture-and-mutants, restored-test
and final-capture helpers exited 0. Every helper cleaned up its container
and volume with exit 0.

### Repository checks

```sh
git diff --check
git diff --check 58ed481
git diff --exit-code 58ed481 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots
git diff --exit-code 3afe97c -- lib test config mix.exs mix.lock priv
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='58ed481..HEAD' --no-banner .
ss -ltn '( sport = :55434 or sport = :4204 or sport = :4205 )'
git status -sb
```

These commands exited 0. Gitleaks found no leaks. The listener check
listed no listeners on 4204, 4205 or 55434. The worktree was clean at
handoff. `rg -n 'authorize\?: false' lib` and
`rg -n '\bTask\b|\b(start_async|assign_async)\b' lib/voelgoed_ai_web/knowledge_live`
each exited 1 with no matches.

### Completion assessment

BUG_FIX, author self-assessment for VGAS-003 C2 review 1. Seven of
seven local criteria passed: publication and retry controls and notices,
the reindex guard and rollback boundary, the three guard regressions,
the runbook, upload preview invalidation, the verification matrix and
mutation checks, and rendered Hallmark verification.

Implementation Score **9/10** (requirements 4/4, verification 2/3,
correctness and risk 2/2, handoff 1/1). Confidence **95%** based on
the repeated suites, targeted mutations and rendered route states.
Verification Status **VERIFIED** for the local review corrections.
Hosted exact-head CI and independent re-review remain for the
orchestrator. Merge status is `NOT_VERIFIED_FOR_MERGE`.
