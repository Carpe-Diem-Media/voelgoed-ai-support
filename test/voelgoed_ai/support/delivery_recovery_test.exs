defmodule VoelgoedAi.Support.DeliveryRecoveryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}

  alias VoelgoedAi.Support.{
    ActionScope,
    Delivery,
    Ingress,
    OutboundDelivery,
    Recovery,
    RunProcessing
  }

  alias VoelgoedAi.Support.ChatwootAdapter.Message

  setup do
    SupportDBCase.setup()
  end

  test "delivery and reconciliation deny crossed roles, wrong targets and wrong inboxes", ctx do
    id = SupportDBCase.prepare_reply(ctx)

    inbox =
      {ctx.event.installation_ref, ctx.event.external_account_id, ctx.event.external_inbox_id}

    for {action, wrong_kind, kind} <- [
          {:deliver_intent, ActionScope.Reconciliation, ActionScope.Delivery},
          {:reconcile_intent, ActionScope.Delivery, ActionScope.Reconciliation}
        ] do
      scope = struct!(kind, action: action, resource: OutboundDelivery, inbox: inbox, target: id)

      for actor <- [
            struct!(wrong_kind, Map.from_struct(scope)),
            %{scope | inbox: {"wrong-installation", 21, 43}},
            %{scope | target: Ash.UUIDv7.generate()}
          ] do
        input = Ash.ActionInput.for_action(OutboundDelivery, action, %{id: id}, actor: actor)
        assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)
      end
    end

    assert %{rows: [["pending", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  for failure <- [:timeout, :reset, :server_error, :redirect, :malformed_success, :forbidden] do
    test "#{failure} after adapter entry leaves one ambiguous attempt", ctx do
      id = SupportDBCase.prepare_reply(ctx)
      SupportDBCase.write_mode(ctx, unquote(failure))

      assert :ok = Delivery.deliver(id)
      assert :ok = Delivery.deliver(id)

      assert %{rows: [["unknown", 1, "ambiguous_write"]]} =
               SupportDBCase.delivery_rows(ctx, "state, attempt_count, uncertainty_reason")

      assert [_] = SupportDBCase.writes(ctx)
    end
  end

  test "a binding auth failure inhibits writes until a successful read-only probe", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :forbidden)
    assert :ok = Delivery.deliver(id)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    another = SupportDBCase.next_conversation(ctx, 1)
    another_id = SupportDBCase.prepare_reply(another)
    SupportDBCase.write_mode(ctx, :accepted)
    assert :ok = Delivery.deliver(another_id)

    assert %{rows: [["cancelled", 0]]} =
             SupportDBCase.delivery_rows(another, "state, attempt_count")

    assert [_] = SupportDBCase.writes(ctx)

    SupportDBCase.advance_clock(ctx, 61)
    probe = SupportDBCase.next_conversation(ctx, 2)
    probe_id = SupportDBCase.prepare_reply(probe)
    competing = SupportDBCase.next_conversation(ctx, 3)
    competing_id = SupportDBCase.prepare_reply(competing)
    SupportDBCase.next_conversation(ctx, 2)

    SupportDBCase.block_next_conversation(ctx, self())
    task = Task.async(fn -> Delivery.deliver(probe_id) end)
    assert_receive {:chatwoot_read, worker}, 1_000

    reads = read_count(ctx)
    assert :ok = Delivery.deliver(competing_id)
    assert read_count(ctx) == reads

    assert %{rows: [["cancelled", 0]]} =
             SupportDBCase.delivery_rows(competing, "state, attempt_count")

    send(worker, :resume_chatwoot_read)
    assert :ok = Task.await(task)

    assert %{rows: [["cancelled", 0]]} =
             SupportDBCase.delivery_rows(probe, "state, attempt_count")

    assert [_] = SupportDBCase.writes(ctx)

    fresh = SupportDBCase.next_conversation(ctx, 4)
    fresh_id = SupportDBCase.prepare_reply(fresh)
    assert :ok = Delivery.deliver(fresh_id)
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(fresh, "state, attempt_count")
    assert [_, _] = SupportDBCase.writes(ctx)
  end

  test "five consecutive transient failures open the binding and a failed probe keeps it open",
       ctx do
    SupportDBCase.write_mode(ctx, :timeout)

    for number <- 1..5 do
      conversation = SupportDBCase.next_conversation(ctx, number)
      id = SupportDBCase.prepare_reply(conversation)
      assert :ok = Delivery.deliver(id)

      assert %{rows: [["unknown", 1]]} =
               SupportDBCase.delivery_rows(conversation, "state, attempt_count")
    end

    sixth = SupportDBCase.next_conversation(ctx, 6)
    id = SupportDBCase.prepare_reply(sixth)
    assert :ok = Delivery.deliver(id)

    assert %{rows: [["cancelled", 0]]} =
             SupportDBCase.delivery_rows(sixth, "state, attempt_count")

    assert length(SupportDBCase.writes(ctx)) == 5

    SupportDBCase.advance_clock(ctx, 61)
    probe = SupportDBCase.next_conversation(ctx, 7)
    probe_id = SupportDBCase.prepare_reply(probe)
    Agent.update(ctx.fake, &Map.put(&1, :conversation_result, {:error, :unavailable}))
    assert :ok = Delivery.deliver(probe_id)
    Agent.update(ctx.fake, &Map.delete(&1, :conversation_result))

    still_open = SupportDBCase.next_conversation(ctx, 8)
    still_open_id = SupportDBCase.prepare_reply(still_open)
    reads = read_count(ctx)
    assert :ok = Delivery.deliver(still_open_id)
    assert read_count(ctx) == reads

    assert %{rows: [["cancelled", 0]]} =
             SupportDBCase.delivery_rows(still_open, "state, attempt_count")

    assert length(SupportDBCase.writes(ctx)) == 5
  end

  test "qualified no-effect before dispatch differs from an absent read-back", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :unissued)
    assert :ok = Delivery.deliver(id)

    assert %{rows: [["failed", "no_effect"]]} =
             SupportDBCase.delivery_rows(ctx, "state, reason_code")

    assert :ok = Recovery.reconcile(id)
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "a handoff exhausts three unavailable reads and stays inhibited", ctx do
    id = prepare_handoff(ctx)
    before = read_count(ctx)
    Agent.update(ctx.fake, &Map.put(&1, :conversation_result, {:error, :unavailable}))

    assert :ok = Delivery.deliver(id)
    assert :ok = Delivery.deliver(id)
    assert read_count(ctx) == before + 1
    SupportDBCase.advance_clock(ctx, 1)
    assert :ok = Delivery.deliver(id)
    SupportDBCase.advance_clock(ctx, 3)
    assert :ok = Delivery.deliver(id)
    assert :ok = Delivery.deliver(id)
    assert read_count(ctx) == before + 3

    assert %{rows: [["failed", "read_exhausted", 3, 0]]} =
             handoff_rows(ctx, "state, reason_code, read_count, attempt_count")

    assert_handoff_inhibited(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "handoff past its five-minute deadline is triaged without another read", ctx do
    id = prepare_handoff(ctx)
    before = read_count(ctx)
    Agent.update(ctx.fake, &Map.put(&1, :conversation_result, {:error, :unavailable}))
    assert :ok = Delivery.deliver(id)
    SupportDBCase.advance_clock(ctx, 300)
    assert :ok = Recovery.delivery_deadline(id)
    assert :ok = Delivery.deliver(id)
    assert read_count(ctx) == before + 1

    assert %{rows: [["failed", "deadline", 0]]} =
             handoff_rows(ctx, "state, reason_code, attempt_count")

    assert_handoff_inhibited(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  for {override, expected, reason} <- [
        {%{status: :open, assignee: :human}, "sent", "already_human"},
        {%{team: 987}, "cancelled", "scope_denied"},
        {%{assignee: :unassigned}, "cancelled", "scope_denied"},
        {%{status: :resolved}, "cancelled", "resolved"}
      ] do
    test "handoff preflight with #{inspect(override)} issues no write", ctx do
      id = prepare_handoff(ctx)

      Agent.update(
        ctx.fake,
        &%{&1 | observation: struct!(&1.observation, unquote(Macro.escape(override)))}
      )

      assert :ok = Delivery.deliver(id)

      assert %{rows: [[unquote(expected), unquote(reason), 0]]} =
               handoff_rows(ctx, "state, reason_code, attempt_count")

      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "a resolved observation after handoff POST closes locally and preserves uncertainty",
       ctx do
    id = prepare_handoff(ctx)

    Agent.update(
      ctx.fake,
      &Map.put(&1, :handoff_observation, %{&1.observation | status: :resolved})
    )

    assert :ok = Delivery.deliver(id)
    assert :ok = Recovery.reconcile(id)
    assert :ok = Delivery.deliver(id)
    assert %{rows: [["unknown", 1]]} = handoff_rows(ctx, "state, attempt_count")
    assert %{rows: [["closed"]]} = session_state(ctx, "state")
    assert [{:handoff, _, _}] = SupportDBCase.writes(ctx)
  end

  test "a closed reply window still permits qualified status handoff", ctx do
    id = prepare_handoff(ctx)
    Agent.update(ctx.fake, &%{&1 | observation: %{&1.observation | can_reply: false}})
    assert :ok = Delivery.deliver(id)
    assert %{rows: [["sent", 1]]} = handoff_rows(ctx, "state, attempt_count")
    assert [{:handoff, _, _}] = SupportDBCase.writes(ctx)
  end

  defp prepare_handoff(ctx) do
    SupportDBCase.prepare_reply(ctx)
    assert {:ok, _} = Support.request_handoff(ctx.operator, SupportDBCase.session_id(ctx))

    assert %{rows: [["cancelled", "public_reply"]]} =
             SupportDBCase.delivery_rows(ctx, "state, purpose")
             |> then(fn result ->
               %{
                 result
                 | rows:
                     Enum.filter(result.rows, fn [_, purpose] -> purpose == "public_reply" end)
               }
             end)

    assert %{rows: [[id]]} = handoff_rows(ctx, "id::text")
    id
  end

  defp handoff_rows(ctx, select) do
    SQL.query!(
      Repo,
      "SELECT #{select} FROM outbound_deliveries WHERE session_id = $1 AND purpose = 'handoff_status'",
      [Ecto.UUID.dump!(SupportDBCase.session_id(ctx))]
    )
  end

  defp session_state(ctx, select) do
    SQL.query!(Repo, "SELECT #{select} FROM support_sessions WHERE id = $1", [
      Ecto.UUID.dump!(SupportDBCase.session_id(ctx))
    ])
  end

  defp assert_handoff_inhibited(ctx) do
    assert %{rows: [["handoff_pending", true]]} = session_state(ctx, "state, human_inhibit")
  end

  defp read_count(ctx), do: Agent.get(ctx.fake, &Map.get(&1, :conversation_reads, 0))

  for invalid <- [:destination, :sender, :visibility, :equal_text] do
    test "#{invalid} cannot prove acceptance on read-back", ctx do
      id = SupportDBCase.prepare_reply(ctx)
      SupportDBCase.write_mode(ctx, :timeout)
      assert :ok = Delivery.deliver(id)
      assert [{:reply, destination, text, operation}] = SupportDBCase.writes(ctx)

      Agent.update(ctx.fake, fn state ->
        message = %Message{id: 900, sender: :bot, visibility: :public, operation: operation}

        {message, destination} =
          case unquote(invalid) do
            :destination -> {message, %{destination | conversation: destination.conversation + 1}}
            :sender -> {%{message | sender: :human}, destination}
            :visibility -> {%{message | visibility: :private}, destination}
            :equal_text -> {Map.put(%{message | operation: nil}, :text, text), destination}
          end

        state
        |> Map.put(:history_destination, destination)
        |> Map.update!(:history, &(&1 ++ [message]))
      end)

      assert :ok = Recovery.reconcile(id)

      assert %{rows: [["unknown", nil]]} =
               SupportDBCase.delivery_rows(ctx, "state, external_message_id")

      assert [_] = SupportDBCase.writes(ctx)
    end
  end

  test "abandonment wins over an in-flight successful read-back", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :commit_then_timeout)
    assert :ok = Delivery.deliver(id)
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :history_barrier, parent))
    task = Task.async(fn -> Recovery.reconcile(id) end)
    assert_receive {:chatwoot_history, worker}, 1_000

    assert {:ok, %{state: :abandoned}} =
             Support.abandon_delivery(ctx.operator, id, :acknowledge_uncertainty)

    send(worker, :resume_chatwoot_history)
    assert :ok = Task.await(task)

    assert %{rows: [["abandoned", nil]]} =
             SupportDBCase.delivery_rows(ctx, "state, external_message_id")

    assert [_] = SupportDBCase.writes(ctx)
  end

  test "an earlier successful read cannot settle after a newer reservation", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :commit_then_timeout)
    assert :ok = Delivery.deliver(id)
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :history_barrier, parent))
    early = Task.async(fn -> Recovery.reconcile(id) end)
    assert_receive {:chatwoot_history, worker}, 1_000

    Agent.update(
      ctx.fake,
      &Map.update!(&1, :history, fn history ->
        Enum.reject(history, fn m -> m.sender == :bot end)
      end)
    )

    SupportDBCase.advance_clock(ctx, 1)
    assert :ok = Recovery.reconcile(id)
    send(worker, :resume_chatwoot_history)
    assert :ok = Task.await(early)

    assert %{rows: [["unknown", 2, nil]]} =
             SupportDBCase.delivery_rows(ctx, "state, read_count, external_message_id")

    assert [_] = SupportDBCase.writes(ctx)
  end

  test "reconciliation expiry does not reserve a read", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :commit_then_timeout)
    assert :ok = Delivery.deliver(id)
    SupportDBCase.advance_clock(ctx, 300)
    assert :ok = Recovery.reconcile(id)

    assert %{rows: [["unknown", "read_exhausted", 0]]} =
             SupportDBCase.delivery_rows(ctx, "state, reason_code, read_count")

    assert [_] = SupportDBCase.writes(ctx)
  end

  test "a stale worker cannot dispatch using a replacement worker's claim", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_after_claim(ctx, self())
    first = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, original}, 1_000

    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = Recovery.delivery_deadline(id)
    SupportDBCase.block_after_claim(ctx, self())
    second = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, replacement}, 1_000

    send(original, :resume_delivery_claim)
    assert :ok = Task.await(first)
    assert [] = SupportDBCase.writes(ctx)

    send(replacement, :resume_delivery_claim)
    assert :ok = Task.await(second)
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "dispatch refuses a live lease that cannot cover its request margin", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_after_claim(ctx, self())
    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, worker}, 1_000

    SQL.query!(
      Repo,
      "UPDATE outbound_deliveries SET lease_expires_at = last_read_at + interval '500 milliseconds' WHERE id = $1",
      [Ecto.UUID.dump!(id)]
    )

    send(worker, :resume_delivery_claim)
    assert :ok = Task.await(task)

    assert %{rows: [["cancelled", 0, nil]]} =
             SupportDBCase.delivery_rows(ctx, "state, attempt_count, dispatch_authorized_at")

    assert [] = SupportDBCase.writes(ctx)
  end

  for {barrier, signal, committed?} <- [
        {:before_commit_barrier, :chatwoot_before_commit, false},
        {:write_barrier, :chatwoot_write, true}
      ] do
    test "killing a worker at #{signal} keeps an authorized attempt uncertain", ctx do
      id = SupportDBCase.prepare_reply(ctx)
      parent = self()
      Agent.update(ctx.fake, &Map.put(&1, unquote(barrier), parent))
      {pid, monitor} = spawn_monitor(fn -> Delivery.deliver(id) end)
      assert_receive {unquote(signal), ^pid}, 1_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

      SupportDBCase.advance_clock(ctx, 6)
      assert :ok = Recovery.delivery_deadline(id)
      assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
      assert :ok = Delivery.deliver(id)
      assert :ok = Recovery.reconcile(id)
      state = if unquote(committed?), do: "sent", else: "unknown"
      assert %{rows: [[^state, 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
      assert [_] = SupportDBCase.writes(ctx)
    end
  end

  test "a worker lost before authorization can be recovered by sweep after losing its expiry jobs",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_after_claim(ctx, self())
    {pid, monitor} = spawn_monitor(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, ^pid}, 1_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    assert %{num_rows: 1} =
             SQL.query!(
               Repo,
               "UPDATE oban_jobs SET state = 'discarded', discarded_at = now() WHERE worker LIKE '%Deliver' AND args->>'delivery_id' = $1",
               [id]
             )

    assert %{num_rows: count} =
             SQL.query!(
               Repo,
               "DELETE FROM oban_jobs WHERE worker LIKE '%Sweep' AND args->>'delivery_id' = $1",
               [id]
             )

    assert count >= 2
    assert [] = SupportDBCase.writes(ctx)

    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = VoelgoedAi.Support.Workers.Sweep.perform(%Oban.Job{args: %{}})
    assert %{rows: [["pending", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert :ok = Delivery.deliver(id)
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "a worker lost after authorization and before POST stays unknown", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :authorization_barrier, parent))
    {pid, monitor} = spawn_monitor(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_authorized, ^pid}, 1_000

    assert %{rows: [["sending", 1, %NaiveDateTime{}]]} =
             SupportDBCase.delivery_rows(ctx, "state, attempt_count, dispatch_authorized_at")

    assert [] = SupportDBCase.writes(ctx)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = Recovery.delivery_deadline(id)
    assert :ok = Delivery.deliver(id)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "a committed remote write with a lost response remains unknown until qualified read-back",
       ctx do
    delivery_id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :commit_then_timeout)
    assert :ok = Delivery.deliver(delivery_id)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert :ok = Delivery.deliver(delivery_id)
    assert [_] = SupportDBCase.writes(ctx)

    assert :ok = Recovery.reconcile(delivery_id)
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "unknown blocks a new input and abandonment requires an audited operator decision", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)

    assert {:ok, receipt} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(receipt)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    SupportDBCase.append_public_input(ctx, ctx.event.message_id + 1)

    assert {:ok, event_id} =
             Ingress.accept(%{ctx.event | message_id: ctx.event.message_id + 1})

    assert :ok = RunProcessing.process_event(event_id)

    assert %{rows: [["triage", "awaiting_operator"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(event_id)]
             )

    assert {:error, :denied} = Support.abandon_delivery(ctx.admin, id, :acknowledge_uncertainty)

    assert {:ok, %{state: :abandoned, uncertainty_reason: :ambiguous_write}} =
             Support.abandon_delivery(ctx.operator, id, :acknowledge_uncertainty)

    assert %{rows: [["abandon_delivery", "local_operator"]]} =
             SQL.query!(
               Repo,
               "SELECT event, reason_code FROM audit_events WHERE delivery_target_id = $1",
               [Ecto.UUID.dump!(id)]
             )

    assert :ok = Delivery.deliver(id)
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "sweep fences an expired worker even while its write callback is blocked", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_next_write(ctx, self())
    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:chatwoot_write, worker}, 1_000
    assert %{rows: [["sending", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = Recovery.sweep()
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    send(worker, :resume_chatwoot_write)
    assert :ok = Task.await(task)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert :ok = Recovery.reconcile(id)
    assert %{rows: [["sent", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "an expired writer cannot settle even before recovery starts", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_next_write(ctx, self())
    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:chatwoot_write, worker}, 1_000
    SupportDBCase.advance_clock(ctx, 6)
    send(worker, :resume_chatwoot_write)
    assert :ok = Task.await(task)

    assert %{rows: [["sending", 1, nil]]} =
             SupportDBCase.delivery_rows(ctx, "state, attempt_count, external_message_id")

    assert :ok = Recovery.delivery_deadline(id)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "a restored control cannot authorize a handoff claimed under its old epoch", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    assert {:ok, _} = Support.request_handoff(ctx.operator, SupportDBCase.session_id(ctx))

    assert %{rows: [[handoff_id]]} =
             SQL.query!(
               Repo,
               "SELECT d.id::text FROM outbound_deliveries d JOIN outbound_deliveries r ON r.session_id = d.session_id WHERE r.id = $1 AND d.purpose = 'handoff_status'",
               [Ecto.UUID.dump!(id)]
             )

    SupportDBCase.block_after_claim(ctx, self())
    task = Task.async(fn -> Delivery.deliver(handoff_id) end)
    assert_receive {:delivery_claimed, worker}, 1_000

    SupportDBCase.disable_automation(ctx)
    SupportDBCase.enable_automation(ctx)
    send(worker, :resume_delivery_claim)
    assert :ok = Task.await(task)

    assert %{rows: [["cancelled", 0]]} =
             SQL.query!(
               Repo,
               "SELECT state, attempt_count FROM outbound_deliveries WHERE id = $1",
               [Ecto.UUID.dump!(handoff_id)]
             )

    assert [] = SupportDBCase.writes(ctx)
  end

  test "verified history suppresses a reply if a newer input's webhook was missed", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.append_public_input(ctx, ctx.event.message_id - 1)
    assert :ok = Delivery.deliver(id)

    assert %{rows: [["cancelled", "history_changed"]]} =
             SupportDBCase.delivery_rows(ctx, "state, reason_code")

    assert [] = SupportDBCase.writes(ctx)
  end

  test "disabling the global epoch during preflight cancels the write", ctx do
    delivery_id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_next_conversation(ctx, self())
    delivery = Task.async(fn -> Delivery.deliver(delivery_id) end)

    assert_receive {:chatwoot_read, worker}, 1_000
    SupportDBCase.disable_automation(ctx)
    send(worker, :resume_chatwoot_read)
    assert :ok = Task.await(delivery)
    assert %{rows: [["cancelled", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "disabling the binding after claim cancels the public write", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_after_claim(ctx, self())
    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, worker}, 1_000

    assert {:ok, _} =
             VoelgoedAi.SupportFixtures.invoke(
               VoelgoedAi.Support.InboxBinding,
               :disable,
               %{id: ctx.binding_id},
               ctx.admin
             )

    send(worker, :resume_delivery_claim)
    assert :ok = Task.await(task)
    assert %{rows: [["cancelled", 0]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "the operator projection exposes only internal intent references and safe reasons", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    session = SupportDBCase.session_id(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)
    assert {:error, :denied} = Support.reconciliation_projection(ctx.admin, session)

    assert {:error, :scope_denied} =
             Support.reconciliation_projection(ctx.operator, Ash.UUIDv7.generate())

    assert {:ok,
            [
              %{
                id: ^id,
                session_id: ^session,
                state: :unknown,
                purpose: :public_reply,
                attempt_count: 1,
                reason_code: nil,
                uncertainty_reason: :ambiguous_write,
                correlation_id: correlation
              } = row
            ]} = Support.reconciliation_projection(ctx.operator, session)

    assert {:ok, _} = Ecto.UUID.cast(correlation)
    assert map_size(row) == 8
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "an ambiguous write emits one alert with only internal references and a safe reason",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)
    subscriber = self()
    handler = {__MODULE__, make_ref()}
    signal = [:voelgoed_ai, :support, :delivery_attention]

    assert :ok = :telemetry.attach(handler, signal, &__MODULE__.forward_signal/4, subscriber)
    on_exit(fn -> :telemetry.detach(handler) end)

    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)
    assert_receive {^signal, %{count: 1}, metadata}

    assert %{
             delivery_id: ^id,
             correlation_id: correlation,
             state: :unknown,
             reason: :ambiguous_write
           } =
             metadata

    assert {:ok, _} = Ecto.UUID.cast(correlation)
    assert map_size(metadata) == 4

    assert :ok = Delivery.deliver(id)
    refute_received {^signal, _, _}
    assert [_] = SupportDBCase.writes(ctx)
  end

  def forward_signal(event, measurements, metadata, destination) do
    send(destination, {event, measurements, metadata})
  end
end
