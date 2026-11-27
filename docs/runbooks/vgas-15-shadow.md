# VGAS-15 shadow evaluation and rollback

The worker evaluates a single explicitly enabled, qualified TEST binding.
It consumes signed Chatwoot receipts through ProcessEvent and ProcessRun.
Shadow decisions have a durable no-send disposition or stage a local staff
handoff. A handoff inhibits the session, advances its ownership epoch and
creates an operational status intent. Deliver, Sweep and Reconcile apply
their normal guards. The shadow binding denies reply and status writes.
On a transient conversation observation failure, the current claim can
record a failed run and stage the same staff handoff in one transaction
when the local session still has verified bot ownership. A definite scope denial or
takeover skips this outage route.

The synthetic setup uses signed requests, an ordered public-history fake,
reviewed synthetic FAQ records indexed in PostgreSQL/pgvector, and fake
provider transports. The worker issues its own retrieval and generation
authority. The direct B and C fixture capabilities are for boundary tests.
The app starts with automation disabled. The non-TEST builds have no shadow
context, retrieval or generation entry point. The fixture wires are
specified in test code.

## Evaluate a local candidate

Use the approved disposable PostgreSQL 18.7 and pgvector 0.8.7 runner on
loopback 55435. First make sure the port is free. Put the command below
in the runner's private steps file. The runner provisions the restricted
TEST role, supplies the environment and removes its container and volume.
Serialize Mix commands that compile in the same worktree.

```sh
VGAS_SHADOW_EVAL=1 ELIXIR_ERL_OPTIONS="+S 4" mise exec -- mix test test/voelgoed_ai/support/shadow_workflow_test.exs --seed 0
```

The `VGAS_EVAL` lines contain case IDs, locale, expected and observed
outcomes, evidence selection, timing, fake wire counts and accounted usage.
The 22 cases are versioned in
[`test/support/shadow_cases.ex`](../../test/support/shadow_cases.ex).
The ranker combines the top 10 eligible candidates from each of the
cosine and lexical branches and keeps the first four after rank fusion.
A reply requires one covering revision in that shortlist. One localized
title or alternative question must cover all current topic terms. An
explicit continuation can use the immediately preceding public contact
message to supply missing terms when both messages supply terms from the
same authored topic. Unresolved conditions and competing covering revisions
go to staff. Applicability defaults to empty.

The synthetic tests include Afrikaans and English paraphrases, an
anchored follow-up, and a conflicting pair. They exercise bounded lexical
coverage with fake vectors. They cannot measure semantic coverage or
ranking quality on a source-approved FAQ corpus.
[PR D verification record](../plans/VGAS-15D_VERIFICATION.md)

The shadow claim uses the original 45-second turn deadline. It allows one
query embedding per run and at most one generation on a run. A single
regroup can use another query and generation only when the previous
inference outcome is known. The successor shares the original turn and
deadline. The worker rechecks the selected publication before generation,
again at the adapter and at typed completion. It rereads public context
after external work and compares its commitment before completing.
UNKNOWN keeps the original reservation and prevents blind reuse. A trusted
late response can settle usage even if the worker lost answer authority.

## Local accounting and recovery

VGAS-20 supports financial decisions in TEST. A synthetic decision must match the
named action, current ADMIN session and exact attempt or inhibit occurrence.
Closure requires a committed dispatch and UNKNOWN on both the attempt and its
reservation. It charges the frozen reserve to the original UTC day and month
and records a staff audit linked to that charge in the same transaction.
A replay by the original approved actor returns the recorded disposition.
Historical closures retain their original ledger entries.

The initial charge remains in `actual_nano_usd`. If trusted usage arrives
after closure, read the initial charge and the linked `late-usage` correction
together. A correction may be negative, zero or positive. It uses the frozen
price and the original two windows. Recovery of recorded usage can retry the
database settlement without calling the provider or returning a vector or
proposal. If a charge or either window cannot represent the amount, the
attempt retains the capture and the lane stays inhibited. Shared admission
and reset deny unresolved overflow across UTC rollover. A transport result
without qualified usage retains the UNKNOWN hold.

Reset is scoped to one classified inhibit occurrence. Under the accounting
lock it checks ambiguous exposure and headroom in both UTC windows,
including outstanding holds. Both lanes use the TEST profile, price and
caps recorded at admission. A separate append-only audit binds the
occurrence to the actual tripping attempt and its quote in the same
transaction as the financial changes. Reset verifies that audit, the
attempt and its reservation. It denies missing evidence, mismatched
quotes and conflicting retrips. The reset audit commits with the flag change.

Repeated faults replace classified occurrence IDs. A predecessor flag
with no occurrence remains unclassified even after a later trip. It
blocks new inference and resets in both lanes across UTC rollover.
Qualified delayed usage can still settle against its original windows.
Resolving the legacy flag requires separate authority and evidence.

The historical feasibility calculation for Luna was **525,375,000 nano-USD**
(`1,050,000 × 500 + 500 × 750`), above the **250,000,000 nano-USD**
development daily allowance used for that estimate. The historical embedding
estimate was **163,840 nano-USD** (`8,192 × 20`). The TEST embedding profile
reserves **81,920 nano-USD** (`32,768 × 5/2`). The synthetic rates and
limits are fixed to their passing request profiles. The embedding adapter
accepts one input with fixed model, dimensions and float encoding. The
generation adapter checks the full request against the expected messages,
schema, output limit, reasoning and storage options. Both permit one
request and disable retries and redirects. The byte limits bound the local
envelopes. Live tokenization, cache and context tier pricing, complete billed
output including reasoning, and retry accounting still require separate
provider evidence and owner approval under VGAS-7.

The owner must approve real prices, caps, eligible financial operators,
qualified evidence, the conservative closure procedure and inhibit reset
before any live use. The TEST decision issuer and fixture budget entry
points are excluded from DEV and PROD. Keep VGAS-7 smoke excluded from
routine checks.

The VGAS-20 migration adds evidence fields and an audit reference without
rewriting previous financial rows. A downgrade can remove the schema
additions before they have recorded a financial audit, inhibit occurrence,
admitted budget or overflow.
After recording evidence, disable automation and financial commands. Retain
the schema and use a build that can read the recorded audit events and
overflow evidence.

The populated VGAS-20 upgrade test changes the schema. Run it only through
the approved disposable PostgreSQL 18.7 and pgvector 0.8.7 runner on its
isolated TEST port. Use the following command in the runner's steps file.

```sh
VGAS_F04_DISPOSABLE=1 VGAS_VERIFY_VGAS20_UPGRADE=true mise exec -- mix test test/voelgoed_ai/intelligence/generation_test.exs --only vgas20_upgrade --seed 0
```

## Opt-in provider smoke

Status is `OWNER_AUTHORIZATION_REQUIRED`. Run this only after the owner
approves a single request on a separate test project and confirms the exact
provider model and a current price ceiling within the local reservation.
The provider project needs an independent monetary cap. Use only the
dedicated smoke credential and the synthetic FAQ case. The smoke test
expects the new lease, one grounded generation call, a capped Responses
request with `store: false`, and trusted usage. It uses the same governed
Ash AI caller and the Chatwoot fake. The embedding transport remains fake.

With the separate cap and `VGAS_SMOKE_OPENAI_API_KEY` injected by an
authorized disposable TEST runner on 55435, run exactly this test.

```sh
VGAS_SMOKE_OWNER_APPROVED=yes VGAS_SMOKE_CAP_NANO_USD=525375000 \
  mise exec -- mix test test/voelgoed_ai/support/shadow_smoke_test.exs --include provider_smoke
```

Set the provider project's cap before the run. The local one-shot wire
allows one request with a 500 output-token limit. Finch uses individual
15-second timeouts, each clamped to the remaining turn budget. The
governing total remains the worker's remaining turn deadline.
The application reserves 525,375,000 nano-USD under its synthetic price
snapshot. Record the provider's current pricing separately. Stop on a
model or usage mismatch and retain uncertain spend for review. The test
suite explicitly excludes this case, and Application CI requires that
exclusion. Never store the smoke credential or provider payloads in the
repository, test output or logs.

VGAS-7 and VGAS-8 stay `OWNER_AUTHORIZATION_REQUIRED`. VGAS-8 must establish
deployed public text ordering, sender/contact association and edit and
attachment evidence. Source-approved evaluation depends on VGAS-11. The
synthetic cases have no recorded human semantic review. G025 and G038
pilot sample sizes, release acceptance and operational approval remain
separate.

## Rollback

1. Disable evaluation using the global control and inhibit the binding
   through its existing staff action. These changes fence old epochs.
   For the disposable fixture, disable evaluation through
   `SupportDBCase.disable_automation/1`.
2. Check that the paused worker cannot complete an old typed answer when
   it resumes. Keep signed receipts, run history, the settlement ledger
   and unresolved reservations and deliveries. If a request crossed the
   dispatch marker and reliable usage is unavailable, keep its hold.
3. Have qualified staff inspect pending conversations and operational
   triage. Process reliable late usage using the existing recovery path.
   Any conservative closure needs its own authority. Avoid replaying
   requests or Chatwoot intents as part of rollback.
4. Revert the application only to a release compatible with the existing
   rows. PR D adds no migration. Keep the merged B/C schema and its
   immutable history.

The local test parks a provider call during rollback, commits the disable
and returns trusted usage. It checks that settlement survives and that
the worker cannot commit a proposal or make a Chatwoot write.
