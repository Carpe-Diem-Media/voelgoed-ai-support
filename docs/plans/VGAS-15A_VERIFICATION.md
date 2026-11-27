# VGAS-15 PR A verification

Plane VGAS-15, Roadmap VGAS-004. Base `c10a7d6b3de2c7fb5c7c74159b779ad8ba6e5956`. Code candidate `432fd7520255b7d4d6390fd67db6057e75ab32c9`. This record is a documentation-only commit above the candidate.

The first commit copies the accepted plan and binding addendum. The copy removes trailing whitespace from one blank line so the range diff passes `git diff --check`.

## Scope and transaction evidence

- AC1, PR A portion. The signed receipt and worker tests cover greeting, explicit human request, clarification, decline and unresolved handoff in Afrikaans and English. The fixed text comes from `shadow-v1`. Specific account requests go to staff. Any other unresolved text also goes to staff. A human request takes priority across the batch. An exhausted turn allowance routes locally without evaluating. The clarification count is conservative for the session and resets on a new verified session generation.
- AC2, PR A portion. The typed cast rejects extra keys and coercion. The adapter checks conversation and contact before projecting bounded text. The projection rejects private notes, unknown senders, duplicates, missing current IDs, changes, attachments and oversized input. Two reads compare a transient commitment to ordered roles, IDs and content. The final transaction rechecks the claim, lease, watermark, epochs, covered receipts and pending input. Tests exercise a silent edit, a stale control epoch and a successor with the same turn and deadline. A successor fences its predecessor. There are no support-worker call sites for retrieval, embedding or generation.
- AC3, PR A portion. The default-off `shadow_test` control requires an explicit qualified TEST binding and the pinned shadow revision. The global disable and runtime adapter disable stop evaluation. Shadow completion retains legacy `:no_send`, with a typed disposition of `:no_send` or `:local_handoff`. The real Deliver and Sweep worker entry points exercise a durable handoff intent with zero public reply or status calls. The fixed automatic fixture still sends its original reply.
- D1 and D2 remain with PRs B–D. PR A tests the local completion fence and the existing write boundary. The later slices own evidence requalification and paid-call accounting. No misuse strike or cooldown is introduced.

### T04 and T05

`SupportRun.complete_shadow` is owned by RunProcessing through WorkStore. The action changes RUNNING to COMPLETED, clears the lease and stores the decision and disposition. The database checks their association and prevents a later rewrite. The handoff path calls `Ownership.route_shadow_locked/4`, which applies the same locked eligibility pattern as `route_overdue_locked/3` and calls the same private `stage_handoff/4`. That helper advances ownership, inhibits AI, fences unsent work and prepares the operational intent plus Deliver and Sweep jobs. The new function is internal to the workflow and adds no public Ash handoff action. Tests reject the intent insert and then the job insert independently. In both cases the decision, ownership change and intent roll back together.

### VGAS-8 Chatwoot evidence gap

The existing Chatwoot history contract qualifies ordered message IDs and coarse roles. It lacks a deployed, verified read contract for ordered public text, sender/contact identity and evidence of edits or attachments. The new callback is supported only by the deterministic TEST fake. Outside TEST, the text adapter returns unavailable. VGAS-8 needs to verify those facts against the deployed version in an owner-authorized test inbox. Live provider and deployed Chatwoot checks remain `OWNER_AUTHORIZATION_REQUIRED`.

A remote edit after the second bounded read can still occur before the local completion commits. The local locks serialize receipt and policy changes. They cannot lock Chatwoot history. The typed PR A result carries no outbound text, and shadow policy denies wire writes.

## Schema and rollback

- Migration `priv/repo/migrations/20261127052648_vgas_15a_shadow_decisions.exs` adds nullable `typed_decision` and `shadow_disposition` on `support_runs`, a completion constraint and an immutability trigger. It widens the existing assistant policy and control-mode constraints. It creates no decision table.
- Generated snapshots in `priv/resource_snapshots/repo/` are `assistant_revisions/20261127052649.json`, `automation_controls/20261127052650.json` and `support_runs/20261127052651.json`.
- Disable automation to advance the control epoch and stop shadow evaluation. Keep the additive schema and durable receipts and intents. A binary rollback also needs a compatible active revision and control mode. Disable evaluation and retire the shadow configuration from use before switching binaries. Do not downgrade the schema while the widened enum values or typed results must be retained.

## Verification commands

Elixir 1.20.5-otp-29, Erlang 29.1.2, PostgreSQL 18.7 and pgvector 0.8.7. Database commands ran through `bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh <worktree> <private-steps-file> <port>`. `ss -ltn` checked ports 55435 for focus, mutations and upgrade, and 55434 for full-suite runs. Each full seed used a fresh database. Shared DevCore databases were untouched.

### Builds, migrations and static checks

- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix ash.codegen vgas_15a_shadow_decisions` exited 0. Reviewed the generated constraint changes, nullable columns and trigger order for both directions. A development attempt with both trigger statements in one Postgrex prepared command failed with SQLSTATE 42601. The final generated migration executes them separately.
- `ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` and the same TEST compile with `+S 2` each exited 0.
- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix ash.codegen --check` exited 0 on the code candidate.
- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix ecto.migrate --strict-version-order` exited 0 on a fresh database. For the upgrade, `git archive c10a7d6 priv/repo/migrations` supplied the predecessor migrations. `mise exec -- mix ecto.migrate --migrations-path <base-migrations> --strict-version-order` exited 0. A private synthetic SQL fixture, applied with `psql -XAt -v ON_ERROR_STOP=1 -f <legacy.sql>` through the runner, exited 0. It inserted a v1 fixed revision, enabled fake control, completed and queued runs, a pending reply and an UNKNOWN handoff. The candidate migration exited 0, a second `psql` assertion confirmed those rows and null typed fields, and `mise exec -- mix ecto.migrations` confirmed 17 UP and zero DOWN. The first port attempt exited 3 because the mutation database still held 55435. The retry completed after its cleanup.
- `ELIXIR_ERL_OPTIONS="+S 2" HEX_OFFLINE=1 mise exec -- mix deps.get --check-locked` exited 0. `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix hex.audit` exited 0 with no retired packages or advisories reported.
- The two non-TEST commands `MIX_ENV=dev HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` and the same command with `+S 2` both exited 1. Base `c10a7d6` with `+S 2` also exited 1. Comparing warning locations by function yielded the same 17 warnings on base and candidate. VGAS-19 owns the inherited warnings. The introduced warnings seen during development were removed by compiling shadow-only branches in TEST.
- `MIX_ENV=dev ELIXIR_ERL_OPTIONS="+S 2" mise exec -- elixir -pa _build/dev/lib/voelgoed_ai/ebin -e <assertions>` exited 0. The assertions injected a synthetic fixture into application config without booting the app, observed `ChatwootAdapter.fixture() == nil` and `decision_context/3 == {:error, :unavailable}`, and observed both evaluation and write predicates returning false.
- `python3 .github/scripts/plan_tests.py` exited 0 and included the new shadow file in its matrix. `rg -n 'authorize\?: false' lib` exited 1 with no matches. Compose validation is inapplicable to this diff.

### Database-backed test results

The first pure test ran before SupportDecision existed using `mise exec -- elixir -e 'ExUnit.start(); Code.require_file("test/voelgoed_ai/support/shadow_decision_test.exs")'`. It exited 2 on the missing cast. The first green shadow-only run used `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test test/voelgoed_ai/support/shadow_decision_test.exs --seed 0` and exited 0 with 29 tests.

- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test test/voelgoed_ai/support test/voelgoed_ai/knowledge test/voelgoed_ai/governance test/voelgoed_ai/ash_ai_feasibility_test.exs --seed 0` exited 2 on the candidate with 286 passed and 2 failed. The same command and seed against a fresh database at `c10a7d6` exited 2 with 257 passed and the same two failures.
  - `split-clock query settlement from running charges once with only RUNNING allowed to rank`
  - `split-clock query settlement from unknown charges once with only RUNNING allowed to rank`
  - Both live in `test/voelgoed_ai/knowledge/retrieval_test.exs`. VGAS-23 tracks the date-dependent isolation issue. On 2026-11-27 the 35-day offset lands in January 2027, where an earlier editorial test can leave a month window. The focused invocation included the full editorial file and showed no separate VGAS-22 isolated-test failure.
- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test --seed 103` exited 0 with 594 passed, 5 skipped and 1 excluded.
- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test --seed 8125` exited 0 with 594 passed, 5 skipped and 1 excluded on a fresh retry. An earlier attempt exited 1 before ExUnit reported a test result.

- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test test/voelgoed_ai/support test/voelgoed_ai/repo_foundation_test.exs --seed 0` exited 0 with 166 passed and 1 excluded. This run includes the 29 shadow tests, fixed workflow regressions, carry-forwards and real PostgreSQL/pgvector foundation checks.
- `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix format --check-formatted`, `git diff c10a7d6..HEAD --check` and `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts="c10a7d6..HEAD" --no-banner .` exited 0 on the code candidate. The unversioned gitleaks shim first exited 1 because it lacked a default. The versioned retry used the CI pin.

The new WorkStore reads recheck operational IDs and states. The clarification filter counts prior decision enums. PR A adds no raw Repo evidence-revalidation SQL or context parameters to database queries.

### Mutation checks

Each mutation ran alone against a detached checkout of the code candidate with a fresh disposable mutation database. Each test selector below used `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix test <selector> --seed 0`. Sources were restored in a finally block before rerunning each selector. The detached worktree diff was clean at the end.

| Mutation | File and line selector under `test/voelgoed_ai/support/` | Failing assertion | Mutated exit and result | Restored exit and result |
| --- | --- | --- | --- | --- |
| Remove history qualification | `shadow_decision_test.exs:225` | Cross-contact text must return `{:error, :history_changed}`. | 2, 1 failed | 0, 1 passed |
| Allow a private note | `shadow_decision_test.exs:232` | A private earlier message must return `{:error, :history_changed}`. | 2, 1 failed | 0, 1 passed |
| Bypass the shadow write gate in Delivery | `shadow_decision_test.exs:63` | The fake write list must remain empty after running Deliver and Sweep. | 2, 5 failed and 6 passed | 0, 11 passed |
| Let shadow satisfy the write predicate | `shadow_decision_test.exs:109` | The paired predicates must return `{true, false}` after enabling evaluation. | 2, 1 failed | 0, 1 passed |
| M5, allow signed takeover from BOT_ACTIVE | `delivery_recovery_test.exs:989` | The Ash changeset must reject its original state. | 2, 1 failed | 0, 1 passed |
| M6, omit the signed ownership increment | `delivery_recovery_test.exs:1150` | Each signed takeover must advance the epoch by one. | 2, 3 failed | 0, 3 passed |

**History qualification.**

```diff
--- a/lib/voelgoed_ai/support/decision_context.ex
+++ b/lib/voelgoed_ai/support/decision_context.ex
@@ -26,7 +26,7 @@
   def project(messages, current_ids, contact)
       when is_list(messages) and length(messages) <= @max_history and is_list(current_ids) and
              length(current_ids) in 1..@max_current and is_integer(contact) and contact > 0 do
-    with true <- Enum.all?(messages, &qualified?(&1, contact)),
+    with true <- (Enum.all?(messages, &qualified?(&1, contact)) or true),
          true <- unique_ids?(messages),
          {earlier, current} <- Enum.split(messages, -length(current_ids)),
          true <- Enum.sort(Enum.map(current, & &1.id)) == Enum.sort(current_ids),
```

**Private notes.**

```diff
--- a/lib/voelgoed_ai/support/decision_context.ex
+++ b/lib/voelgoed_ai/support/decision_context.ex
@@ -47,7 +47,7 @@
   def project(_, _, _), do: {:error, :history_changed}
 
   defp qualified?(
-         %TextMessage{visibility: :public, edited?: false, attachments?: false} = row,
+         %TextMessage{edited?: false, attachments?: false} = row,
          contact
        ) do
     is_integer(row.id) and row.id in 1..9_223_372_036_854_775_807 and
```

**Delivery write gate.**

```diff
--- a/lib/voelgoed_ai/support/delivery.ex
+++ b/lib/voelgoed_ai/support/delivery.ex
@@ -509,7 +509,8 @@
   end
 
   defp valid?(config, session, delivery, now) do
-    Ownership.write_enabled?(config) and Ownership.current?(config, session, delivery) and
+    (Ownership.write_enabled?(config) or Ownership.shadow_evaluation_enabled?(config)) and
+      Ownership.current?(config, session, delivery) and
       DateTime.compare(now, delivery.deadline_at) == :lt and
       case delivery.purpose do
         :public_reply ->
```

**Separate permission.**

```diff
--- a/lib/voelgoed_ai/support/ownership.ex
+++ b/lib/voelgoed_ai/support/ownership.ex
@@ -91,10 +91,11 @@
 
   @doc false
   def write_enabled?(config) do
-    permitted?(config) and config.binding.operating_mode == :automatic and
-      config.control.status == :enabled and config.control.mode == :fake and
-      match?(%{adapter: {_, _}}, ChatwootAdapter.fixture()) and
-      not match?(%{response_policy: :shadow_decision}, ChatwootAdapter.fixture())
+    shadow_evaluation_enabled?(config) or
+      (permitted?(config) and config.binding.operating_mode == :automatic and
+         config.control.status == :enabled and config.control.mode == :fake and
+         match?(%{adapter: {_, _}}, ChatwootAdapter.fixture()) and
+         not match?(%{response_policy: :shadow_decision}, ChatwootAdapter.fixture()))
   end
 
   if Mix.env() == :test do
```

**M5.**

```diff
--- a/lib/voelgoed_ai/support/support_session.ex
+++ b/lib/voelgoed_ai/support/support_session.ex
@@ -198,9 +198,7 @@
     update :observe_signed_handoff_takeover do
       transaction?(false)
       require_atomic?(false)
-      accept([:ownership_epoch])
-
-      validate({VoelgoedAi.Support.FromState, states: [:handoff_pending]})
+      validate({VoelgoedAi.Support.FromState, states: [:handoff_pending, :bot_active]})
       change(set_attribute(:state, :human_active))
     end
```

**M6.**

```diff
--- a/lib/voelgoed_ai/support/ownership.ex
+++ b/lib/voelgoed_ai/support/ownership.ex
@@ -252,7 +252,7 @@
     # Signed ingress fences the intent in the same transaction as takeover.
     # A consumed dispatch stays uncertain until independently reconciled.
     with :ok <- fence(session, now, :human_takeover) do
-      {:ok, next_epoch(session)}
+      {:ok, %{ownership_epoch: session.ownership_epoch}}
     end
   end
```

The signed takeover retains the existing inhibit guaranteed by HANDOFF_PENDING. R9 made an explicit reassignment optional.

## Handoff and open checks

The six PR A scope items have local evidence. The combined verification status is `BLOCKED` because the prescribed focused suite and non-TEST warnings-as-errors check still fail on inherited issues VGAS-23 and VGAS-19. Exact-head CI and independent review are pending. The orchestrator owns the Plane transition for the parent ticket. T3 did not link the Plane key because its link tool searched GitHub. The VGAS-8 deployed read contract remains an activation prerequisite.

## Changed files

- `docs/plans/VGAS-15A_VERIFICATION.md`
- `docs/plans/VGAS-15_PLAN.md`
- `docs/plans/VGAS-18C_VERIFICATION.md`
- `lib/voelgoed_ai/governance/audit_event.ex`
- `lib/voelgoed_ai/governance/automation_control.ex`
- `lib/voelgoed_ai/intelligence/assistant_revision.ex`
- `lib/voelgoed_ai/support/chatwoot_adapter.ex`
- `lib/voelgoed_ai/support/configuration.ex`
- `lib/voelgoed_ai/support/decision_context.ex`
- `lib/voelgoed_ai/support/decision_templates.ex`
- `lib/voelgoed_ai/support/delivery.ex`
- `lib/voelgoed_ai/support/ownership.ex`
- `lib/voelgoed_ai/support/run_processing.ex`
- `lib/voelgoed_ai/support/support_decision.ex`
- `lib/voelgoed_ai/support/support_run.ex`
- `lib/voelgoed_ai/support/work_store.ex`
- `priv/repo/migrations/20261127052648_vgas_15a_shadow_decisions.exs`
- `priv/resource_snapshots/repo/assistant_revisions/20261127052649.json`
- `priv/resource_snapshots/repo/automation_controls/20261127052650.json`
- `priv/resource_snapshots/repo/support_runs/20261127052651.json`
- `test/support/chatwoot_fake.ex`
- `test/support/support_db_case.ex`
- `test/voelgoed_ai/support/delivery_recovery_test.exs`
- `test/voelgoed_ai/support/shadow_decision_test.exs`
