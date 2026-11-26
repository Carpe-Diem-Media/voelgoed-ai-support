# VGAS-003 C1 verification

Plane VGAS-14. Base `e1040b8eaa9e5074bfed3e07d16ce93eab68dbbe`. On `feat/vgas-003c1-staff-knowledge`, `7564bf3` records the accepted plan, `a469d59640310380bfef762bed8bf9f57180344f` contains the runtime implementation, and `b0787d462fbb20e51493df2342e5921ed402f784` adds the tests for the clarified telemetry criterion. The surrounding verification commits contain evidence only.

## Acceptance criteria

- **Pass.** Default-off staff transport and HTTPS routing. Loopback Bandit accepted a current encrypted session on the configured TLS origin with valid cookie-backed CSRF. It rejected disabled auth, HTTP, forged forwarding headers, missing and tampered cookies, an expired session, a bad origin, and missing or wrong CSRF. The health route stayed available with staff auth disabled.
- **Pass.** Current access on mount, navigation, refresh and expiry. The LiveView tests rejected a missing transport session, role revocation between mounts, role loss and scope loss during an open view, forged event targets, and mismatched parents. The idle view redirected and its process exited at the deadline. Ordinary sign-out expired the browser cookie and reconnect without it failed.
- **Pass.** Bounded authorized read contracts. Ash filtered collections before paging, ordered by ascending UUID, returned at most 50 rows per action, and followed the cursor without duplicates. ADMIN received collection metadata. Article and revision reads required scope and an editorial role. Revision reads returned the contributor boolean, no contributor IDs, and distinguished absent, queued, failed and active locale states.
- **Pass.** Read-only pages and asset controls. Authenticated HTML rendered the index, collection, article and revision. It included no-store, no-referrer, nosniff and staff CSP. Both endpoint and Chromium tests verified the exact browser assets and MIME types. Denials shared one response, and scoped empty collections rendered their empty state.
- **Pass.** Authenticated visual and accessibility checks. See the Hallmark and Chromium results below.
- **Pass.** Compilation, regression suites, migration rehearsals and C1 mutation checks. See the command record below.
- **Pass.** Staff telemetry and logs under the clarified C1 criterion. The pinned framework callbacks are the only allowed subscribers. The debug captures excluded the tested credentials, editorial text and staff identifiers, including during three LiveView crashes. The transport, upload logging and telemetry mutations failed on their intended assertions.

## Telemetry ruling

> The plan says "keep ... connection credentials out of logs, flashes and telemetry". Its authority is the spec rule "redact telemetry ... no raw request logging". That rule governs data that is emitted, logged or exported. It does not govern the in-memory metadata that framework events carry. The clarified C1 criterion: no handler, logger or exporter in this application receives, logs or exports the sensitive metadata of those pinned Phoenix and LiveView events (raw transport params, connect_info, session, socket assigns). Future instrumentation (VGAS-8 observability) must attach only through an allowlisted filtering handler; record that as a follow-up rule, do not build it now. This ruling is a clarification. It is not a framework change and not a waiver.

The tripwire checks subscriptions after startup. Each subscription must match an exact event, handler ID and callback from the pinned Phoenix or LiveView logger. It covers these prefixes, including start, stop and exception suffixes where applicable.

- `[:phoenix, :socket_connected]`
- `[:phoenix, :channel_joined]`
- `[:phoenix, :channel_handled_in]`
- `[:phoenix, :router_dispatch]`
- `[:phoenix, :endpoint]`
- `[:phoenix, :error_rendered]`
- `[:phoenix, :live_view]`
- `[:phoenix, :live_component]`

Phoenix 1.8.17 emits the socket and channel events in `phoenix/socket.ex` and `phoenix/channel/server.ex`. `phoenix/router.ex`, Plug.Telemetry in the endpoint and `phoenix/endpoint/render_errors.ex` emit the HTTP events. LiveView 1.2.15 emits the view and component events in `utils.ex`, `channel.ex` and `diff.ex`.

The debug capture covers Bandit TLS upgrades, a missing CSRF rejection and an unmatched staff request with the issued cookie and CSRF header. It also exercises a rejected upload-channel join with an arbitrary client parameter. The staff socket sets Phoenix's channel join and event log options to `false`. The endpoint and staff routes suppress request and dispatch logging. The pinned error-rendered callback reports the exception class on the covered 404 and does not inspect the conn. LiveViewTest covers mounts, navigation, refresh, access denial and idle expiry. The capture checks issued credentials, signed page tokens, editorial text and synthetic staff identifiers. Assertion failures report the field label only.

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

### Telemetry verification rerun

After restoring the two telemetry mutations, the disposable PostgreSQL helper ran these steps against `b0787d4`. Every step and the helper exited 0.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 1" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force
ELIXIR_ERL_OPTIONS="+S 2" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_auth_test.exs test/voelgoed_ai_web/staff_knowledge_live_test.exs --seed 0
mise exec -- mix test --seed 0
```

The focused suites passed all 16 tests. The full seed passed 456 with 5 skipped and 1 excluded. It again logged the expected synthetic reservation-commit failure. Both upgrade lanes above were rerun. All steps exited 0. The foundation upgrade passed 6 with 1 excluded, and the seeded VGAS-001 upgrade passed 7. The earlier Hallmark and browser evidence applies to the same runtime and assets as this test-only revision.

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

Two further mutations ran on the committed telemetry tests using the same disposable helper. Each command ran one selected test and exited 2 with one assertion failure.

- An extra `:telemetry.attach/4` subscription for `[:phoenix, :socket_connected]` in the auth test setup failed `mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_auth_test.exs:16 --seed 0` with `Unreviewed telemetry handler for [:phoenix, :socket_connected]`. Three other tests were excluded.
- Changing the staff socket to `transport_log: :info` failed `mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_live_test.exs:122 --seed 0` with `Captured logs included staff HTTP or WebSocket transport log`. Eleven other tests were excluded.

`git checkout -- lib test config` restored each mutation. `git diff --exit-code -- lib test config` exited 0 after restoration.

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

Ordinary sign-out removes the browser's cookie. An already connected tab or a captured cookie can remain valid up to the original ten-minute deadline unless staff generation, roles, registration or collection access are revoked sooner. The owner must decide under VGAS-9 whether sign-out needs immediate cross-tab or captured-cookie revocation and approve a production membership mapping before enabling staff access. Disable the existing staff gate to inhibit new requests and upgrades. Revert the C1 source change to remove the workspace. Existing editorial records need no migration or restoration.

## Follow-ups

- VGAS-8 observability. Any new instrumentation for the protected Phoenix and LiveView events must attach through an allowlisted filtering handler. Review the handler's event list and callback and test its output before allowlisting it. Pass only approved fields downstream. Exclude raw transport params, `connect_info`, sessions and socket assigns from exported data.

## Review 1 corrections

### Crash reporting

The application installs the primary filter before it starts the endpoint and removes it after the supervision tree stops. OTP 29.1.2 `kernel/src/logger_server.erl` prepends filters registered with `:logger.add_primary_filter/2`. `logger_backend.erl` passes a replacement event to subsequent filters and handlers. Elixir 1.20.5 `Logger.App` registers its translator as a primary filter. Its GenServer translator prints the last message at every reportable level and prints the state at debug. Redacting before translation also keeps exception details out of structured handler metadata.

OTP `stdlib/src/gen_server.erl` and `proc_lib.erl` expose process labels on their termination and crash reports. LiveView 1.2.15 `channel.ex` labels the channel with the verified view module before mount callbacks and returns the entire state from `format_status(:terminate, ...)`. It prunes connect info and connect params after mount. The views keep the page projection for rendering and the decoded session for event authorization.

Phoenix's `socket/pool_supervisor.ex` gives the staff socket a dedicated supervisor tree. The filter uses that ancestry for reports created before the LiveView label is set, upload channel reports and DynamicSupervisor child failures. It also replaces the formatted join error from `Phoenix.Channel.Server.join/4` when the transport has the staff socket label assigned by `Phoenix.Socket.__init__/1`. The replacement keeps a fixed notice, the view module when available, and only OTP time, process and group leader metadata.

The crash tests run the actual revision channel in the staff socket pool. At debug, with all logger metadata included, an unexpected call, a raise during `handle_params` and a raise during an event each produce a redacted notice. The tests check the article answers, event payload, cookie, CSRF, signed tokens, staff ID, session binding and last-message label.

### Role and origin checks

A freshly authenticated support-only operator is denied by the static GET, the real TLS upgrade and the connected mount. The previous refresh test now names the session-generation invalidation it exercises.

Two real TLS requests vary the origin layers independently. A wrong effective Host port with no Origin header must be denied before the `socket_connected` event. Without the early endpoint guard, the socket still rejects that URI, but Phoenix has already parsed and processed the cookie and emits the event. A trusted Host with a wrong-port Origin must also be denied. Phoenix's `:conn` check compares the browser Origin's scheme, host and port to the conn and rejects that mismatch before cookie processing.

C2 derives the approve control from both `approve` and `self_approval_required`. The existing generic denial for an uppercase revision UUID remains the C1 behavior.

### Review checks

The implementation under test was `119e428f9269f78421393546e93a2199e0be52eb`. All database commands ran in TEST via `bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$steps" 55434` on PostgreSQL 18.7 with vector 0.8.7. The helper reported these step results.

- `mise exec -- mix format --check-formatted`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix ash.codegen --check` and `mise exec -- mix ecto.migrate --strict-version-order` each exited 0.
- `ELIXIR_ERL_OPTIONS="+S 1" MIX_ENV=test mise exec -- mix compile --warnings-as-errors --force` and the same command at `+S 2` each exited 0.
- `mise exec -- mix test test/voelgoed_ai_web/staff_knowledge{_auth,_live,_crash_log}_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 0` exited 0 after restoration, with 53 passed. An earlier invocation exited 2 with 52/53 passed. The existing indexing-status test returned a failed locale for its expected active index. The failure did not recur in the fresh focused rerun or either final full-suite run. Its cause is unconfirmed.
- `mise exec -- mix test --seed 0` and `mise exec -- mix test --seed 8125` each exited 0 with 462 passed, 5 skipped and 1 excluded. Both runs logged the expected synthetic reserve-commit failure from its rollback fixture.
- `git diff --exit-code e1040b8 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots`, `git diff --check`, `mise exec -- mix hex.audit` and `python3 .github/scripts/plan_tests.py` each exited 0. `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e1040b8..HEAD' --no-banner .` exited 0 and reported no leaks.

The initial focused run exited 2 with 21/22 passed, and its full seed 0 exited 2 with 461/462 passed, 5 skipped and 1 excluded. The Plug.Test 404 probe reused a response marker in its test process mailbox. The probe now uses the real TLS listener. The command runner terminated that initial combined lane with exit 143 during its second seed. Its disposable container and volume were removed before restarting in separate lanes. The final runs cleaned up their containers and volumes, and `ss -ltn ' ( sport = :4205 or sport = :55434 )'` showed both ports free.

### Review mutations

The implementation was committed before mutation. Each target was run as `mise exec -- mix test <target> --seed 0`. All 13 mutations exited 2 on the intended assertions. Each mutation was restored with `git checkout -- lib test config`. The subsequent `git diff --exit-code -- lib test config` exited 0 before the focused rerun.

- Crash filter disabled. `test/voelgoed_ai_web/staff_knowledge_crash_log_test.exs` failed all 3 tests. The logs included an event payload or the last message.
- M11, any staff role can pass. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:87` failed its TLS assertion with HTTP 101.
- M8, effective port ignored. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:122` failed its wrong-Host-port assertion with HTTP 101.
- M12, early endpoint check removed. The same test at line 122 received the socket connection event on the rejected request.
- M13, socket Origin check removed. `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:146` failed its wrong-Origin-port assertion with HTTP 101.
- Six extra telemetry subscriptions were tested one at a time in `test/voelgoed_ai_web/staff_knowledge_auth_test.exs:18`. The allowlist rejected a handler on each of `socket_connected`, `endpoint/start`, `router_dispatch/exception`, `error_rendered`, `channel_joined` and `channel_handled_in`. Each run had one failure and six exclusions.
- The original transport log mutation and an upload join log mutation each failed the privacy capture at `test/voelgoed_ai_web/staff_knowledge_live_test.exs:130`. Each run had one failure and 11 exclusions.

## Review 1 completion assessment

BUG_FIX. Author self-assessment for VGAS-003 C1 Review 1, tracked in Plane VGAS-14. Four of four corrections passed. The debug captures verified crash redaction, the HTTP, TLS and connected mount tests verified current wrong-role denial, the expanded telemetry tripwire and flow capture verified the logging criterion, and the port and origin tests verified both transport guards. Zero corrections failed, remained unverified or were left incomplete. The seven C1 criteria remain the scope of the local handoff. The earlier visual and migration-upgrade evidence applies to the same staff page markup, assets and schema.

Implementation score is **9/10**. Requirements 4/4, observed verification 2/3, correctness and risk 2/2, and handoff 1/1. Hosted exact-head CI accounts for the verification deduction. Confidence is **90%**, based on three channel crash tests, real TLS requests, the targeted mutations, and both full local seeds. The transient indexing-status failure and reliance on pinned report shapes limit confidence.

Verification status is **VERIFIED** for the local C1 Review 1 corrections. Merge status is `NOT_VERIFIED_FOR_MERGE`. The orchestrator owns hosted CI and independent review on the pushed head. The VGAS-9 decisions still govern staff use.

## Review 2 corrections

### HTTP and channel logging

The primary logger filter replaces Bandit crash reports whose original `Plug.Conn.path_info` begins with `"staff"`. That prefix covers staff pages, the socket upgrade and the assets. Review 3 showed that it did not cover percent-encoded paths, which Review 3 corrections below close. The replacement carries a fixed notice and the OTP time, process and group leader metadata.

- Bandit 1.15.0 passes the original conn and plug to `handle_error/7` after conn construction. It unwraps `Plug.Conn.WrapperError` and logs the formatted exception with `domain: [:bandit]` and `crash_reason`. Elixir 1.20.5 prepends `:elixir` to that domain before the primary filters see it. See `deps/bandit/lib/bandit/{pipeline,logger}.ex` and Elixir's `Logger.add_elixir_domain/1`. Bandit is the configured adapter. The lockfile has no Plug.Cowboy package.
- Phoenix 1.8.17 wraps the endpoint at compile time and emits `[:phoenix, :error_rendered]` before re-raising. Its logger prints the exception module for a struct exception and can inspect a thrown or exited reason. The endpoint marks the staff request process so the primary filter can drop that Phoenix log, which carries no conn metadata. The successful endpoint call clears the marker. On failure the marker remains set while Phoenix emits its error log. A subsequent non-staff call in the same process clears it before public request logging. Bandit supplies the fixed crash notice. See `deps/phoenix/lib/phoenix/{endpoint.ex,endpoint/render_errors.ex,logger.ex}`. The configured JSON error response uses the status template.
- Phoenix overwrites route `metadata.log` with the route's `:log` option or its enclosing scope's setting. The staff knowledge scope now uses `log: false`. See `deps/phoenix/lib/phoenix/router/scope.ex:52` and `:173`.
- OTP 29.1.2 removes any primary filter that raises. The filter catches unexpected failures and redacts them when it can identify the staff request or process without relying on the malformed report. Other events proceed through the normal logger filters. The regression sends a malformed report through OTP and checks the filter is still registered. See OTP `kernel/src/logger_backend.erl:122`.

The TLS tests cover a dead render raising after actor assignment, a dead render throwing a synthetic reason, a non-staff HTTP crash, a malformed join before the channel is labelled and a connected mount crash after actor assignment. The debug captures include logger metadata and check synthetic exception data, staff IDs, the session binding, cookies and signed LiveView tokens. The staff flow capture rejects router dispatch output. The indexing test checks both retry embeddings are ready before finalization.

### Review checks

Code and tests were verified at `04aba359789d37624dad5d232a77f2ad54899c80`. The starting PR head was `7a4ee5df10f043b3a15fca59bb1947436717cd58` and the base was `e1040b8eaa9e5074bfed3e07d16ce93eab68dbbe`. The disposable helper ran with `MIX_ENV=test` on PostgreSQL 18.7 and vector 0.8.7 at port 55434. It used `bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$PWD" "$steps" 55434`. The helper and each of these steps exited 0.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --warnings-as-errors --force
ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --warnings-as-errors --force
mise exec -- mix ash.codegen --check
mise exec -- mix ecto.migrate --strict-version-order
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_{auth,live,crash_log,crash_filter}_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 0
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_{auth,live,crash_log,crash_filter}_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 8125
mise exec -- mix test test/voelgoed_ai_web/staff_knowledge_{auth,live,crash_log,crash_filter}_test.exs test/voelgoed_ai_web/staff_auth_test.exs --seed 43117
mise exec -- mix test --seed 0
mise exec -- mix test --seed 8125
```

Each focused run passed 58 tests. Each full run passed 467 tests with 5 skipped and 1 excluded. Both full runs reached the expected synthetic reserve-commit failure in its rollback fixture. The earlier Hallmark and upgrade evidence applies to the same page templates, assets and schema.

```sh
mise exec -- mix deps.get --check-locked
mise exec -- mix hex.audit
python3 .github/scripts/plan_tests.py
git diff --exit-code e1040b8 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots
git diff --check
git diff --check e1040b8
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts='e1040b8..HEAD' --no-banner .
```

All commands exited 0. Hex reported zero retired packages or advisories. Gitleaks found zero leaks.

### Review mutations

Each mutation was applied to the committed code and restored with `git checkout -- lib test config` after its test. For each target below the command was `mise exec -- mix test test/voelgoed_ai_web/<target> --seed 0`. All 11 mutations compiled and were killed by test failures.

| Mutation | Target | Exit | Passed / run | Excluded |
| --- | --- | ---: | ---: | ---: |
| MA, filter installation skipped | `staff_knowledge_crash_log_test.exs` | 2 | 1/7 | 0 |
| MB, ancestry fallback disabled | `staff_knowledge_crash_log_test.exs:83` | 2 | 0/1 | 6 |
| MC, transport join redaction removed | `staff_knowledge_crash_log_test.exs:87` | 2 | 0/1 | 6 |
| Bandit HTTP redaction removed | `staff_knowledge_crash_log_test.exs:22` | 2 | 0/1 | 6 |
| Phoenix error logging suppression removed | `staff_knowledge_crash_log_test.exs:22` | 2 | 0/1 | 6 |
| F3, ineffective route metadata restored | `staff_knowledge_live_test.exs:130` | 2 | 0/1 | 11 |
| F5, filter error boundary removed | `staff_knowledge_crash_filter_test.exs` | 2 | 0/1 | 0 |
| M11, any staff role admitted | `staff_knowledge_auth_test.exs:87` | 2 | 0/1 | 6 |
| M8, effective port ignored | `staff_knowledge_auth_test.exs:122` | 2 | 0/1 | 6 |
| M12, early endpoint guard removed | `staff_knowledge_auth_test.exs:122` | 2 | 0/1 | 6 |
| M13, socket Origin check removed | `staff_knowledge_auth_test.exs:146` | 2 | 0/1 | 6 |

The mutation lane's migration and final `git diff --exit-code -- lib test config` each exited 0. The helper itself returned 1 because its summary grep found no output for the final, clean diff. After restoration, the migration and focused seed 0 ran again on a fresh disposable database. Both steps and the helper exited 0, with 58 tests passed. The lanes removed their disposable containers and volumes. Both ports were free before and after verification.

### Follow-ups

- F4, C2. A task started under a staff LiveView may emit a `{Task.Supervisor, :terminating}` report with sensitive data. C1 starts no LiveView tasks. Before using `start_async` or `assign_async` in the staff views, C2 must extend redaction to task termination reports and verify it, or avoid async work in those views.
- N3, VGAS-8. Production compile with `--warnings-as-errors` has inherited warnings outside C1, as recorded by Review 2. The verification here uses the TEST compile.

### Completion assessment

BUG_FIX. Author self-assessment for VGAS-003 C1 Review 2, tracked in Plane VGAS-14. Seven of seven review items passed within their assigned scope. F1 passed the dead-render, thrown-reason and public control TLS cases. F2 passed both TLS join cases and the MA, MB and MC mutation checks. F3 passed the router privacy capture and its mutation. F5 passed the OTP registration check and its mutation. F6 passed the embedding readiness assertion across the focused and full runs. F4 and N3 are recorded as follow-ups. Zero items failed, remain unverified or were left incomplete in this review scope.

Implementation score is **9/10**. Requirements 4/4, observed verification 2/3, correctness and risk 2/2, and handoff 1/1. Hosted exact-head CI accounts for the verification deduction. Confidence is **90%**, based on the debug captures, 11 killed mutations and two full local seeds. Redaction depends on the pinned framework report shapes. The cause of the earlier indexing-status flake remains unconfirmed.

Verification status is **VERIFIED** for the local Review 2 corrections. Merge status is `NOT_VERIFIED_FOR_MERGE`. The orchestrator owns hosted CI and independent review on the pushed head.

## Review 3 corrections

Review 3 at `8dbcbdb5eaa2a2f347abde3a5b75bcf7cabd2bcc` found one MEDIUM gap (R3-1). Phoenix 1.8.17's router URI-decodes each path segment before it matches a route (`deps/phoenix/lib/phoenix/router.ex:470`), but Bandit leaves `path_info` undecoded. Requests to `/%73taff/knowledge` and `/st%61ff/knowledge` therefore reached the staff LiveViews. The endpoint marker, `request_log_level/1` and the crash filter all match the raw `"staff"` segment, so none of them recognised these requests. A dead-render crash on such a path logged the exception, the staff ID and the payload. The socket and the assets were not affected, because socket dispatch and `Plug.Static` match the raw path.

The fix is in commit `08f18e2`. Before any plug or log runs, `Endpoint.call/2` returns an empty 404 for any request whose first segment contains `%` and decodes to `"staff"`. Elixir 1.20.5 leaves malformed escapes intact during URI decoding, so those segments cannot decode to `"staff"`. All three raw-path checks therefore see every request that can reach a staff route.

A new real-TLS test sends `/%73taff/knowledge`, `/st%61ff/knowledge` and `/%73%74%61%66%66/knowledge` with a valid staff cookie, and a scope fixture that crashes if it is reached. For each path it asserts a 404, that the request never reached the staff route, and that the debug capture contains none of the cookie, staff ID, binding, payload or path text.

The orchestrator ran these checks on `08f18e2`.

- The disposable helper on port 55434 ran `deps.get --check-locked`, `format --check-formatted`, `compile --warnings-as-errors`, and the staff suites (`staff_knowledge_{crash_log,auth,live}_test.exs` and `staff_auth_test.exs`) at seed 0. Every step exited 0, and the staff suites passed 58 tests.
- Mutant: replacing the guard with `if false` made the new test fail (exit 2, 7 of 8 passed in the crash-log file). After `git checkout -- lib test config`, the diff check exited 0.
- `mix test --seed 97` exited 0 with 468 passed, 5 skipped and 1 excluded. The expected synthetic reserve-commit failure was logged.
- Forced TEST compiles under `ELIXIR_ERL_OPTIONS="+S 1"` and `"+S 2"` each exited 0.
- `git diff --check e1040b8`, `git diff --exit-code e1040b8 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots`, and Gitleaks with redaction exited 0, and Gitleaks found no leaks. `rg 'authorize\?: false' lib` found no matches.

Not fixed in this PR:

- R3-2 (LOW). No test pins that the request marker is cleared. Mutants that never clear it survive. In production this is safe, because Bandit's default `clear_process_dict: true` resets the process dictionary between keep-alive requests, and Bandit closes the connection after a 500. This is a C2 follow-up: add an in-process staff-404-then-public-404 debug test.
- R3-3 (NIT). The socket `connect` origin check and the `handle_event` access recheck are both backed by outer checks, so removing either one leaves behaviour unchanged. They stay as defence in depth.

## Files changed

- Plans and evidence in `docs/plans/VGAS-003C_PLAN.md` and this record.
- Application and endpoint configuration in `config/config.exs` and `lib/voelgoed_ai/application.ex`. Review 1 adds the filter in `lib/voelgoed_ai_web/knowledge_live/crash_log.ex`.
- Read actions and projections in `lib/voelgoed_ai/knowledge/{article,article_revision,editorial,knowledge_collection}.ex`.
- Transport and routing in `lib/voelgoed_ai_web/{endpoint,router,staff_live_socket,staff_session}.ex`.
- Staff HTML and authorization in `lib/voelgoed_ai_web/knowledge_live/{article,auth,components,denial_controller,index,revision}.ex`.
- First-party assets in `priv/static/staff/{knowledge.css,knowledge.js}`.
- Test fixture and checks in `test/support/staff_knowledge_fixture.ex` and `test/voelgoed_ai_web/staff_knowledge_{auth,live,crash_log,crash_filter}_test.exs`.
