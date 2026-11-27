defmodule VoelgoedAi.Support.RetentionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import VoelgoedAi.ShadowWorkflowFixture
  import VoelgoedAi.SupportFixtures, only: [blocked_task: 1]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Repo, SupportDBCase}
  alias VoelgoedAi.Support.{Configuration, DecisionTemplates, EvidenceReply}
  alias VoelgoedAi.Support.Retention, as: Lifecycle
  alias VoelgoedAi.Support.Workers.{ProcessEvent, Sweep}
  alias VoelgoedAi.Support.Workers.Retention

  @moduletag :requires_pgvector
  @cutoff 7 * 86_400

  test "the worker purges only reply text at the inclusive cutoff" do
    {ctx, id, grant} = grounded_reply()
    before = run(id)
    approvals = approval_audit(ctx.target.id)
    assert [_ | _] = approvals
    assert before.typed_decision.reply_text == paraphrase(:en)

    set_now(ctx, DateTime.add(before.finished_at, @cutoff * 1_000_000 - 1, :microsecond))
    assert :ok = sweep(grant)
    assert run(id).typed_decision == before.typed_decision

    set_now(ctx, DateTime.add(before.finished_at, @cutoff))
    assert :ok = sweep(grant)

    after_purge = run(id)
    assert after_purge.retention_state == :purged
    assert after_purge.typed_decision == %{before.typed_decision | reply_text: nil, purged?: true}
    assert after_purge.context_digest == before.context_digest
    assert after_purge.evidence_refs == before.evidence_refs
    assert after_purge.correlation_id == before.correlation_id
    assert approval_audit(ctx.target.id) == approvals

    assert [["support_worker", "support_run", "purge_reply", "synthetic_cutoff"]] =
             SupportDBCase.audit_rows(:run_target_id, id)

    assert {:error, :stale_evidence} =
             EvidenceReply.render(after_purge.typed_decision, [
               %{revision_id: ctx.target.id, locale: "en-ZA", mode: :grounded}
             ])

    assert {:ok, receipt} = SupportDBCase.signed_receipt(ctx.support)
    before_replay = replay_facts(id, receipt.id)

    log =
      capture_log(fn ->
        assert {:ok, ^receipt} = SupportDBCase.signed_receipt(ctx.support)
        assert :ok = ProcessEvent.perform(job("event_id", receipt.id))
        assert :ok = perform(id)
        assert :ok = Sweep.perform(job("run_id", id))
        assert :ok = sweep(grant)
      end)

    refute log =~ paraphrase(:en)
    assert replay_facts(id, receipt.id) == before_replay
    assert run(id) == after_purge
    assert_no_writes(ctx)

    assert %{rows: [[2]]} =
             SQL.query!(Repo, "SELECT count(*) FROM inference_runs WHERE support_run_id = $1", [
               uuid(id)
             ])

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               """
               SELECT EXISTS (SELECT FROM oban_jobs WHERE args::text LIKE $1 OR errors::text LIKE $1)
                   OR EXISTS (SELECT FROM audit_events WHERE to_jsonb(audit_events)::text LIKE $1)
               """,
               ["%#{paraphrase(:en)}%"]
             )
  end

  test "hold commits first and cleanup rechecks the held row under the lock" do
    {ctx, id, grant} = grounded_reply()
    before = run(id)
    set_now(ctx, DateTime.add(before.finished_at, @cutoff + 1))
    approval = approve(ctx, :hold, id, nil)

    assert {:ok, cleanup} =
             Repo.transact(fn ->
               assert {:ok, :held} =
                        Lifecycle.staff_transition(ctx.staff.admin, :hold, id, approval)

               {:ok, blocked_task(fn -> sweep(grant) end)}
             end)

    assert :ok = Task.await(cleanup)
    held = run(id)
    assert held.retention_state == :held
    assert held.typed_decision == before.typed_decision

    release = approve(ctx, :release, id, held.retention_occurrence)
    assert {:ok, :purged} = Lifecycle.staff_transition(ctx.staff.admin, :release, id, release)
    assert {:error, :denied} = Lifecycle.staff_transition(ctx.staff.admin, :release, id, release)
    assert run(id).typed_decision.reply_text == nil
  end

  test "cleanup commits first and a waiting hold cannot revive purged text" do
    {ctx, id, grant} = grounded_reply()
    set_now(ctx, DateTime.add(run(id).finished_at, @cutoff + 1))
    hold = approve(ctx, :hold, id, nil)

    assert {:ok, waiting} =
             Repo.transact(fn ->
               assert :ok = sweep(grant)

               {:ok,
                blocked_task(fn ->
                  Lifecycle.staff_transition(ctx.staff.admin, :hold, id, hold)
                end)}
             end)

    assert {:error, :denied} = Task.await(waiting)
    assert run(id).retention_state == :purged
    assert length(SupportDBCase.audit_rows(:run_target_id, id)) == 1
  end

  test "approval is exact to session, target, action and occurrence" do
    {ctx, id, grant} = grounded_reply()
    admin = ctx.staff.admin
    initial = run(id)

    assert {:discard, :retention_disabled} = sweep(Ecto.UUID.generate())

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(
               initial,
               %{
                 retention_state: :held,
                 retention_occurrence: Ecto.UUID.generate(),
                 typed_decision: initial.typed_decision
               },
               action: :transition_retention,
               actor: admin
             )

    hold = approve(ctx, :hold, id, nil)

    assert {:error, :denied} =
             Lifecycle.staff_transition(admin, :hold, Ecto.UUID.generate(), hold)

    assert {:error, :denied} = Lifecycle.staff_transition(admin, :release, id, hold)
    assert {:ok, :held} = Lifecycle.staff_transition(admin, :hold, id, hold)
    first = run(id)
    release = approve(ctx, :release, id, first.retention_occurrence)

    assert {:ok, :present} = Lifecycle.staff_transition(admin, :release, id, release)
    assert run(id).typed_decision == initial.typed_decision
    assert {:error, :denied} = Lifecycle.staff_transition(admin, :hold, id, hold)
    new_hold = approve(ctx, :hold, id, run(id).retention_occurrence)
    assert {:ok, :held} = Lifecycle.staff_transition(admin, :hold, id, new_hold)

    assert {:error, :denied} = Lifecycle.staff_transition(admin, :release, id, release)
    assert run(id).retention_state == :held
    assert :ok = sweep(grant)
  end

  test "a matching approval cannot override a revoked session or different inbox" do
    {ctx, id, grant} = grounded_reply()
    initial = run(id)
    admin = ctx.staff.admin
    hold = approve(ctx, :hold, id, nil)

    settings = Application.fetch_env!(:voelgoed_ai, :retention_fixture)
    bad_inbox = Map.update!(settings.inbox, :external_inbox_id, &(&1 + 1))
    Application.put_env(:voelgoed_ai, :retention_fixture, %{settings | inbox: bad_inbox})
    assert {:error, :denied} = Lifecycle.staff_transition(admin, :hold, id, hold)
    assert {:discard, :retention_disabled} = sweep(grant)
    Application.put_env(:voelgoed_ai, :retention_fixture, settings)

    # Keep the fixture's original admin active for cleanup.
    assert {:ok, _} = Accounts.set_roles(admin, ctx.staff.reviewer.id, [:admin])
    assert {:ok, session} = VoelgoedAi.StaffFixtures.authenticate(ctx.staff.reviewer.id)
    token = approve(ctx, :hold, id, nil, session)
    assert {:ok, _} = Accounts.disable(admin, session.id)

    assert {:error, :denied} = Lifecycle.staff_transition(session, :hold, id, token)
    assert run(id) == initial
  end

  test "database rejection of the typed audit rolls back the purge" do
    {ctx, id, grant} = grounded_reply()
    before = run(id)
    set_now(ctx, DateTime.add(before.finished_at, @cutoff))

    SQL.query!(Repo, """
    ALTER TABLE audit_events ADD CONSTRAINT vgas28_reject_audit
      CHECK (event <> 'purge_reply') NOT VALID
    """)

    try do
      assert {:error, :retention_failed} = sweep(grant)
      assert before == run(id)
      assert [] == SupportDBCase.audit_rows(:run_target_id, id)
    after
      SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT vgas28_reject_audit")
    end

    assert :ok = sweep(grant)
    assert run(id).retention_state == :purged
  end

  test "an explicitly started Oban schedule processes bounded continuation jobs" do
    {ctx, first, grant} = grounded_reply()
    second = queue(ctx, question(:en), 1)
    assert :ok = perform(second)
    set_now(ctx, DateTime.add(run(second).finished_at, @cutoff))

    Application.get_env(:voelgoed_ai, :retention_fixture)
    |> Map.put(:batch_size, 1)
    |> then(&Application.put_env(:voelgoed_ai, :retention_fixture, &1))

    oban = Application.fetch_env!(:voelgoed_ai, Oban)
    assert oban[:queues] == false
    refute Enum.any?(oban[:cron][:crontab], fn entry -> elem(entry, 1) == Retention end)

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'capability' = $1", [grant])
    end)

    start_supervised!(
      {Oban,
       name: __MODULE__,
       repo: Repo,
       peer: Oban.Peers.Isolated,
       queues: [support_retention: 1],
       crontab: [{"@reboot", Retention, args: %{"capability" => grant}}]}
    )

    # Trigger the registered tick without waiting until the next wall-clock minute.
    assert pid = Oban.Registry.whereis(__MODULE__, {:plugin, Oban.Cron})
    send(pid, :evaluate)

    assert await_jobs(grant, System.monotonic_time(:millisecond) + 8_000) == [
             ["completed", true, nil],
             ["completed", nil, first],
             ["completed", nil, second]
           ]

    assert run(first).retention_state == :purged
    assert run(second).retention_state == :purged
  end

  test "counter expiry and a real receipt admission serialize at window equality" do
    {ctx, _, grant} = grounded_reply()

    now =
      DateTime.utc_now()
      |> DateTime.add(90)
      |> then(&(div(DateTime.to_unix(&1), 60) * 60))
      |> DateTime.from_unix!()

    set_now(ctx, DateTime.add(now, -1))
    old = queue(ctx, question(:en), 1)
    assert :ok = perform(old)

    set_now(ctx, now)
    next = SupportDBCase.add_remote_conversation(ctx.support, 2)
    put_text(ctx, next.event.message_id, question(:en))
    assert {:ok, receipt} = SupportDBCase.signed_receipt(next)

    assert {:ok, admission} =
             Repo.transact(fn ->
               assert {:ok, _} = Configuration.lock_control()

               admission =
                 blocked_task(fn -> ProcessEvent.perform(job("event_id", receipt.id)) end)

               assert :ok = sweep(grant)
               {:ok, admission}
             end)

    assert :ok = Task.await(admission)

    assert %{rows: [["covered"]]} =
             SQL.query!(Repo, "SELECT disposition FROM inbound_events WHERE id = $1", [
               uuid(receipt.id)
             ])

    account = ctx.support.event.external_account_id
    start = DateTime.to_unix(now)

    assert %{rows: [[^start, 1]]} =
             SQL.query!(
               Repo,
               "SELECT extract(epoch FROM starts_at)::bigint, count FROM support_admission_windows WHERE scope = $1",
               ["synthetic:#{account}:fixture_global"]
             )
  end

  test "purged text-bearing clarifications still consume both clarification slots" do
    {ctx, id, grant} = grounded_reply()
    baseline = run(id)
    marker = "Synthetic clarification marker"

    # Current deterministic clarifications have no stored text. These rows
    # represent the text-bearing clarification shape supported by the schema.
    for _ <- 1..2 do
      clarification = Ash.UUIDv7.generate()

      SQL.query!(
        Repo,
        """
        INSERT INTO support_runs
        SELECT (jsonb_populate_record(NULL::support_runs, to_jsonb(run) ||
          jsonb_build_object('id', $2::uuid, 'turn_ref', $2::uuid, 'decision', 'no_send',
            'evidence_refs', NULL, 'context_digest', NULL, 'typed_decision',
              jsonb_build_object('schema_version', 1, 'decision', 'clarify', 'reason_code', 'ambiguous',
                'locale', 'en-ZA', 'evidence_revision_ids', '[]'::jsonb, 'reply_text', $3::text)))).*
        FROM support_runs run WHERE id = $1
        """,
        [uuid(id), uuid(clarification), marker]
      )
    end

    set_now(ctx, DateTime.add(baseline.finished_at, @cutoff))
    assert :ok = sweep(grant)

    assert %{rows: rows} =
             SQL.query!(
               Repo,
               """
               SELECT id::text FROM support_runs
               WHERE session_id = $1 AND typed_decision->>'decision' = 'clarify' AND retention_state = 'purged'
               """,
               [uuid(baseline.session_id)]
             )

    assert length(rows) == 2

    for [clarification] <- rows do
      assert :error = DecisionTemplates.render(run(clarification).typed_decision, "shadow-v1")
    end

    next = queue(ctx, "help", 1)
    assert :ok = perform(next)
    assert run(next).typed_decision.decision == "handoff"
  end

  test "unresolved inference and original accounting survive cleanup" do
    {ctx, id, grant} = grounded_reply()
    known = attempts(id)
    next = queue(ctx, question(:en), 1)
    configure(ctx, embedding: fn request -> {request, %Req.TransportError{reason: :timeout}} end)

    assert :ok = perform(next)
    assert [[_, "unknown", _, _, "unknown", _, _]] = uncertain = attempts(next)
    assert_no_writes(ctx)

    set_now(ctx, DateTime.add(run(id).finished_at, @cutoff + 1))
    assert :ok = sweep(grant)
    assert run(id).retention_state == :present
    assert attempts(id) == known
    assert attempts(next) == uncertain
  end

  defp await_jobs(grant, deadline) do
    result =
      SQL.query!(
        Repo,
        """
        SELECT state, (meta->>'cron')::boolean, args->>'after_run'
        FROM oban_jobs WHERE args->>'capability' = $1 ORDER BY id
        """,
        [grant]
      ).rows

    if length(result) == 3 and Enum.all?(result, &(hd(&1) == "completed")) do
      result
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(result)
      Process.sleep(20)
      await_jobs(grant, deadline)
    end
  end

  defp approval_audit(revision) do
    SQL.query!(
      Repo,
      """
      SELECT to_jsonb(audit_events) FROM audit_events
      WHERE article_revision_target_id = $1 AND event = 'approve' ORDER BY id
      """,
      [uuid(revision)]
    ).rows
  end

  defp replay_facts(id, receipt_id) do
    SQL.query!(
      Repo,
      """
      SELECT to_jsonb(e), (SELECT count(*) FROM support_runs WHERE session_id = e.session_id),
        (SELECT count(*) FROM outbound_deliveries WHERE session_id = e.session_id),
        (SELECT count(*) FROM inference_runs WHERE support_run_id = $1),
        (SELECT count(*) FROM usage_ledger_entries l JOIN inference_runs i ON i.id = l.inference_run_id
         WHERE i.support_run_id = $1)
      FROM inbound_events e WHERE id = $2
      """,
      [uuid(id), uuid(receipt_id)]
    ).rows
  end

  defp approve(ctx, action, id, occurrence, session \\ nil) do
    token = Ecto.UUID.generate()

    approval = %{
      token: token,
      session: session || ctx.staff.admin,
      target: id,
      occurrence: occurrence
    }

    settings = Application.fetch_env!(:voelgoed_ai, :retention_fixture)
    Application.put_env(:voelgoed_ai, :retention_fixture, Map.put(settings, action, approval))
    token
  end

  defp grounded_reply do
    ctx = setup_faq(:en, "grounded")
    configure(ctx, generation: &response(&1, ctx))
    id = queue(ctx, question(:en))
    assert :ok = perform(id)

    grant = Ecto.UUID.generate()

    set_retention(%{
      capability: grant,
      inbox: Map.take(ctx.support.event, inbox_keys()),
      batch_size: 25
    })

    {ctx, id, grant}
  end

  defp inbox_keys, do: [:installation_ref, :external_account_id, :external_inbox_id]

  defp set_retention(settings) do
    previous = Application.get_env(:voelgoed_ai, :retention_fixture)
    Application.put_env(:voelgoed_ai, :retention_fixture, settings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:voelgoed_ai, :retention_fixture, previous),
        else: Application.delete_env(:voelgoed_ai, :retention_fixture)
    end)
  end

  defp set_now(ctx, now), do: Agent.update(ctx.support.fake, &%{&1 | now: now})

  defp sweep(grant), do: Retention.perform(job("capability", grant))
end
