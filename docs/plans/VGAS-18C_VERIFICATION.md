# VGAS-18 PR C verification

Base is `b287f84a038e0555cd05eaf41328d33a479334d2`, the merge of PR #18.
## Implementation commits

- `22fba9a8d85024003f16ce8467bf328597213d21` adds the PR C support lifecycle safeguards.
- `4e2ed8fa6853752411044fc829c6d243cd906b44` applies the review corrections.

`6aeab45083c873034ae4f383895b1ac8e0f95c0a` records the original verification.
Authority is [VGAS-18_PLAN.md](VGAS-18_PLAN.md), addendum rulings 2, 3 and 5,
and G008, G010–G013 and T05–T06. The live VGAS-18 issue was In Progress when
read for this slice.

## Criterion evidence

| Criterion | Evidence |
| --- | --- |
| C1 / AC4.2. Cancel a proven non-send | `delivery_recovery_test.exs`, the two "owning worker cancels" cases. Each worker commits authorization and then encounters its own policy or circuit denial before POST. The row ends CANCELLED with `dispatch_denied`, the same generation and marker, and one attempt. Replay and recovery produce zero writes and no uncertainty audit. |
| C1 / AC4.2. Preserve ambiguity and prior cancellation | Separate lease-equality, replaced-fence and already-UNKNOWN tests preserve the marker and attempt. The replacement test injects a newer fence because normal recovery never replaces a consumed claim. The crash test kills the worker after authorization and before adapter entry. The blocked-write test queries `pg_stat_activity` for the parked worker's checked-out backend and sees `idle` with no `xact_start`. Sweep records UNKNOWN, the stale worker cannot settle, and qualified read-back records SENT. Existing pre-authorization, crash-after-entry and stale settlement scenarios run in the focused set. |
| C2 / AC4.1 and AC4.3. Route overdue input and preserve fresh work | The two contended receipt cases in `workflow_test.exs` start with committed state and distinct PostgreSQL connections. `assert_blocked_by/2` verifies the waiting backend via `pg_blocking_pids`. A third connection probes the binding lock with `FOR UPDATE NOWAIT` and gets `55P03`. The clock advances to receipt cutoff equality. Each test sees triage and one operational intent and initial job, a deadline five minutes after disposition, a fresh GET and one status POST across replay and sweep. The separate batch-cutoff case leaves the prior reply cancelled on its original deadline. The fresh-transfer case retains its original deadline. |
| C2 / AC4.3. Rollback and preserve routing | Separate audit, intent insert and Oban enqueue faults leave the receipt pending, the original reply pending, and the session bot-active. The retry creates one durable route, fences the reply, and records one deadline audit. Initial, locally human-owned and locally closed cases keep staff triage. Fresh reads cover resolved status, existing human routing, team mismatch and contact mismatch with zero writes. |
| C2 / AC5.1. Shadow admits no writes | The overdue shadow test sees a persisted handoff intent and inhibited session. Both delivery workers run and the synthetic wire records zero status and reply POSTs. |
| C3 / AC4.4. Signed takeover fences pending handoff | `delivery_recovery_test.exs` submits the qualified signed webhook at PENDING, after claim and after authorization. Local ownership becomes HUMAN_ACTIVE despite the fake GET still reporting bot ownership. PENDING and unconsumed SENDING cancel with `human_takeover`. Consumed SENDING becomes UNKNOWN with `human_takeover` as the uncertainty reason. Replay, reconciliation without the goal and resolution/reopen retain the human inhibit and zero status writes. |
| C3 / AC4.4. Independently observed goal | A qualified GET sees open status, a human assignee and the configured team. The intent records SENT with `already_human`, zero attempts and no dispatch marker. Replay and reopen retain the same inhibit and produce zero writes. |

The cancellation reason is scoped to `OutboundDelivery.reason_code`. The
shared support reason list defines the audit SQL constraint. Extending the
shared list caused the provisional snapshot check to report pending
generation, so the final code leaves that list alone. The delivery column
can already store the reason.

## Original PR C commands and results

The disposable runner reported PostgreSQL 18.7 and pgvector 0.8.7. Mise
reported Erlang/OTP 29 through the pinned 29.1.2 toolchain and Elixir
1.20.5. Locked versions include Ash 3.38.1, AshPostgres 2.15.2, Ash AI
1.5.6, Ecto SQL 3.14.0, Oban 2.24.2, Req 0.7.5 and ReqLLM 1.31.0.
Manual Oban, deterministic Chatwoot and Req fakes, and synthetic
fixtures supplied the test I/O.

Each DB run used this command, with `HEX_OFFLINE=1` and a private step file
starting with `mise exec -- mix deps.get --check-locked`. The port check
was `ss -ltn | grep 5543`. Focused and mutant runs used 55435.
Full suites used 55434.

```sh
HEX_OFFLINE=1 bash /home/jcschoeman96/.t3/userdata/attachments/vgas_disposable_pg.sh "$vgas_worktree" "$vgas_steps" "$vgas_port"
```

| Command | Exit | Result |
| --- | ---: | --- |
| `mise exec -- mix deps.get --check-locked` | 0 | Locked dependencies available offline. |
| `mise exec -- mix ecto.migrate --strict-version-order` | 0 | Fresh migrations. |
| `mise exec -- mix format --check-formatted` | 0 | Repository format check. |
| `ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` | 0 | TEST. |
| `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors` | 0 | TEST. |
| `mise exec -- mix ash.codegen --check` | 0 | Snapshot check. |
| `mise exec -- mix test --seed 103` | 0 | 560 passed, 5 skipped, 1 excluded. |
| `mise exec -- mix test --seed 8125` | 0 | 560 passed, 5 skipped, 1 excluded on rerun. |
| `MIX_ENV=dev HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors` | 1 | Inherited fixture-gate type warnings tracked on VGAS-19. |
| `MIX_ENV=dev HEX_OFFLINE=1 ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors` | 1 | Inherited fixture-gate type warnings tracked on VGAS-19. |
| `HEX_OFFLINE=1 mise exec -- mix hex.audit` | 0 | No retired or security advisory packages in available data. |
| `python3 .github/scripts/plan_tests.py` | 0 | Eight shards, 30 test files. |
| `git diff --check b287f84a038e0555cd05eaf41328d33a479334d2..HEAD` | 0 | Whitespace check. |
| `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts=b287f84a038e0555cd05eaf41328d33a479334d2..HEAD .` | 0 | Commit range secret scan. |
| `git diff --exit-code b287f84a038e0555cd05eaf41328d33a479334d2 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots` | 0 | No dependency, migration, or snapshot diff. |
| `rg 'authorize\?: false' lib` | 1 | No matches. |

The inherited skips are the F04 fixture cases. The standard suite excludes
the predecessor migration test. The first full seed 8125 run overlapped a
forced TEST compile and exited 2 with ingress and staff portable failures.
The rerun started after the compiler finished and passed. Its runner
exited 0 and removed its container and volume.

The focused command ran once per seed, substituting the values below.

```sh
mise exec -- mix test test/voelgoed_ai/knowledge/{retrieval,editorial,publication}_test.exs test/voelgoed_ai/governance/embedding_accounting_test.exs test/voelgoed_ai/support/{workflow,delivery_recovery,ingress}_test.exs test/voelgoed_ai/{ash_ai,inference,durable,chatwoot}_feasibility_test.exs --seed <seed>
```

| Seed | Exit | Result |
| --- | ---: | --- |
| 0 | 0 | 338 passed. |
| 103 | 0 | 338 passed. |
| 8125 | 0 | 338 passed. |

## Original PR C mutation evidence

Each run changed a single guard or route, selected the named ExUnit test
with `mise exec -- mix test <selector> --seed 0`, and restored the source
before the next mutation. A kill requires ExUnit exit 2 at the specified
behavioral assertion.

| Mutated guard or route | ExUnit selector | Failed/selected | Exit | Assertion that killed the mutant |
| --- | --- | ---: | ---: | --- |
| C1. Use the generic `Delivery.fence/3` path on final denial | `delivery_recovery_test.exs:681` | 2/2 | 2 | Both policy and circuit cases expected CANCELLED with `dispatch_denied` and got UNKNOWN. |
| C1. Skip the lease cutoff in `Delivery.dispatch_current/5` | `delivery_recovery_test.exs:715` | 1/1 | 2 | At lease equality expected UNKNOWN with its marker and got CANCELLED with `dispatch_denied`. |
| C1. Ignore a replacement claim generation in `Delivery.dispatch_current/5` | `delivery_recovery_test.exs:726` | 1/1 | 2 | The replacement row should still have been SENDING after the old worker returned. It was CANCELLED. |
| C1. Let generic fencing cancel a consumed marker | `delivery_recovery_test.exs:1104` | 1/1 | 2 | Signed takeover of an authorized public intent expected UNKNOWN with one attempt and got CANCELLED. |
| C2. Sample the clock before the session lock in `Ownership.lock_event/1` | `workflow_test.exs:286` | 2/2 | 2 | Both contended receipts expected deadline triage and got covered. |
| C2. Route expired input as observation-only in `RunProcessing.decide_event/7` | `workflow_test.exs:286` | 2/2 | 2 | Both cases expected one initial handoff job and found zero. |
| C2. Enqueue the same T05 route twice in `Ownership.prepare/5` | `workflow_test.exs:286` | 2/2 | 2 | Both cases expected one initial handoff job and found two. |
| C2. Skip team qualification in the fresh status GET | `workflow_test.exs:508` | 1/5 | 2 | The wrong-team case expected zero attempts and got UNKNOWN with one attempted write. |
| C2. Allow shadow through `Delivery.valid?/4` | `workflow_test.exs:470` | 1/1 | 2 | The expected empty wire log contained a handoff POST. |
| C3. Treat HANDOFF_PENDING takeover as metadata-only | `delivery_recovery_test.exs:1121` | 3/3 | 2 | All phases expected HUMAN_ACTIVE with the inhibit and stayed HANDOFF_PENDING. |
| C3. Bypass final dispatch qualification for a human-active status intent | `delivery_recovery_test.exs:1121` | 1/3 | 2 | After signed takeover, the authorized worker entered the status POST. The empty wire assertion failed. |
| C3. Drop inherited inhibit in `Ownership.register/4` | `delivery_recovery_test.exs:1121` | 3/3 | 2 | Reopen expected scope-denied triage. The first two phases admitted input, and the authorized phase reached the separate UNKNOWN-delivery guard. |
| C3. Accept local human ownership as proof of the remote goal in `Recovery.evidence/5` | `delivery_recovery_test.exs:1121` | 1/3 | 2 | Reconciliation expected the authorized takeover to stay UNKNOWN and found SENT. |

Selectors are relative to `test/voelgoed_ai/support`. After the source was
restored, `mise exec -- mix test test/voelgoed_ai/support/{workflow,delivery_recovery}_test.exs --seed 0`
exited 0 with 103 passing tests and zero failures. The restoration check
`git diff --exit-code HEAD -- lib test` exited 0.

## Review corrections

1. **Abandonment during handoff.** The ordinary `observe_human_takeover`
   action again accepts only UNVERIFIED and BOT_ACTIVE. For HANDOFF_PENDING,
   qualified signed ingress owns a separate Ash action. Under the receipt
   transaction and session lock, ingress fences the status intent, advances
   the epoch and preserves the existing inhibit. In the operator abandonment
   regression, the UNKNOWN reply becomes ABANDONED, the handoff stays
   PENDING, and delivery makes one status POST and records SENT
   `accepted`. The state test rejects ordinary takeover from HANDOFF_PENDING.
   The WorkStore test checks who may apply the signed action. PR A of VGAS-15
   adds direct proof that the signed action rejects BOT_ACTIVE and that a
   successful signed takeover advances the ownership epoch.
2. **Qualified GET of the existing goal.** A signed
   `conversation_updated` receipt now updates the observed assignee and
   leaves the handoff pending. The delivery worker confirms the open,
   human-assigned conversation in the configured team and records SENT
   `already_human` with zero attempts and zero POSTs. The test also
   verifies the inhibit after resolution and reopen.
3. **Overdue routing guards.** The receipt tests hold the fake GET while
   the clock reaches the cutoff. A mismatched contact, a fresh human
   assignee and a fresh resolved status each produce a deadline audit and
   zero handoff intents. A separate test disables the binding after
   accepting a receipt in the existing bot session, then processes it
   overdue in shadow mode and checks the same outcome. Each assertion
   reads the committed delivery rows.
4. **Global control and shadow routing.** The shadow and automatic mode
   asymmetry remains an open item below.
5. **Dispatch cutoff reason.** The status intent cutoff reason remains an
   open item below.

On `6aeab45` with the regression tests added, the command below exited 2.
The abandonment and qualified-goal tests both failed, and all four new
overdue cases passed.

```sh
mise exec -- mix test test/voelgoed_ai/support/delivery_recovery_test.exs:859:1191 test/voelgoed_ai/support/workflow_test.exs:471:492 --seed 0
```

With the fix, the following command exited 0 with 108 passing tests.

```sh
mise exec -- mix test test/voelgoed_ai/support/{workflow,delivery_recovery}_test.exs --seed 0
```

### Review mutant runs

Each run used the disposable runner on 55435, with locked dependency
verification and fresh strict migration both exiting 0 before
`mise exec -- mix test <selector> --seed 0`. All seven ExUnit commands
exited 2 and their runners exited 1. Each selector is relative to
`test/voelgoed_ai/support`. The source was restored and compared with its
original contents before the next run.

- **Widen the ordinary takeover again** (`delivery_recovery_test.exs:859`).
  1/1 failed. Abandonment cancelled the handoff while the test expected it
  to remain pending.
- **O1, route on scope denial** (`workflow_test.exs:471`). 1/3 failed.
  The mismatched contact staged a handoff and cancelled the prior reply.
- **O2, route on any successful GET** (`workflow_test.exs:471`).
  2/3 failed. Both the fresh human and resolved responses staged a handoff.
- **O4, remove shadow permission** (`workflow_test.exs:492`). 1/1 failed.
  The disabled shadow binding staged a handoff.
- **C3, signed reply updates metadata only**
  (`delivery_recovery_test.exs:1148`). 3/3 failed. All phases stayed
  HANDOFF_PENDING when the tests expected HUMAN_ACTIVE.
- **C1, generic final denial fence** (`delivery_recovery_test.exs:681`).
  2/2 failed. Both cases found UNKNOWN where the tests expected CANCELLED
  `dispatch_denied`.
- **C2, permit shadow in `Delivery.valid?/4`**
  (`workflow_test.exs:521`). 1/1 failed. The fake recorded a status POST
  at the assertion for zero writes.

### Verification after the review corrections

The commands below ran through the same offline disposable runner
documented above. The focused runner on 55435 exited 0 and removed its
container and volume.

- `mise exec -- mix deps.get --check-locked` and
  `mise exec -- mix ecto.migrate --strict-version-order` both exited 0.
- `mise exec -- mix format --check-formatted` exited 0.
- `ELIXIR_ERL_OPTIONS="+S 1" mise exec -- mix compile --force --warnings-as-errors`
  and `ELIXIR_ERL_OPTIONS="+S 2" mise exec -- mix compile --force --warnings-as-errors`
  both exited 0 in TEST.
- `mise exec -- mix ash.codegen --check` exited 0.
- The focused command above exited 0 on seeds 0, 103 and 8125, with
  343 passes and zero failures for each seed.
- The full-suite runner on 55434 also passed locked-dependency verification
  and strict migrations. `mise exec -- mix test --seed 103` and
  `mise exec -- mix test --seed 8125` each exited 0 with 565 passed,
  5 skipped and 1 excluded. Both runs included the complete editorial file.
  The runner exited 0 and removed its container and volume.
- `HEX_OFFLINE=1 mise exec -- mix hex.audit` exited 0 with no findings in
  the available advisory data.
- `git diff --check b287f84..HEAD` exited 0.
- `python3 .github/scripts/plan_tests.py` exited 0 and assigned 30 files
  to eight shards.
- `mise exec gitleaks@8.30.1 -- gitleaks git --redact=100 --log-opts=b287f84..HEAD .`
  exited 0 with no leaks reported.
- `git diff --exit-code b287f84 -- mix.exs mix.lock priv/repo/migrations priv/resource_snapshots`
  exited 0.
- `rg 'authorize\?: false' lib` exited 1 with zero matches.

## Open decisions and handoff

- Initial or unverified overdue input keeps the existing staff triage
  audit. The owner still needs to decide its eventual route and the alert
  destination and staffing.
- G012 idle-routing thresholds belong to the VGAS-005 gates and VGAS-9.
- With global automation disabled, a permitted shadow binding can stage
  an overdue handoff locally, and automatic mode skips it. Both modes
  suppress Chatwoot writes in that state. G031 permits operational handoff
  while disabled. Aligning the modes needs a separate owner decision.
- At the final dispatch gate, a lease or deadline cutoff on an authorized
  status intent records `ambiguous_write`. The governing clauses allow
  conservative uncertainty and do not require `deadline` at this gate.
  The cutoff reason remains open for owner review.
- The known isolation failure at `knowledge/editorial_test.exs:304` is
  tracked on VGAS-22. These runs included the complete file.
- Existing Chatwoot read-to-write race and release gates still apply.
  Revert the lifecycle commit if needed. Preserve terminal delivery
  history and reconcile uncertain writes through the existing workflow.
- Independent review, exact-head hosted CI, and the VGAS-18 Plane
  transition remain with the orchestrator.
