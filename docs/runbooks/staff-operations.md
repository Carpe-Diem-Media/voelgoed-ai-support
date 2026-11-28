# Staff operations and local recovery

Plane VGAS-29 implements the local portion of G013, G026–G031 and G033–G038.
The accepted scope is in Plane comment
`ebbbcc2a-d327-4294-9ea8-9d78e1344049`. The predecessor is
`96c42c820194610bc5b63ac4ff709b170fb133f4` with tree
`eac28c3529f6dc0485655e30a381374af75b9121`. VGAS-18 supplies the overdue
routing and no-send cancellation rules. VGAS-20 owns financial settlement
and reset. VGAS-27 supplies the ownership, cooldown and local handoff
rules. VGAS-28 supplies the purge and replay rules.

## Use the staff page

- A current admin session can open `/staff/operations` on the configured
  Entra origin. The page shows automation state, local readiness,
  qualifying configuration and bounded activity. Spend is exact nano-USD.
  Settlement values apply to the current UTC day and month. Outstanding
  exposure includes all reserved and UNKNOWN holds. The cap labels identify
  the generation and embedding configurations that supply those values.
  Disable automation stays available when the separately authorized
  accounting read reports unavailable totals. Spend uses a single
  read-only snapshot with a 750 ms deadline. It holds neither the staff
  row nor the automation row while reading accounting tables.
- A current support operator can inspect the qualified queue, delivery
  uncertainty and local attention history. Open a session by the internal
  reference in the queue. An unavailable session can indicate that the
  reference is stale or outside the qualified inbox. Editorial roles have
  their own route and socket grants. The operations stylesheet requires a
  current operations grant. PostgreSQL limits each queue projection query
  to 750 ms. If a query times out, the page reports that it could not load.
  Staff with both grants retain the admin controls while the queue is
  unavailable. The disable action checks the current admin grant again.
  Use **Refresh** after database contention clears.
- To route locally, use **Route to staff locally**. This fences unsent work,
  advances the ownership epoch and records one audit and one terminal status
  intent in one transaction. Staff complete the handoff in Chatwoot. The
  cancelled intent remains terminal if a delivery job appears later.
- For UNKNOWN, use **Check Chatwoot for evidence**. The action reserves one
  existing read-back slot and records a staff audit in the same transaction.
  Only qualified operation evidence or the verified handoff goal can confirm
  delivery. Review the outstanding state after a failed read. Use explicit
  abandonment separately if authorized. It preserves uncertainty and
  fences an in-flight read. The page sends no messages, retries no delivery,
  resolves no conversation and changes no financial controls.
- An assisted draft appears only after an operator requests review. The
  application rechecks the qualified session and context, current
  ownership and configuration epochs, the original deadline, and all
  public evidence before revealing the draft. A shadow result, edited
  context, revoked evidence, held or purged text, or expired run makes the
  draft unavailable. The page clears a displayed draft on refresh,
  navigation or expiry. Staff review and send through Chatwoot.

Qualified inboxes and calls use TEST fixtures. The packaged release keeps
their admission disabled. There is no verified Chatwoot web URL in the
current binding contract. Open the existing staffed Chatwoot queue using
the organization's approved access path. Live inbox qualification,
link configuration, alert recipients and coverage belong to the external
acceptance work.

## Disable and recover

`GET /health` checks HTTP liveness. `GET /ready` returns generic ready or
unavailable JSON and prevents caching. It reads the control row and Oban
storage with short query timeouts, checks the local Oban supervisor and
checks that the published revision still qualifies for the selected TEST
mode, including its current configuration hash. Neither route
calls Chatwoot or a provider, enqueues work or reserves money.

Set `VGAS_EMERGENCY_DISABLE=true` at startup for emergency inhibition. The
runtime treats an invalid explicit value as asserted. An unset value or
`false` defers to persistent controls. The startup latch must commit before
the job supervisor and endpoint start when the override is asserted.
Clearing the environment value leaves the latch in place. A current admin
records **Disable automation** to clear the latch and advance the epoch.
Clear the environment assertion and restart under the approved procedure
before explicitly enabling fresh qualified work. Old epochs cannot
dispatch. Leave scope disabled whenever the current configuration or
ownership cannot be verified.

DB admission, reservation and dispatch checks run under the existing
locks. The Chatwoot write adapter checks the emergency setting and reads
the current persisted control immediately before calling the fake
transport. It requires an enabled, unlatched control in the qualified
mode and an exact match with the intent's immutable epoch. The read has
a 250 ms deadline and zero pool checkout retries. Denial or a read failure cancels the matching
proven-unissued claim. A worker loss after dispatch authorization still
requires conservative recovery. A disable can occur after this last read
or while an already issued request is in flight.

Circuit opening records a pending fact for its generation. Auth and
configuration failures require a newer revalidated binding configuration
and an explicit admin probe. The admin supplies an internal session
reference in the qualified inbox. A bounded observation runs outside the
transaction after audit and reservation commit. The final transaction
rechecks role and epochs and settles only that leased generation. A
transient circuit retains its existing timed recovery. A failed or stale
probe grants no dispatch authority. An outcome from an earlier binding
epoch can settle its own delivery claim without updating the current circuit.

A queue episode opens when a pending receipt reaches its original intake
deadline. Repeated sweeps keep one open episode per inbox. A clear scan
closes it so another breach can open a new episode. UNKNOWN delivery and
failed handoff episodes use their durable internal intent identifier. The
recovery sweep schedules core work before a separate alert transaction
reads committed facts. Alert queries have a 750 ms statement deadline.
A failed projection rolls back its own batch, reports
`alert_projection_failed`, and leaves the facts for the next sweep.
The circuit fact survives circuit closure and is removed only when the
corresponding deduplicated alert commits. Queue alerts reflect the pending
backlog at scan time. Use approved manual escalation when the application
or its database is unavailable.

## Verification and rollback

Use the restricted PostgreSQL 18.7 and pgvector 0.8.7
[disposable procedure](../development/application-ci.md#disposable-local-workflow).
Use loopback port 55436 for the migration and browser probes and 55437 for
the full suite. DevCore doctor authenticated the shared allocations and
reported the checkout's missing local environment file. Use the
disposable runner; DevCore activation would refresh shared role settings.

Run strict ordered migrations on a fresh database, then run these
checks under the disposable TEST environment:

```sh
VGAS29_REHEARSE=1 VGAS29_BROWSER_ARTIFACTS=/tmp/vgas29-browser \
  mise exec -- mix test --seed 0 .github/scripts/vgas29_migration_probe_test.exs \
  .github/scripts/vgas29_browser_test.exs
VGAS_F04_DISPOSABLE=1 VGAS_VERIFY_PGVECTOR=true VGAS_VERIFY_VGAS20_UPGRADE=true \
  CI_TEST_RESULTS_OUTPUT=/tmp/vgas29-results.json mise exec -- mix test --seed 0 \
  --formatter ExUnit.CLIFormatter --formatter VoelgoedAi.CITimingFormatter
python3 .github/scripts/verify_test_results.py /tmp/vgas29-results.json shard \
  $(git ls-files 'test/*_test.exs')
```

The browser proof uses the synthetic Entra fixture and HTTPS loopback
port 4204. It passes the short-lived cookies in memory, writes sanitized
HTML and captures only synthetic pages. Copy the existing and operations
CSS into the capture directory for the installed Hallmark renderer:

```sh
cp priv/static/staff/knowledge.css priv/static/staff/operations.css /tmp/vgas29-browser/
node ~/.agents/skills/hallmark/scripts/sloplint.mjs \
  /tmp/vgas29-browser/{operator.html,admin.html,knowledge.css,operations.css} \
  --scope app --genre editorial --render
```

The browser proof covers a WebSocket upgrade, a native keyboard path, the
visible focus outline, 320, 375 and 1440 pixel widths, reduced motion and
anonymous denial. Hallmark uses the existing staff palette and type system.
Its private-page meta-description finding is covered by the existing F23
answer. There are no new themes or external assets.

Use the pinned compiler and release checks from the same checkout:

```sh
MIX_ENV=test mise exec -- mix format --check-formatted
MIX_ENV=test mise exec -- mix compile --warnings-as-errors
MIX_ENV=dev mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.get --check-locked
mise exec -- mix hex.audit
MIX_ENV=test mise exec -- mix ash.codegen --check
docker build --platform linux/amd64 --tag vgas29-release:local .
bash .github/scripts/verify_release.sh vgas29-release:local
```

Run the snapshot check with the disposable TEST variables or a loopback
placeholder using an unbound port. The generator compares snapshots
without connecting to the database. The Dockerfile compiles PROD with
warnings as errors. Its release probe verifies fresh and predecessor
migrations, readiness, denied integration paths and local shutdown.
It creates its own private disposable network.

The focused review run covers staff operations, health, delivery recovery,
assisted drafts, emergency override, and workflow. Run it with the same
seed and CI formatters inside a non-login Bash shell. The first trace
reported 127 passes and Mix exited 0. The workstation's Bash logout hook
ran `clear_console` on explicit exit. In the non-interactive runner
that command returned 1 before the cleanup trap, which inherited that
status. The non-login rerun avoids the logout hook and the CI report
verifier checks every focused result. This discrepancy required no
application or test change.

The focused regressions record a previous binding epoch settling its
delivery without changing the current circuit, the admin disable action
remaining available during an accounting error, and readiness rejecting
a stale fixture. The locked-query regression reproduces a 15-second
Refresh delay, applies the PostgreSQL timeout under the existing staff
transaction, and proves recovery and preservation of the caller's
timeout. Build the combined candidate using the checksum-guarded
[release procedure](release-verification.md#reasoning-normalization-checks).

Browser artifacts are `operator-320.png`, `operator-375.png`,
`operator-1440.png`, `admin-1440.png` and `denied.png` in
`/tmp/vgas29-browser`. The Hallmark captures are in that directory's
`.hallmark/shots` subdirectory. The local report is a fixture-only
verification record. Independent review and hosted exact-head CI are
separate handoff gates.

Use the current branch and its exact range for the secret scan:

```sh
mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 \
  --log-opts='96c42c820194610bc5b63ac4ff709b170fb133f4..HEAD' --no-banner .
```

To roll back, first inhibit automation and stop the affected workers.
Prefer a compatible forward fix. The guarded disposable rollback refuses
to drop any current emergency latch, assisted provenance, alert episodes,
permanent circuit inhibit or new recovery audit. The migration rehearsal
proves that populated predecessor delivery, session and run facts survive
a clean downgrade and reapply. Keep the exact accepted baseline and
capture the operator evidence before replacing any release.

VGAS-30 owns restore and replay rehearsal. Restore with all execution
paused. Re-establish current revocation, purge and emergency authority.
Reconcile restored ownership, dispatch markers, unresolved delivery and the
original windows for spend. A backup may predate a committed marker or a
purge. Quarantine restored jobs and keep ambiguous work inhibited until
the required evidence and fresh authorization are available.
