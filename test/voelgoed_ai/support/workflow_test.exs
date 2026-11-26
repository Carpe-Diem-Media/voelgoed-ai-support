defmodule VoelgoedAi.Support.WorkflowTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Intelligence.AssistantRevision

  alias VoelgoedAi.Support.{
    ActionScope,
    Delivery,
    InboxBinding,
    InboundEvent,
    Ingress,
    Recovery,
    RunProcessing
  }

  alias VoelgoedAi.Support.Workers.{Deliver, ProcessEvent, ProcessRun}

  setup do
    SupportDBCase.setup()
  end

  test "receipt processing denies mismatched worker scope and runs with the qualified scope",
       ctx do
    assert {:ok, id} = Ingress.accept(ctx.event)
    action = Ash.Resource.Info.action(InboundEvent, :process_receipt)
    assert action && action.type == :action

    scope = %ActionScope.Processing{
      action: :process_receipt,
      resource: InboundEvent,
      target: id,
      inbox:
        {ctx.event.installation_ref, ctx.event.external_account_id, ctx.event.external_inbox_id}
    }

    for actor <- [
          nil,
          ctx.operator,
          struct!(ActionScope.Delivery, Map.from_struct(scope)),
          %{scope | target: Ash.UUIDv7.generate()},
          %{scope | inbox: {"forged", 1, 1}}
        ] do
      input = Ash.ActionInput.for_action(InboundEvent, :process_receipt, %{id: id}, actor: actor)
      assert {:error, _} = Ash.run_action(input)
    end

    assert %{rows: [["pending"]]} =
             SQL.query!(Repo, "SELECT disposition FROM inbound_events WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])

    assert :ok = ProcessEvent.perform(%Oban.Job{args: %{"event_id" => id}})

    assert %{rows: [["covered"]]} =
             SQL.query!(Repo, "SELECT disposition FROM inbound_events WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])
  end

  test "the durable receipt produces an accepted fixed reply", ctx do
    assert {:ok, %{id: receipt_id}} = SupportDBCase.signed_receipt(ctx)
    assert :ok = ProcessEvent.perform(%Oban.Job{args: %{"event_id" => receipt_id}})

    revision = ctx.revision.id

    assert %{rows: [[run_id, ^revision, true, true, true, true]]} =
             SQL.query!(
               Repo,
               """
               SELECT r.id::text, r.assistant_revision_id::text,
                      r.ownership_epoch = s.ownership_epoch, r.binding_epoch = b.security_epoch,
                      r.assistant_epoch = a.security_epoch, r.control_epoch = c.security_epoch
               FROM support_runs r
               JOIN support_sessions s ON s.id = r.session_id
               JOIN inbox_bindings b ON b.id = s.binding_id
               JOIN assistants a ON a.id = b.assistant_id
               CROSS JOIN automation_controls c
               WHERE s.conversation_id = $1
               """,
               [ctx.event.conversation_id]
             )

    SupportDBCase.advance_clock(ctx, 2)

    assert :ok = ProcessRun.perform(%Oban.Job{args: %{"run_id" => run_id}})
    assert %{rows: [[delivery_id]]} = SupportDBCase.delivery_rows(ctx, "id::text")
    assert :ok = Deliver.perform(%Oban.Job{args: %{"delivery_id" => delivery_id}})
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [{:reply, destination, "Synthetic fixture", _operation}] = SupportDBCase.writes(ctx)
    assert destination.conversation == ctx.event.conversation_id
  end

  test "a signed request on an unconfigured installation creates no receipt", ctx do
    assert SupportDBCase.signed_request(ctx, & &1, "unconfigured").status == 404

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM inbound_events WHERE message_id = $1", [
               ctx.event.message_id
             ])

    assert [] = SupportDBCase.writes(ctx)
  end

  test "concurrent deliveries of the same signed receipt register one event and one job", ctx do
    assert {:ok, waiter} =
             Repo.transact(fn ->
               assert SupportDBCase.signed_request(ctx, & &1).status == 204

               waiter =
                 VoelgoedAi.SupportFixtures.blocked_task(fn ->
                   SupportDBCase.signed_request(ctx, & &1).status
                 end)

               {:ok, waiter}
             end)

    assert 204 = Task.await(waiter, 5_000)

    assert %{rows: [[id]]} =
             SQL.query!(Repo, "SELECT id::text FROM inbound_events WHERE message_id = $1", [
               ctx.event.message_id
             ])

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = $1", [id])

    assert [] = SupportDBCase.writes(ctx)
  end

  test "a signed replay after admission leaves its run deadline and charges unchanged", ctx do
    assert {:ok, %{id: id}} = SupportDBCase.signed_receipt(ctx)
    assert :ok = RunProcessing.process_event(id)
    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
    account = "synthetic:#{ctx.event.external_account_id}:%"

    assert %{rows: [[deadline, 6]]} =
             SQL.query!(
               Repo,
               """
               SELECT deadline_at, (SELECT sum(count)::bigint FROM support_admission_windows WHERE scope LIKE $2)
               FROM support_runs WHERE session_id = $1
               """,
               [session, account]
             )

    SupportDBCase.advance_clock(ctx, 44)
    assert {:ok, %{id: ^id}} = SupportDBCase.signed_receipt(ctx)
    assert :ok = RunProcessing.process_event(id)

    assert %{rows: [[^deadline, 6]]} =
             SQL.query!(
               Repo,
               """
               SELECT deadline_at, (SELECT sum(count)::bigint FROM support_admission_windows WHERE scope LIKE $2)
               FROM support_runs WHERE session_id = $1
               """,
               [session, account]
             )

    assert [] = SupportDBCase.writes(ctx)
  end

  test "restoring global control cannot replay a pending public reply", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.disable_automation(ctx)
    SupportDBCase.enable_automation(ctx)
    assert :ok = Delivery.deliver(id)
    assert :ok = Recovery.sweep()
    assert %{rows: [["cancelled", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "an unassigned pending conversation never admits a run", ctx do
    Agent.update(ctx.fake, &%{&1 | observation: %{&1.observation | assignee: :unassigned}})
    assert {:ok, id} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(id)

    assert %{rows: [["triage", "scope_denied"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(id)]
             )

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM support_runs WHERE session_id = $1", [
               Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
             ])

    assert [] = SupportDBCase.writes(ctx)
  end

  test "an out-of-order receipt is batched by verified history without moving the hard cutoff",
       ctx do
    assert {:ok, first} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(first)
    SupportDBCase.advance_clock(ctx, 4)

    older = %{
      ctx.event
      | message_id: ctx.event.message_id + 1,
        received_at: DateTime.add(ctx.event.received_at, 4)
    }

    Agent.update(ctx.fake, fn state ->
      [first] = state.history
      %{state | history: [%{first | id: older.message_id}, first]}
    end)

    assert {:ok, late} = Ingress.accept(older)
    assert :ok = RunProcessing.process_event(late)
    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert %{rows: [[run, cutoff, deadline]]} =
             SQL.query!(
               Repo,
               "SELECT id::text, batch_cutoff_at, deadline_at FROM support_runs WHERE session_id = $1",
               [session]
             )

    assert cutoff == ctx.event.received_at |> DateTime.add(5) |> DateTime.to_naive()
    assert deadline == ctx.event.received_at |> DateTime.add(45) |> DateTime.to_naive()
    assert :ok = RunProcessing.process_run(run)
    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "state")

    SupportDBCase.advance_clock(ctx, 1)
    assert :ok = RunProcessing.process_run(run)

    assert %{rows: [[^late, 0], [^first, 1]]} =
             SQL.query!(
               Repo,
               "SELECT event_id::text, position FROM run_inputs WHERE run_id = $1 ORDER BY position",
               [Ecto.UUID.dump!(run)]
             )

    assert %{rows: [["pending"]]} = SupportDBCase.delivery_rows(ctx, "state")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "oversize input is stored as triage with no work or text", ctx do
    assert SupportDBCase.signed_request(ctx, &Map.put(&1, "content", String.duplicate("x", 3001))).status ==
             204

    assert %{rows: [[id, "quarantined", "triage", "oversize"]]} =
             SQL.query!(
               Repo,
               "SELECT id::text, state, disposition, reason_code FROM inbound_events WHERE message_id = $1",
               [ctx.event.message_id]
             )

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = $1", [id])

    assert [] = SupportDBCase.writes(ctx)
  end

  test "the recovery sweep requeues at most 25 stranded receipts per pass", ctx do
    ids =
      for offset <- 1..26 do
        assert {:ok, id} =
                 Ingress.accept(%{ctx.event | message_id: ctx.event.message_id + offset})

        id
      end

    assert %{num_rows: 26} =
             SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'event_id' = ANY($1::text[])", [
               ids
             ])

    assert :ok = Recovery.sweep()

    assert %{rows: [[25]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = ANY($1::text[])",
               [ids]
             )

    assert [] = SupportDBCase.writes(ctx)
  end

  for response <- [:fixed_reply, :handoff] do
    test "a contended session lock cannot admit an overdue #{response} decision", ctx do
      configure_response(ctx, unquote(response))
      assert_overdue_receipt(ctx)
    end
  end

  defp configure_response(_, :fixed_reply), do: nil

  defp configure_response(ctx, :handoff) do
    import VoelgoedAi.SupportFixtures, only: [allow_fixture: 2, draft: 2, invoke: 4]
    revision = draft(ctx.admin, ctx.assistant)
    fixture = Application.fetch_env!(:voelgoed_ai, :support_fixture)
    allow_fixture(ctx.assistant, %{fixture | response_policy: :handoff})

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :edit_draft,
               %{id: revision.id, response_policy: :handoff},
               ctx.admin
             )

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: ctx.revision.id},
               ctx.admin
             )
  end

  defp assert_overdue_receipt(ctx) do
    assert {:ok, event_id} = Ingress.accept(ctx.event)
    SupportDBCase.append_public_input(ctx, ctx.event.message_id + 1)
    assert {:ok, first} = Ingress.accept(%{ctx.event | message_id: ctx.event.message_id + 1})
    assert :ok = RunProcessing.process_event(first)

    assert {:ok, waiter} =
             Repo.transact(fn ->
               SQL.query!(
                 Repo,
                 "SELECT id FROM support_sessions WHERE conversation_id = $1 FOR UPDATE",
                 [ctx.event.conversation_id]
               )

               waiter =
                 VoelgoedAi.SupportFixtures.blocked_task(fn ->
                   RunProcessing.process_event(event_id)
                 end)

               # The parent holds only the session row. A third connection
               # sees the binding lock owned by the worker waiting on it.
               assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} =
                        Task.async(fn ->
                          SQL.query(
                            Repo,
                            "SELECT id FROM inbox_bindings WHERE id = $1 FOR UPDATE NOWAIT",
                            [
                              Ecto.UUID.dump!(ctx.binding_id)
                            ]
                          )
                        end)
                        |> Task.await(5_000)

               SupportDBCase.advance_clock(ctx, 45)
               {:ok, waiter}
             end)

    assert :ok = Task.await(waiter, 5_000)

    assert %{rows: [["triage", "deadline"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(event_id)]
             )

    assert :ok = RunProcessing.process_event(event_id)

    assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
             SupportDBCase.audit_rows(:event_target_id, event_id)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               """
               SELECT count(*) FROM oban_jobs j
               JOIN outbound_deliveries d ON d.id::text = j.args->>'delivery_id'
               WHERE d.session_id = $1 AND d.purpose = 'handoff_status' AND j.worker = $2
               """,
               [Ecto.UUID.dump!(SupportDBCase.session_id(ctx)), inspect(Deliver)]
             )

    assert :ok = Recovery.sweep()

    assert %{rows: [[id, "pending", processed_at, deadline]]} =
             SQL.query!(
               Repo,
               """
               SELECT d.id::text, d.state, e.processed_at, d.deadline_at
               FROM outbound_deliveries d JOIN inbound_events e ON e.session_id = d.session_id
               WHERE e.id = $1 AND d.purpose = 'handoff_status'
               """,
               [Ecto.UUID.dump!(event_id)]
             )

    assert NaiveDateTime.diff(deadline, processed_at, :second) == 300
    assert processed_at == DateTime.to_naive(DateTime.add(ctx.event.received_at, 45))
    assert [["cancelled", "late_input"]] = overdue_runs(ctx)
    assert [] = SupportDBCase.writes(ctx)

    # The route runs with its independent deadline and fetches current state.
    reads = Agent.get(ctx.fake, & &1.conversation_reads)
    assert :ok = Delivery.deliver(id)
    assert :ok = Delivery.deliver(id)
    assert Agent.get(ctx.fake, & &1.conversation_reads) > reads
    assert [{:handoff, _, _}] = SupportDBCase.writes(ctx)
  end

  for failure <- [:audit, :intent, :enqueue] do
    test "overdue handoff rolls back when #{failure} fails", ctx do
      reply = SupportDBCase.prepare_reply(ctx)
      receipt = overdue_input(ctx)

      reject_overdue_write(unquote(failure), fn ->
        case unquote(failure) do
          :enqueue ->
            assert_raise Ash.Error.Unknown, ~r/reject_overdue_fixture/, fn ->
              RunProcessing.process_event(receipt)
            end

          _ ->
            assert {:error, :storage_failure} = RunProcessing.process_event(receipt)
        end
      end)

      assert %{rows: [["pending", nil]]} =
               SQL.query!(
                 Repo,
                 "SELECT disposition, session_id FROM inbound_events WHERE id = $1",
                 [
                   Ecto.UUID.dump!(receipt)
                 ]
               )

      assert [] = SupportDBCase.audit_rows(:event_target_id, receipt)

      assert %{rows: [["bot_active", false]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, human_inhibit FROM support_sessions WHERE id = $1",
                 [
                   Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
                 ]
               )

      assert %{rows: [["public_reply", "pending"]]} =
               SupportDBCase.delivery_rows(ctx, "purpose, state")

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT count(*) FROM oban_jobs
                 WHERE args ? 'delivery_id' AND args->>'delivery_id' <> $1
                 """,
                 [reply]
               )

      assert :ok = RunProcessing.process_event(receipt)
      assert :ok = RunProcessing.process_event(receipt)
      assert :ok = Recovery.sweep()
      assert :ok = Delivery.deliver(reply)

      assert SupportDBCase.delivery_rows(ctx, "purpose, state").rows |> Enum.sort() ==
               [["handoff_status", "pending"], ["public_reply", "cancelled"]]

      assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
               SupportDBCase.audit_rows(:event_target_id, receipt)

      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "an overdue shadow route records an inhibit and never posts a reply or status", ctx do
    reply = SupportDBCase.prepare_reply(ctx)

    assert {:ok, _} =
             VoelgoedAi.SupportFixtures.invoke(
               InboxBinding,
               :change_mode,
               %{id: ctx.binding_id, operating_mode: :shadow},
               ctx.admin
             )

    receipt = overdue_input(ctx)
    assert :ok = RunProcessing.process_event(receipt)

    assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
             SupportDBCase.audit_rows(:event_target_id, receipt)

    assert %{rows: [["handoff_pending", true]]} =
             SQL.query!(Repo, "SELECT state, human_inhibit FROM support_sessions WHERE id = $1", [
               Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
             ])

    id = overdue_handoff_id(ctx)
    assert :ok = Delivery.deliver(reply)
    assert :ok = Delivery.deliver(id)
    assert [] = SupportDBCase.writes(ctx)

    assert SupportDBCase.delivery_rows(ctx, "purpose, state, attempt_count").rows |> Enum.sort() ==
             [["handoff_status", "cancelled", 0], ["public_reply", "cancelled", 0]]
  end

  for {change, result} <- [
        {%{status: :resolved}, ["cancelled", "resolved"]},
        {%{status: :open, assignee: :human}, ["sent", "already_human"]},
        {%{status: :pending, assignee: :human}, ["cancelled", "scope_denied"]},
        {%{team: 987}, ["cancelled", "scope_denied"]},
        {%{contact: 6}, ["cancelled", "unavailable"]}
      ] do
    test "an overdue route checks fresh scope and routing with #{inspect(change)}", ctx do
      reply = SupportDBCase.prepare_reply(ctx)
      receipt = overdue_input(ctx)
      assert :ok = RunProcessing.process_event(receipt)
      id = overdue_handoff_id(ctx)

      Agent.update(ctx.fake, fn fake ->
        %{fake | observation: struct!(fake.observation, unquote(Macro.escape(change)))}
      end)

      assert :ok = Delivery.deliver(id)
      assert :ok = Delivery.deliver(reply)

      assert %{rows: [[state, reason, 0]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, reason_code, attempt_count FROM outbound_deliveries WHERE id = $1",
                 [Ecto.UUID.dump!(id)]
               )

      assert [state, reason] == unquote(result)

      assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
               SupportDBCase.audit_rows(:event_target_id, receipt)

      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "an overdue first receipt only records the existing triage audit", ctx do
    assert {:ok, receipt} = Ingress.accept(ctx.event)
    SupportDBCase.advance_clock(ctx, 45)
    assert :ok = RunProcessing.process_event(receipt)
    assert :ok = RunProcessing.process_event(receipt)

    assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
             SupportDBCase.audit_rows(:event_target_id, receipt)

    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "state")
    assert [] = SupportDBCase.writes(ctx)
  end

  for status <- [:human_active, :closed] do
    test "overdue input only audits an existing #{status} session", ctx do
      reply = SupportDBCase.prepare_reply(ctx)

      case unquote(status) do
        :human_active ->
          human = %{ctx.event | kind: :human_outbound, message_id: ctx.event.message_id + 8}
          assert {:ok, _} = Ingress.accept(human)

        :closed ->
          Agent.update(ctx.fake, &put_in(&1.observation.status, :resolved))

          assert SupportDBCase.signed_request(ctx, &Map.put(&1, "event", "conversation_updated")).status ==
                   204

          assert %{rows: [[event]]} =
                   SQL.query!(
                     Repo,
                     """
                     SELECT id::text FROM inbound_events
                     WHERE conversation_id = $1 AND message_id IS NULL
                     """,
                     [ctx.event.conversation_id]
                   )

          assert :ok = RunProcessing.process_event(event)
      end

      receipt = overdue_input(ctx)
      assert :ok = RunProcessing.process_event(receipt)
      assert :ok = Delivery.deliver(reply)

      assert %{rows: [[0]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT count(*) FROM outbound_deliveries d
                 JOIN support_sessions s ON s.id = d.session_id
                 WHERE s.conversation_id = $1 AND d.purpose = 'handoff_status'
                 """,
                 [ctx.event.conversation_id]
               )

      assert [["support_worker", "inbound_event", "missed_deadline", "deadline"]] =
               SupportDBCase.audit_rows(:event_target_id, receipt)

      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "a new receipt at the batch deadline routes without extending the old reply", ctx do
    reply = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.advance_clock(ctx, 43)
    now = VoelgoedAi.Support.ChatwootAdapter.now()
    message = ctx.event.message_id + 1
    SupportDBCase.append_public_input(ctx, message)
    assert {:ok, receipt} = Ingress.accept(%{ctx.event | message_id: message, received_at: now})
    assert :ok = RunProcessing.process_event(receipt)
    id = overdue_handoff_id(ctx)
    assert :ok = RunProcessing.process_event(receipt)
    assert :ok = Delivery.deliver(reply)
    assert :ok = Delivery.deliver(id)
    assert [{:handoff, _, _}] = SupportDBCase.writes(ctx)

    assert %{rows: [[deadline, "cancelled", "late_input"]]} =
             SQL.query!(
               Repo,
               "SELECT deadline_at, state, reason_code FROM outbound_deliveries WHERE id = $1",
               [
                 Ecto.UUID.dump!(reply)
               ]
             )

    assert deadline == DateTime.to_naive(now)
  end

  defp overdue_input(ctx) do
    now = VoelgoedAi.Support.ChatwootAdapter.now()
    message = ctx.event.message_id + 1
    SupportDBCase.append_public_input(ctx, message)
    assert {:ok, receipt} = Ingress.accept(%{ctx.event | message_id: message, received_at: now})
    SupportDBCase.advance_clock(ctx, 45)
    receipt
  end

  defp overdue_handoff_id(ctx) do
    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert %{rows: [[id, "pending"]]} =
             SQL.query!(
               Repo,
               "SELECT id::text, state FROM outbound_deliveries WHERE session_id = $1 AND purpose = 'handoff_status'",
               [session]
             )

    id
  end

  defp overdue_runs(ctx) do
    SQL.query!(Repo, "SELECT state, reason_code FROM support_runs WHERE session_id = $1", [
      Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
    ]).rows
  end

  defp reject_overdue_write(:audit, fun) do
    Process.put({VoelgoedAi.Support.SystemAudit, :reject_audit}, :missed_deadline)

    try do
      fun.()
    after
      Process.delete({VoelgoedAi.Support.SystemAudit, :reject_audit})
    end
  end

  defp reject_overdue_write(failure, fun) do
    {table, check} =
      case failure do
        :intent -> {"outbound_deliveries", "purpose <> 'handoff_status'"}
        :enqueue -> {"oban_jobs", "NOT (args ? 'delivery_id')"}
      end

    SQL.query!(
      Repo,
      "ALTER TABLE #{table} ADD CONSTRAINT reject_overdue_fixture CHECK (#{check}) NOT VALID"
    )

    try do
      fun.()
    after
      SQL.query!(Repo, "ALTER TABLE #{table} DROP CONSTRAINT reject_overdue_fixture")
    end
  end

  test "a run deadline records one audit fact across recovery retries", ctx do
    assert {:ok, receipt} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(receipt)

    assert %{rows: [[id]]} =
             SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [
               Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
             ])

    SupportDBCase.advance_clock(ctx, 46)
    assert :ok = Recovery.run_deadline(id)
    assert :ok = Recovery.run_deadline(id)

    assert [["support_worker", "support_run", "missed_deadline", "deadline"]] =
             SupportDBCase.audit_rows(:run_target_id, id)
  end

  test "failure to audit a receipt deadline rolls back triage", ctx do
    assert {:ok, id} = Ingress.accept(ctx.event)
    SupportDBCase.advance_clock(ctx, 46)

    Process.put({VoelgoedAi.Support.SystemAudit, :reject_audit}, :missed_deadline)
    assert {:error, :storage_failure} = RunProcessing.process_event(id)
    Process.delete({VoelgoedAi.Support.SystemAudit, :reject_audit})

    assert %{rows: [["pending", nil]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, session_id FROM inbound_events WHERE id = $1",
               [
                 Ecto.UUID.dump!(id)
               ]
             )

    assert [] = SupportDBCase.audit_rows(:event_target_id, id)
    assert :ok = RunProcessing.process_event(id)
  end

  for mode <- [:shadow, :assisted] do
    test "#{mode} completes its decision without a delivery", ctx do
      import VoelgoedAi.SupportFixtures, only: [invoke: 4]

      assert {:ok, _} =
               invoke(
                 InboxBinding,
                 :change_mode,
                 %{id: ctx.binding_id, operating_mode: unquote(mode)},
                 ctx.admin
               )

      assert {:ok, receipt} = Ingress.accept(ctx.event)
      assert :ok = RunProcessing.process_event(receipt)
      session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

      assert %{rows: [[run_id]]} =
               SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [
                 session
               ])

      SupportDBCase.advance_clock(ctx, 2)
      assert :ok = RunProcessing.process_run(run_id)

      assert %{rows: [["completed", "no_send"]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, decision FROM support_runs WHERE session_id = $1",
                 [session]
               )

      assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "purpose")
      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "late input transfers coverage on the original deadline and preserves completed history",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)

    late = %{
      ctx.event
      | message_id: ctx.event.message_id + 1,
        received_at: DateTime.add(ctx.event.received_at, 2)
    }

    SupportDBCase.append_public_input(ctx, late.message_id)
    assert {:ok, receipt} = Ingress.accept(late)
    assert :ok = RunProcessing.process_event(receipt)

    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert %{rows: [["completed", "fixed_reply", "queued", true, 2]]} =
             SQL.query!(
               Repo,
               """
               SELECT prior.state, prior.decision, successor.state,
                      prior.deadline_at = successor.deadline_at,
                      (SELECT count(*) FROM run_inputs WHERE run_id = successor.id AND current)
               FROM support_runs successor JOIN support_runs prior ON successor.parent_run_id = prior.id
               WHERE successor.session_id = $1
               """,
               [session]
             )

    assert :ok = Delivery.deliver(id)

    assert %{rows: [["cancelled", "late_input", 0]]} =
             SupportDBCase.delivery_rows(ctx, "state, reason_code, attempt_count")

    assert [] = SupportDBCase.writes(ctx)
  end

  test "two jobs cannot claim one run and the expired generation cannot complete it", ctx do
    assert {:ok, receipt} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(receipt)
    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert %{rows: [[id]]} =
             SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [session])

    SupportDBCase.advance_clock(ctx, 2)
    SupportDBCase.block_next_conversation(ctx, self())
    first = Task.async(fn -> RunProcessing.process_run(id) end)
    assert_receive {:chatwoot_read, worker}, 1_000
    assert :ok = RunProcessing.process_run(id)

    assert %{rows: [["running", 1, 1]]} =
             SQL.query!(
               Repo,
               "SELECT state, attempt_count, claim_generation FROM support_runs WHERE session_id = $1",
               [session]
             )

    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = Recovery.run_deadline(id)
    send(worker, :resume_chatwoot_read)
    assert :ok = Task.await(first)

    assert %{rows: [["queued", 1, 2]]} =
             SQL.query!(
               Repo,
               "SELECT state, attempt_count, claim_generation FROM support_runs WHERE session_id = $1",
               [session]
             )

    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "state")

    assert :ok = RunProcessing.process_run(id)

    assert %{rows: [["completed", 2, 3]]} =
             SQL.query!(
               Repo,
               "SELECT state, attempt_count, claim_generation FROM support_runs WHERE session_id = $1",
               [session]
             )

    assert %{rows: [["pending"]]} = SupportDBCase.delivery_rows(ctx, "state")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "PostgreSQL rejects a second active run for the same session", ctx do
    assert {:ok, receipt} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(receipt)
    session = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :unique_violation, constraint: "support_runs_one_active"}
            }} =
             Repo.transact(fn ->
               SQL.query(
                 Repo,
                 """
                 INSERT INTO support_runs
                 SELECT (jsonb_populate_record(NULL::support_runs,
                         to_jsonb(r) || jsonb_build_object('id', uuidv7(), 'turn_ref', uuidv7()))).*
                 FROM support_runs r WHERE r.session_id = $1 AND r.state = 'queued'
                 """,
                 [session]
               )
             end)
  end

  test "reopening inherits human inhibit and unresolved delivery across generations", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    session_id = SupportDBCase.session_id(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)
    assert {:ok, %{state: :closed}} = Support.close_session(ctx.operator, session_id)

    next = %{ctx.event | message_id: ctx.event.message_id + 1}
    SupportDBCase.append_public_input(ctx, next.message_id)
    assert {:ok, receipt} = Ingress.accept(next)
    assert :ok = RunProcessing.process_event(receipt)

    assert %{rows: [[1, "closed", true], [2, "unverified", true]]} =
             SQL.query!(
               Repo,
               "SELECT generation, state, human_inhibit FROM support_sessions WHERE conversation_id = $1 ORDER BY generation",
               [ctx.event.conversation_id]
             )

    assert %{rows: [["unknown"]]} =
             SQL.query!(Repo, "SELECT state FROM outbound_deliveries WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               """
               SELECT count(*) FROM support_runs r JOIN support_sessions s ON r.session_id = s.id
               WHERE s.conversation_id = $1
               """,
               [ctx.event.conversation_id]
             )

    assert [_] = SupportDBCase.writes(ctx)
  end

  test "explicit return requires a verified assignment and does not replay prior work", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    session_id = SupportDBCase.session_id(ctx)
    human_event = %{ctx.event | kind: :human_outbound, message_id: ctx.event.message_id + 1}
    assert {:ok, _} = Ingress.accept(human_event)
    assert %{rows: [["cancelled"]]} = SupportDBCase.delivery_rows(ctx, "state")

    Agent.update(ctx.fake, &%{&1 | observation: %{&1.observation | assignee: :unassigned}})
    assert {:error, :scope_denied} = Support.return_to_bot(ctx.operator, session_id)
    Agent.update(ctx.fake, &%{&1 | observation: %{&1.observation | assignee: :bot}})
    assert {:ok, %{state: :bot_active}} = Support.return_to_bot(ctx.operator, session_id)

    assert :ok = Delivery.deliver(id)
    assert :ok = Recovery.sweep()
    assert %{rows: [["cancelled", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "return denies a changed ownership epoch while human ownership stays active", ctx do
    SupportDBCase.prepare_reply(ctx)
    session = SupportDBCase.session_id(ctx)

    assert {:ok, _} =
             Ingress.accept(%{
               ctx.event
               | kind: :human_outbound,
                 message_id: ctx.event.message_id + 1
             })

    SupportDBCase.block_next_conversation(ctx, self())
    task = Task.async(fn -> Support.return_to_bot(ctx.operator, session) end)
    assert_receive {:chatwoot_read, worker}, 1_000

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE support_sessions SET ownership_epoch = ownership_epoch + 1 WHERE id = $1 AND state = 'human_active'",
               [Ecto.UUID.dump!(session)]
             )

    send(worker, :resume_chatwoot_read)
    assert {:error, :scope_denied} = Task.await(task)
    assert {:ok, %{state: :bot_active}} = Support.return_to_bot(ctx.operator, session)
  end

  test "locked session samples its clock after waiting on PostgreSQL", ctx do
    SupportDBCase.prepare_reply(ctx)
    session = SupportDBCase.session_id(ctx)

    assert {:ok, {waiter, expected}} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SELECT id FROM support_sessions WHERE id = $1 FOR UPDATE", [
                 Ecto.UUID.dump!(session)
               ])

               waiter =
                 VoelgoedAi.SupportFixtures.blocked_task(fn ->
                   Repo.transact(fn ->
                     VoelgoedAi.Support.Ownership.locked_session(session, fn _, _, now ->
                       {:ok, now}
                     end)
                   end)
                 end)

               SupportDBCase.advance_clock(ctx, 46)
               {:ok, {waiter, VoelgoedAi.Support.ChatwootAdapter.now()}}
             end)

    assert {:ok, ^expected} = Task.await(waiter)
  end

  test "an exact signed replay of an id-less observation creates one receipt and job", ctx do
    event = &Map.put(&1, "event", "conversation_updated")
    assert SupportDBCase.signed_request(ctx, event).status == 204
    assert SupportDBCase.signed_request(ctx, event).status == 204

    assert %{rows: [[receipt]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM inbound_events WHERE conversation_id = $1 AND message_id IS NULL",
               [ctx.event.conversation_id]
             )

    assert %{rows: [[1]]} =
             SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = $1", [
               receipt
             ])

    SupportDBCase.advance_clock(ctx, 1)
    assert SupportDBCase.signed_request(ctx, event).status == 204

    assert %{rows: [[2]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM inbound_events WHERE conversation_id = $1 AND message_id IS NULL",
               [ctx.event.conversation_id]
             )
  end

  test "signed human receipt fences before its job and rolls back on enqueue failure", ctx do
    id = SupportDBCase.prepare_reply(ctx)

    shape = fn payload, sender ->
      Map.merge(payload, %{
        "id" => ctx.event.message_id + 1,
        "message_type" => "outgoing",
        "sender" => sender
      })
    end

    malformed = fn payload ->
      payload |> shape.(%{"type" => "user"}) |> Map.put("id", ctx.event.message_id + 2)
    end

    assert SupportDBCase.signed_request(ctx, malformed).status == 204
    assert %{rows: [["pending", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    human = &shape.(&1, %{"type" => "user", "id" => 82})

    SQL.query!(Repo, """
    ALTER TABLE oban_jobs ADD CONSTRAINT reject_human_fixture_job
      CHECK (NOT (args ? 'event_id')) NOT VALID
    """)

    try do
      assert SupportDBCase.signed_request(ctx, human).status == 500
    after
      SQL.query!(Repo, "ALTER TABLE oban_jobs DROP CONSTRAINT reject_human_fixture_job")
    end

    session_id = Ecto.UUID.dump!(SupportDBCase.session_id(ctx))

    assert %{rows: [[false]]} =
             SQL.query!(Repo, "SELECT human_inhibit FROM support_sessions WHERE id = $1", [
               session_id
             ])

    assert %{rows: [["pending", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    assert SupportDBCase.signed_request(ctx, human).status == 204

    assert %{rows: [[true]]} =
             SQL.query!(Repo, "SELECT human_inhibit FROM support_sessions WHERE id = $1", [
               session_id
             ])

    assert :ok = Delivery.deliver(id)
    assert %{rows: [["cancelled", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "only a current support operator can request a durable handoff", ctx do
    assert {:ok, event_id} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(event_id)
    session_id = SupportDBCase.session_id(ctx)

    assert {:error, :denied} = Support.request_handoff(nil, session_id)
    assert {:error, :denied} = Support.request_handoff(ctx.admin, session_id)

    assert {:error, :denied} =
             Support.request_handoff(
               %{ctx.operator | generation: ctx.operator.generation + 1},
               session_id
             )

    assert {:ok, _} = Support.request_handoff(ctx.operator, session_id)

    assert %{rows: [["handoff_status", "pending"]]} =
             SupportDBCase.delivery_rows(ctx, "purpose, state")

    assert %{rows: [["handoff_pending"]]} =
             SQL.query!(Repo, "SELECT state FROM support_sessions WHERE id = $1", [
               Ecto.UUID.dump!(session_id)
             ])

    assert %{rows: [[delivery_id]]} = SupportDBCase.delivery_rows(ctx, "id::text")
    assert :ok = Deliver.perform(%Oban.Job{args: %{"delivery_id" => delivery_id}})
    assert :ok = Recovery.reconcile(delivery_id)

    assert %{rows: [["handoff_status", "sent"]]} =
             SupportDBCase.delivery_rows(ctx, "purpose, state")

    assert [{:handoff, _, _}] = SupportDBCase.writes(ctx)
  end
end
