# Review synthetic knowledge gaps

VGAS-26 implements the local fixture in G019, G029 and Resource Contracts §4/T04 under A-010. Use the scope decision on the Plane issue for topic, evidence and staff authority. [VGAS-26](https://app.plane.so/symphony-development/projects/8e7e9131-668d-4d99-8bd7-b5847d5f8c8c/issues/a918f2c5-e7c5-481b-8e92-898215e7150d)

## Local operation

Use a disposable PG 18.7 database with pgvector 0.8.7 and the signed intake fixtures in `test/voelgoed_ai/support/knowledge_gap_test.exs`. Run that file with the isolated setup in [Application CI](../development/application-ci.md). The fixtures enable one synthetic binding, its assistant, one public collection and explicit staff IDs. The topic and the two supported languages are fixed in code. The capture issuer, review authority and `/staff/gaps` route are compiled only for TEST.

The queue shows cause, language, state and time. Editors, reviewers and support operators with the bound scope can start a review or defer it back to Open. Reviewers and support operators can dismiss an in-review occurrence with a reason from the list. To address one, a reviewer needs collection scope, the exact ID of the currently eligible published revision and an affirmative attestation. Addressing records the revision on the occurrence and leaves publication to the existing editorial workflow.

If the queue rejects a change, refresh and check the current version and scope before resubmitting. An addressed or dismissed occurrence stays terminal. A later qualified occurrence creates an independent row and links to a prior terminal occurrence only when the binding, assistant, collection, topic, language, applicability and cause match.

## What the occurrence records

The shadow worker checks the fixture phrase and live grant independently of the customer-facing reason. A healthy lookup proves absence, an approved alternate-language source proves insufficient coverage, and incompatible eligible exact values for the same fact prove conflict. Other search outcomes retain their established routing. In T04 the worker rechecks the current claim, ordinary retrieval coverage and the fixture finding before committing the shadow completion, occurrence and local handoff together. A newly eligible FAQ can suppress a stale gap without changing the local handoff. Each optional proof restores the caller's statement timeout on success or failure. A failed write rolls back the entire completion.

The occurrence stores local origin and publication references, a topic code, language, applicability, cause and review state. It contains no question text or hash, prompt, transcript, or external customer or conversation identifier. Staff transitions append the actor, decision and before and after states and versions inside the same transaction. The support operator's queue admission does not grant editorial admission.

The migration adds one table, one audit target reference and the associated constraints and snapshots. Rollback is available on an empty gap table. If there is history, retain it and use a forward migration. Production topic rules, staff scope and expiry remain under owner authority. VGAS-28 owns retention and replay policy.

## Local verification

The candidate is based on `0c7336cd8def8995530cd2e566cc8b269cb1b8a6` and tree `254d246240e9fdbf0e198eee2890c7f7083914e6`. Checks used Mise Elixir 1.20.5 and OTP 29.1.2. The database runner used the CI-pinned PostgreSQL image on disposable loopback ports 55436 and 55437. No shared database was used for migration or tests.

- `mise exec -- mix deps.get --check-locked` and `mise exec -- mix hex.audit` verified the locked packages.
- The fresh, foundation-only and VGAS-001 predecessor lanes ran `mix ecto.migrate --strict-version-order` and `mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs`. The predecessor lane used `.github/scripts/vgas001_upgrade_fixture.sql` and `VGAS_VERIFY_VGAS001_UPGRADE=true`.
- The populated lane installed the same synthetic VGAS-001 history, migrated to the exact VGAS-20 predecessor, then applied VGAS-26. It checked the occurrence trigger and verified the existing audit rows through `mix ecto.rollback --step 1` and reapply with an empty gap table. The VGAS-20 predecessor test now rewinds later migrations during its SQL-only proof.
- Hallmark app scope used the existing Almanac-derived staff stylesheet and form components. The occurrence queue is the main view. Authenticated HTTP and connected LiveView captures supplied the empty, populated and rejected-submission states. The render files omitted the fixture session, CSRF and LiveView tokens. The installed `sloplint.mjs <populated.html> <empty.html> <error.html> --genre editorial --scope app --render` returned zero FAIL and zero REFLEX. F23 is answered by the private route. The finish review checked the 1440px and 375px full views after correcting duplicate chrome in the capture harness.
- Chromium at 320px, 375px and 1440px verified ten keyboard stops with visible focus, the skip link, labeled controls, reflow and reduced motion. The queue text remained visible without JavaScript. ExUnit exercised the denied route, scoped operator mount and role withdrawal. No HTTP server was needed for the render.

- `mise exec -- mix format --check-formatted`, `MIX_ENV={dev,test,prod} mise exec -- mix compile --force --warnings-as-errors` run separately, and `MIX_ENV=test mise exec -- mix ash.codegen --check` exited 0.
- The targeted command `mise exec -- mix test --seed 0 test/voelgoed_ai/support/knowledge_gap_test.exs test/voelgoed_ai/accounts/direct_staff_authorization_test.exs test/voelgoed_ai_web/staff_knowledge_crash_filter_test.exs` passed 47 tests. It exercised separate database connections, write and audit rollback, terminal recurrence, stale review, publication eligibility, role and scope checks, direct action denial, and zero external writes. A separate disposable probe verified that migration rollback rejected stored gap history.
- The full command `mise exec -- mix test --seed 0 --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter` used `VGAS_F04_DISPOSABLE=1`, `VGAS_VERIFY_PGVECTOR=true`, and `VGAS_VERIFY_VGAS20_UPGRADE=true`. The CI report verifier confirmed 912 passes and two approved exclusions. The VGAS-001 predecessor assertion passed in its dedicated lane. The owner-approved one-call provider smoke remained excluded. The query accounting concurrency test now checks both exact ledger entries irrespective of the order PostgreSQL returns them. Its race barriers still verify the operation order.
- `docker build --platform linux/amd64 --progress=plain --tag vgas26-local:verified .` and `bash .github/scripts/verify_release.sh vgas26-local:verified` passed package, migration, health, denial, and asset checks. A release eval confirmed that the gap route modules and TEST fixture issuers are absent. The packaged gap CSS matched the source bytes.
- `gitleaks git --redact=100 --no-banner` passed on the candidate range using Gitleaks 8.30.1.

Hosted CI and independent review belong to the exact candidate after the orchestrator takes handoff.
