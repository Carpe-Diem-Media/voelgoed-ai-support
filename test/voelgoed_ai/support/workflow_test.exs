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

               SupportDBCase.advance_clock(ctx, 46)
               {:ok, waiter}
             end)

    assert :ok = Task.await(waiter, 5_000)

    assert %{rows: [["triage", "deadline"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(event_id)]
             )

    assert [] = SupportDBCase.writes(ctx)
    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "purpose")
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
