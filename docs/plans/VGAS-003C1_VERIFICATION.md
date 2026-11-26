# VGAS-003 C1 verification

Plane VGAS-14. Base `e1040b8eaa9e5074bfed3e07d16ce93eab68dbbe`. Implementation candidate `a469d59640310380bfef762bed8bf9f57180344f` on `feat/vgas-003c1-staff-knowledge`. The first commit, `7564bf3`, copies the accepted plan byte for byte, including the orchestrator addendum. This evidence is the only subsequent repository change.

## Acceptance criteria

- **Pass.** Default-off staff transport and HTTPS routing. Loopback Bandit accepted a current encrypted session on the configured TLS origin with valid cookie-backed CSRF. It rejected disabled auth, HTTP, forged forwarding headers, missing and tampered cookies, an expired session, a bad origin, and missing or wrong CSRF. The health route stayed available with staff auth disabled.
- **Pass.** Current access on mount, navigation, refresh and expiry. The LiveView tests rejected a missing transport session, role revocation between mounts, role loss and scope loss during an open view, forged event targets, and mismatched parents. The idle view redirected and its process exited at the deadline. Ordinary sign-out expired the browser cookie and reconnect without it failed.
- **Pass.** Bounded authorized read contracts. Ash filtered collections before paging, ordered by ascending UUID, returned at most 50 rows per action, and followed the cursor without duplicates. ADMIN received collection metadata. Article and revision reads required scope and an editorial role. Revision reads returned the contributor boolean, no contributor IDs, and distinguished absent, queued, failed and active locale states.
- **Pass.** Read-only pages and asset controls. Authenticated HTML rendered the index, collection, article and revision. It included no-store, no-referrer, nosniff and staff CSP. Both endpoint and Chromium tests verified the exact browser assets and MIME types. Denials shared one response, and scoped empty collections rendered their empty state.
- **Pass.** Authenticated visual and accessibility checks. See the Hallmark and Chromium results below.
- **Pass.** Compilation, regression suites, migration rehearsals and C1 mutation checks. See the command record below.
- **Blocked.** The accepted plan requires credentials and editorial content to stay out of telemetry. Pinned Phoenix emits the raw transport params and `connect_info` in `[:phoenix, :socket_connected]`. Pinned LiveView emits the mount session and sockets in its own telemetry spans. The socket includes staff page assigns. The repository installs no exporter for those events. The framework log options suppress logging but leave the event metadata intact. Before C1 can satisfy this criterion, the owner must approve an explicit boundary for in-process instrumentation and a tested export filter, or authorize a framework change that removes these fields. Relevant pinned sources are `deps/phoenix/lib/phoenix/socket.ex` near line 520 and `deps/phoenix_live_view/lib/phoenix_live_view/utils.ex` near lines 350 and 470.

## Commands

Database commands used the supplied helper against a new PostgreSQL 18.7 instance with vector 0.8.7 for each lane. The disposable TEST listener bound to `127.0.0.1:55434`. The Bandit test listener bound to `127.0.0.1:4205`. Runtime commands used Elixir 1.20.5 and the repository's OTP 29.1.2 pin through Mise.

```sh
vgas_evidence=/tmp/vgas-c1-evidence.P4rkBz
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_evidence/verification.steps" 55434
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_evidence/foundation-upgrade.steps" 55434
bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$vgas_evidence/staff-upgrade.steps" 55434
```

The test helper reports each step's exit code. `verification-exact.log`, `foundation-upgrade-exact.log` and `staff-upgrade-exact.log` contain the observed results. The upgrade lanes mirror Application CI. One installs the committed foundation at `aa93104fd476d208206288658e67bfe70e0780cd`. The other installs the committed VGAS-001 migrations at `92ef0e39a7808d4ffa692b37b48ba3ee27a05e30`, loads `.github/scripts/vgas001_upgrade_fixture.sql`, applies the candidate ordering and enables the upgrade assertion. Exact-head hosted CI requires a pull request or a push to main under the current workflow.

All commands in the fresh and upgrade lanes exited 0.

- `mise exec -- mix format --check-formatted`
- `mise exec -- mix compile --warnings-as-errors`
- `ELIXIR_ERL_OPTIONS="+S 1" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force`
- `ELIXIR_ERL_OPTIONS="+S 2" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force`
- `mise exec -- mix ash.codegen --check`
- `mise exec -- mix ecto.migrate --strict-version-order`
- `mise exec -- mix test --seed 0 test/voelgoed_ai/repo_foundation_test.exs` passed 6 and excluded the upgrade fixture on fresh and foundation-upgrade lanes. With `VGAS_VERIFY_VGAS001_UPGRADE=true`, it passed 7 on the seeded VGAS-001 upgrade.
- `mise exec -- mix test test/voelgoed_ai_web/staff_knowledge{_auth,_live}_test.exs --seed 0` passed 14.
- `mise exec -- mix test --seed 0` and `mise exec -- mix test --seed 8125` each passed 454 with 5 skipped and 1 excluded. The excluded test uses seeded VGAS-001 data. Both runs logged the expected synthetic reservation-commit failure from the rollback fixture and completed with zero test failures.
- `VGAS_F04_DISPOSABLE=1 mise exec -- mix test test/voelgoed_ai/knowledge_feasibility_test.exs --seed 0` ran the 5 default-skipped feasibility cases in a separate disposable lane. All 5 passed.


```sh
mise exec -- mix deps.get --check-locked
mise exec -- mix deps.unlock --check-unused
mise exec -- mix hex.audit
python3 .github/scripts/plan_tests.py
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e1040b8..HEAD' --no-banner .
git diff --check e1040b8
git diff --exit-code e1040b8 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots
```

All seven commands exited 0 when run. Gitleaks reported no leaks. Hex reported no retired packages or advisories. Lockfile SHA-256 is `97e956eb45a003ebae63bdbe513d6ecabd187e9fd5a40f68114c732896c71867`. Compose is outside the touched files.

## Mutation checks

The implementation commit was clean before mutation. Each mutation ran under the disposable helper from `mutants.steps`; the script restored the tracked source with `git checkout -- lib` after each run. The targeted command for every case was `mise exec -- mix test <file>:<line> --seed 0`. Each command exited 2 with one assertion failure, and none failed at compile time.

- Skipped connected mount authorization. `staff_knowledge_live_test.exs:85` failed the direct mount gate assertion for a revoked session.
- Disabled cookie CSRF. `staff_knowledge_auth_test.exs:14` failed the real handshake assertion for missing CSRF.
- Trusted cached staff access. `staff_knowledge_live_test.exs:190` failed the denial assertion after role revocation.
- Used the event's article ID as the target. `staff_knowledge_live_test.exs:65` failed the assertion that the forged ID leaves the authorized revision visible.
- Dropped the article/revision match. `staff_knowledge_live_test.exs:119` failed the mismatched-parent denial assertion.
- Used the creator alone for self-approval. `staff_knowledge_live_test.exs:146` failed the non-creator contributor assertion.
- Delayed session expiry. `staff_knowledge_live_test.exs:110` failed because the open view did not redirect at its deadline.

Seven killed, zero survived. `git diff --exit-code -- lib` exited 0 after restoration. Exact commands and results are in `mutants-exact.log`. Review/publish snapshot, import preview and imported-authority mutations belong to C2.

## Hallmark and accessibility

The preflight found no repository design file or staff styles to extend. Hallmark v2 dealt Grid, Almanac and Blueprint for the staff app. Almanac was pick 2 of 3, seed `42191e64`. The screens use its slate paper, pale ruled sheets and magenta action color with system fonts and first-party CSS. A short staff top bar and ordinary links lead to the collection and revision tables. The revision pairs localized indexing state with the corresponding FAQ text. Initial data loads synchronously. A refresh uses the button's busy label. Empty collection, unavailable article list and generic denial have separate text.

The final browser capture used Node 26.2.0, Puppeteer Core 24.43.1, Chrome 158.0.8127.88 and the loopback TLS fixture. The browser requested the real routes and tested static HTML, a connected LiveView, the first keyboard focus, the refresh button's visible focus and Enter activation, narrow reflow at 320 px, 1280 px layout, reduced motion, MIME and CSP. The capture checked HTTP 200 and route-specific headings and fixture markers. Capture code removed scripts, the CSRF meta tag and signed LiveView tokens before persisting HTML. The private evidence directory contains the capture script and browser log. The browser fixture ran through the disposable helper using:

```sh
VGAS_C1_EVIDENCE="$(cat /tmp/vgas-c1-evidence-path)" mise exec -- mix test test/vgas_c1_capture_temp.exs --seed 0
```

The final capture exited 0, 1 test. The temporary ExUnit file was removed from the worktree and retained in the evidence directory for replay. Warm loopback HTTP requests, 20 per route, measured p50/p95 of 4.0/5.2 ms for the collection list, 6.5/10.0 ms for the populated collection, 6.4/6.7 ms for its empty equivalent, 9.3/10.8 ms for the article and 8.8/12.9 ms for the revision. These fixtures exercised the control lock with no competing ingress traffic. They provide no load estimate for concurrent ingress.

The following commands ran for each target, `collections`, `collection`, `article`, `revision` and `empty`, each in `static` and `connected` states:

```sh
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope page --render
node /home/jcschoeman96/.agents/skills/hallmark/scripts/sloplint.mjs "$vgas_capture" --scope app --render
```

All 20 runs exited 0 with zero FAILs, REFLEX findings and WARNs. Earlier captures flagged 34 and 73 for horizontal clipping and the positioned skip link, and 49b for wrapped links at 320 px. The final skip link appears in place on focus, the app handles overflow, and the two name columns have enough room for the fixture links. No Reflex waivers. F23 is answered in the CSS because these private staff routes have no public previews. The evidence directory holds `hallmark-verified.log` and each target's five screenshots under `.hallmark/shots/`.

The in-thread app-screen Finish review checked the full desktop and mobile editorial views. The table headings, review state and current revision were legible at both widths. Revision dates wrap on narrow screens and remain readable. Contrast ratios calculated from the CSS palette are 17.28:1 for text on the sheet, 8.90:1 for muted text on the sheet, 8.02:1 for the primary button and at least 5.06:1 for the focus ring on adjacent surfaces. The verification capability here was the in-thread fallback. The orchestrator can commission a separate review of the exact candidate.

## Deployment and rollback

The staff gate stays off. VGAS-9 owns live Entra and any trusted TLS ingress. The endpoint checks the HTTPS scheme, host and port against the registered staff origin. It ignores client-supplied forwarded values. The tests used TLS directly. A deployed termination arrangement needs its own validation against those same checks.

Ordinary sign-out removes the browser's cookie. An already connected tab or a captured cookie can remain valid up to the original ten-minute deadline unless staff generation, roles, registration or collection access are revoked sooner. The owner must decide under VGAS-9 whether sign-out needs immediate cross-tab or captured-cookie revocation, approve a production membership mapping and resolve the telemetry criterion before enabling staff access. Disable the existing staff gate to inhibit new requests and upgrades. Revert the C1 source change to remove the workspace. Existing editorial records need no migration or restoration.

## Completion assessment

Implementation task. Author self-assessment for VGAS-003 C1 only. Six of seven criteria passed. The telemetry criterion is blocked. The candidate has no hosted exact-head CI or independent merge review.

Implementation score is **5/10**. Requirements 3/4, verification 2/3, correctness and risk 1/2, and handoff 1/1 give 7/10 before the required blocker cap. The telemetry contract accounts for the requirements and risk deductions. Hosted exact-head evidence accounts for the verification deduction. Confidence is **95%** in the local results and in the pinned framework behavior. Production TLS termination and instrumentation remain untested.

Verification status is **BLOCKED** for release acceptance. The owner has to resolve the instrumentation requirement, then the orchestrator can rerun the transport and telemetry checks and obtain CI and independent review on the resulting commit. Those are the conditions for a score of at least 8/10. Merge status is `NOT_VERIFIED_FOR_MERGE`.

## Files changed

- Plans and evidence in `docs/plans/VGAS-003C_PLAN.md` and this record.
- Application and endpoint configuration in `config/config.exs` and `lib/voelgoed_ai/application.ex`.
- Read actions and projections in `lib/voelgoed_ai/knowledge/{article,article_revision,editorial,knowledge_collection}.ex`.
- Transport and routing in `lib/voelgoed_ai_web/{endpoint,router,staff_live_socket,staff_session}.ex`.
- Staff HTML and authorization in `lib/voelgoed_ai_web/knowledge_live/{article,auth,components,denial_controller,index,revision}.ex`.
- First-party assets in `priv/static/staff/{knowledge.css,knowledge.js}`.
- Test fixture and checks in `test/support/staff_knowledge_fixture.ex` and `test/voelgoed_ai_web/{staff_knowledge_auth,staff_knowledge_live}_test.exs`.
