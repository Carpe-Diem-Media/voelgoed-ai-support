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
