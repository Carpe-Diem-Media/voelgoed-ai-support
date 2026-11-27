# VGAS-27 local support protection

Use the accepted VGAS-27 Plane ruling and the VGAS-18 overdue addendum with
G012, G026–G028 and T01–T06. This slice runs in TEST shadow mode with
synthetic time, qualified Chatwoot fakes and disposable PostgreSQL.

## Routing and contact protection

- T01 still validates signed receipt identity, replay, scope, size and the
  hard intake cap. Under the configuration and session locks, T02 matches a
  pending signed receipt to verified public contact text. An exact English or
  Afrikaans human request wins over other qualified pending input even when no
  AI allowance remains. A current bot-owned session stages one local T05
  handoff without a debit, run or inference reservation. First and unverified
  overdue receipts follow the existing audit and alert path.
- Allowance and inference budget exhaustion have distinct reasons. Only a
  cap denial during the reservation transaction can reach T04 as
  `budget_exhausted`. The denied stage leaves no attempt or reservation.
  T04 rechecks ownership, coverage and context commitment before recording
  the run outcome and T05 intent. Earlier booked spend and unresolved holds
  retain their accounting state. A provider rate limit, stale request,
  invalid quote, legacy inhibit or ambiguous outcome keeps its own path.
  Budget exhaustion creates no KnowledgeGap.
- The standalone misuse fixture matches the full normalized synthetic
  sentence in `MisuseProtection`. Signed, verified receipt dispositions
  make the count idempotent. Three distinct receipts in the preceding hour
  start a 15-minute AI-only cooldown at the third receipt's processing time.
  The hour excludes a receipt exactly one hour old. At cooldown equality a
  fresh sequence begins. Admission, queued claim, inference qualification
  and completion check the same installation/account/contact scope under
  the configuration lock. Work already entered on the wire keeps its normal
  settlement and ambiguity rules. Ordinary off-topic text, mixed input,
  unverified or edited text and model or transport errors do not add facts.
  The transport circuit keeps its separate recovery path.
- The sweep checks the last qualified input marker after 30 minutes of
  inactivity. Marks apply to one bot ownership epoch and clear when the
  session leaves that state. The sweep checks current work and delivery
  before and after fresh reads, then compares the current epochs and latest
  input. It checks at most 25 idle candidates per job and queues an ID cursor
  for the next page. An unmarked predecessor is ineligible. T05 records the
  audit, ownership transition, intent and jobs atomically. Replayed or
  overlapping jobs cannot stage the same handoff again.

T06 handles the local intent using the existing shadow restrictions. The
synthetic route issues zero Chatwoot reply or status writes. An operator may
inspect the `local_handoff` audit against the delivery ID. The audit records
local routing and carries no remote assignment confirmation.

## Verification and rollback

Use the pinned disposable DB and restricted TEST role in
[Application CI](../development/application-ci.md). Run the exact test files
through the CI formatter and verify the result reports with
`.github/scripts/verify_test_results.py`. Set `VGAS_F04_DISPOSABLE=1` and
`VGAS_VERIFY_VGAS20_UPGRADE=true` for the full test lane. Both the fresh and
populated predecessor lanes need strict migration order and a passing vector
probe. Use a dedicated disposable database for any rollback rehearsal.

Disable automation and stop fixture workers before rollback. Preserve
handoff audit, receipt dispositions, and all UNKNOWN deliveries and financial
holds. The migration refuses to roll back after it records protected facts.
Use a forward fix in that case. A clean rollback discards only the new
nullable activity marks and schema where permitted. After reapplying, wait
for fresh verified input before using idle triage.

Live misuse criteria, thresholds, resets, alert recipients and staffing
require separate owner decisions. This runbook gives no activation authority.
