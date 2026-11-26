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
