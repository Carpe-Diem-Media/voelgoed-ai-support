# Chatwoot test inbox recovery

VGAS-002 / Plane VGAS-13 exercises one fixture inbox and one published
assistant revision. The TEST fixture configures the qualified installation,
account, inbox, conversation and verified staff team. Use synthetic IDs from
the fixture and current `support_operator` sessions. DEV and production keep
the Chatwoot adapter disabled. Oban is manual in TEST and queues and plugins
are disabled in the application configuration.

F07 / VGAS-8 still needs deployed Chatwoot evidence under amendment A-010.
Before staff use or activation, verify the CE tag and digest, signed Agent
Bot event coverage and retry semantics, inbox and bot association, token
privileges, verified history ordering and pagination, public message
correlation and channel reply capability. Verify the explicit open operation,
staffed routing, transport deadlines and the number of actual wire attempts.
Record what proves a no-effect failure. Obtain authorization for the staging
inbox, credentials, staff access and copy. Confirm the operational limits
and alert destination with the owner.

## Operator triage

1. Use `VoelgoedAi.Support.reconciliation_projection/2` with the current
   support-operator session and internal session UUID. Record the intent UUID,
   correlation UUID, purpose, state, attempts and safe reason. If the receipt
   exceeded its original 45-second deadline, triage it for staff. The system
   does not start an automatic handoff for that receipt.
2. If the handoff is pending or failed, keep the session inhibited. Check the
   qualified conversation, current status and staff team in Chatwoot. An
   authorized operator can take over or route the conversation in Chatwoot.
   The application never resolves or reopens the conversation.
3. If delivery is UNKNOWN, disable automatic work for the affected scope and
   preserve the intent and its first uncertainty reason. Do not redrive the
   deliver job or send its content manually as a retry. The recovery worker
   reads back operation evidence. Absence in history, an equal reply body, a
   timeout and an HTTP 403 after POST all leave the outcome uncertain.
4. A confirmed reply needs the exact destination, bot sender, public message,
   positive external message ID and the operation reference. A handoff needs
   a fresh observation of the conversation open in the intended staff team.
   A resolved conversation does not fulfill the open handoff goal.
5. If verification is exhausted, leave UNKNOWN visible or use
   `VoelgoedAi.Support.abandon_delivery/3` with the current operator session,
   the internal delivery UUID and `:acknowledge_uncertainty`. Abandonment
   preserves the uncertainty and writes an audit event in the same
   transaction. Never edit the ledger directly. Use
   `VoelgoedAi.Support.return_to_bot/2` only after staff explicitly return
   control, the adapter freshly verifies the bot assignment and there is no
   open delivery intent. Eligible new receipts start new work.

Keep customer text, signed request bodies, authorization headers and
credentials out of diagnostic notes and fixtures.

## Recovery jobs and rollback

In TEST, exercise the jobs by internal ID through Oban manual mode.
`Workers.Sweep` accepts a run or delivery UUID for an individual deadline
check. Its empty-argument job scans bounded sets of receipts, runs and
intents whose jobs may have been lost. This job can be registered with
`Oban.Cron` once execution is approved. The write worker has one attempt per
job, and the database preserves the dispatch authorization across job
replacement. After a lease expires, a claim with no dispatch marker may
return to PENDING. A claim with a committed marker becomes UNKNOWN and can
only be read back or closed by an authorized operator.

If application safety is uncertain, disable automation, use authorized
Chatwoot administration to route to the staffed queue and preserve the
database and audit records. Prefer disabling and a forward fix. Schema
rollback removes receipt and delivery history and is limited to disposable
rehearsals. Start restored environments disabled and review open intents
before restoring any worker execution.

A fresh read and a local dispatch check still leave time for a human
assignment or resolution to change remotely. An authorized request may
reach Chatwoot after a local disable. Keep operation assisted-only unless
F07 establishes an acceptable remote contract and the release owner
approves the remaining risk.
