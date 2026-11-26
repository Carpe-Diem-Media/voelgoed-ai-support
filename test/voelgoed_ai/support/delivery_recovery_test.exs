defmodule VoelgoedAi.Support.DeliveryRecoveryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Governance.AuditEvent

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

      assert [["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"]] =
               SupportDBCase.audit_rows(:delivery_target_id, id)
    end
  end

  test "failure to audit UNKNOWN preserves the authorized write for recovery", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)

    Process.put({VoelgoedAi.Support.SystemAudit, :reject_audit}, :delivery_unknown)
    assert {:error, :storage_failure} = Delivery.deliver(id)
    Process.delete({VoelgoedAi.Support.SystemAudit, :reject_audit})

    assert %{rows: [["sending", 1, true]]} =
             SupportDBCase.delivery_rows(
               ctx,
               "state, attempt_count, dispatch_authorized_at IS NOT NULL"
             )

    assert [] = SupportDBCase.audit_rows(:delivery_target_id, id)
    SupportDBCase.advance_clock(ctx, 6)
    assert :ok = Recovery.delivery_deadline(id)

    assert [["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"]] =
             SupportDBCase.audit_rows(:delivery_target_id, id)

    assert [_] = SupportDBCase.writes(ctx)
  end

  test "system history projects exact targets for current staff and scoped reconciliation", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)

    args = %{target_kind: :outbound_delivery, id: id}

    {installation, account, inbox} =
      {ctx.event.installation_ref, ctx.event.external_account_id, ctx.event.external_inbox_id}

    scope = %ActionScope.Reconciliation{
      action: :system_history,
      resource: AuditEvent,
      target: {:outbound_delivery, id},
      inbox: {installation, account, inbox}
    }

    invoke = &VoelgoedAi.SupportFixtures.invoke(AuditEvent, :system_history, args, &1)

    assert {:ok, [row]} = invoke.(ctx.operator)

    assert %{
             actor_kind: :support_worker,
             target_kind: :outbound_delivery,
             target_id: ^id,
             event: :delivery_unknown,
             reason_code: :ambiguous_write
           } = row

    assert Enum.sort(Map.keys(row)) ==
             Enum.sort([
               :id,
               :actor_kind,
               :target_kind,
               :target_id,
               :event,
               :reason_code,
               :correlation_id,
               :occurred_at
             ])

    assert {:ok, [^row]} = invoke.(ctx.admin)
    assert {:ok, [^row]} = invoke.(scope)

    # Another delivery's system row and a staff row on this delivery must not
    # appear in this target's system history.
    other = SupportDBCase.next_conversation(ctx, 2)
    other_id = SupportDBCase.prepare_reply(other)
    assert :ok = Delivery.deliver(other_id)
    assert [_] = SupportDBCase.audit_rows(:delivery_target_id, other_id)

    assert {:ok, %{state: :abandoned}} =
             Support.abandon_delivery(ctx.operator, id, :acknowledge_uncertainty)

    assert [_, _] = SupportDBCase.audit_rows(:delivery_target_id, id)
    assert {:ok, [^row]} = invoke.(ctx.operator)
    assert {:ok, [^row]} = invoke.(scope)

    for actor <- [
          nil,
          %{ctx.operator | generation: ctx.operator.generation + 1},
          %{scope | target: {:outbound_delivery, Ash.UUIDv7.generate()}},
          %{scope | inbox: {installation, account, inbox + 1}},
          %{scope | inbox: nil},
          struct!(ActionScope.Processing, Map.from_struct(scope))
        ] do
      assert {:error, _} = invoke.(actor)
    end

    attrs = %{
      actor_kind: :support_worker,
      target_kind: :outbound_delivery,
      delivery_target_id: id,
      event: :delivery_unknown,
      reason_code: :ambiguous_write,
      correlation_id: Ash.UUIDv7.generate()
    }

    assert %Ash.Changeset{valid?: true} =
             Ash.Changeset.for_create(AuditEvent, :append_system, attrs)

    assert %Ash.Changeset{valid?: false, errors: [%{field: :actor_kind}]} =
             Ash.Changeset.for_create(AuditEvent, :append_system, %{attrs | actor_kind: :staff})

    for actor <- [
          nil,
          ctx.admin,
          ctx.operator,
          scope,
          %VoelgoedAi.Support.WorkStore{ref: make_ref()}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               AuditEvent
               |> Ash.Query.for_read(:system_rows, args, actor: actor)
               |> Ash.read()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(AuditEvent, attrs, action: :append_system, actor: actor)
    end

    assert {:error, %Postgrex.Error{postgres: %{constraint: "audit_events_actor_reference"}}} =
             SQL.query(
               Repo,
               "UPDATE audit_events SET actor_staff_id = $1 WHERE id = $2",
               [Ecto.UUID.dump!(ctx.admin.id), Ecto.UUID.dump!(row.id)]
             )
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

    assert [["support_worker", "outbound_delivery", "handoff_failed", "read_exhausted"]] =
             SupportDBCase.audit_rows(:delivery_target_id, id)

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

    assert [["support_worker", "outbound_delivery", "handoff_failed", "deadline"]] =
             SupportDBCase.audit_rows(:delivery_target_id, id)

    assert_handoff_inhibited(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "failure to audit a handoff deadline leaves the intent pending", ctx do
    id = prepare_handoff(ctx)
    SupportDBCase.advance_clock(ctx, 300)

    Process.put({VoelgoedAi.Support.SystemAudit, :reject_audit}, :handoff_failed)
    assert {:error, :storage_failure} = Recovery.delivery_deadline(id)
    Process.delete({VoelgoedAi.Support.SystemAudit, :reject_audit})

    assert %{rows: [["pending", nil]]} = handoff_rows(ctx, "state, reason_code")
    assert [] = SupportDBCase.audit_rows(:delivery_target_id, id)
    assert :ok = Recovery.delivery_deadline(id)
  end

  test "an expired handoff claim without dispatch records one deadline failure", ctx do
    id = prepare_handoff(ctx)
    SupportDBCase.block_after_claim(ctx, self())
    worker = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_claimed, pid}, 1_000

    SupportDBCase.advance_clock(ctx, 300)
    assert :ok = Recovery.delivery_deadline(id)
    send(pid, :resume_delivery_claim)
    assert :ok = Task.await(worker)
    assert :ok = Recovery.delivery_deadline(id)

    assert %{rows: [["cancelled", 0]]} = handoff_rows(ctx, "state, attempt_count")

    assert [["support_worker", "outbound_delivery", "handoff_failed", "deadline"]] =
             SupportDBCase.audit_rows(:delivery_target_id, id)

    assert [] = SupportDBCase.writes(ctx)
  end

  test "an uncertain handoff records recovery failure without changing UNKNOWN", ctx do
    id = prepare_handoff(ctx)
    Agent.update(ctx.fake, &Map.put(&1, :handoff_observation, &1.observation))
    assert :ok = Delivery.deliver(id)
    SupportDBCase.advance_clock(ctx, 300)
    assert :ok = Recovery.reconcile(id)
    assert :ok = Recovery.delivery_deadline(id)

    assert %{rows: [["unknown", "read_exhausted", "ambiguous_write"]]} =
             handoff_rows(ctx, "state, reason_code, uncertainty_reason")

    assert [
             ["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"],
             ["support_worker", "outbound_delivery", "handoff_failed", "deadline"]
           ] = SupportDBCase.audit_rows(:delivery_target_id, id)
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

      assert [["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"]] =
               SupportDBCase.audit_rows(:delivery_target_id, id)

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

  for denial <- [:policy, :circuit] do
    test "the owning worker cancels a proven no-send after #{denial} denial", ctx do
      id = SupportDBCase.prepare_reply(ctx)
      {task, worker} = pause_authorized(ctx, id)

      assert %{rows: [["sending", nil, 1, generation, %NaiveDateTime{} = marker]]} =
               dispatch_history(ctx)

      case unquote(denial) do
        :policy ->
          SupportDBCase.disable_automation(ctx)

        :circuit ->
          alias VoelgoedAi.Support.{BindingCircuit, Ownership}

          assert {:ok, :ok} =
                   Repo.transact(fn ->
                     Ownership.locked_session(SupportDBCase.session_id(ctx), fn config, _, now ->
                       {:ok, BindingCircuit.record(config.binding, 0, now, {:error, :forbidden})}
                     end)
                   end)
      end

      assert :ok = resume_authorized(task, worker)
      assert :ok = Delivery.deliver(id)
      assert :ok = Recovery.delivery_deadline(id)

      assert %{rows: [["cancelled", "dispatch_denied", 1, ^generation, ^marker]]} =
               dispatch_history(ctx)

      assert [] = SupportDBCase.audit_rows(:delivery_target_id, id)
      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "a stale authorized worker cannot cancel at lease equality", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    {task, worker} = pause_authorized(ctx, id)
    SupportDBCase.advance_clock(ctx, 5)
    SupportDBCase.disable_automation(ctx)
    assert :ok = resume_authorized(task, worker)
    assert :ok = Recovery.delivery_deadline(id)
    assert %{rows: [["unknown", nil, 1, _, %NaiveDateTime{}]]} = dispatch_history(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "a replaced authorized fence cannot be cancelled by the old worker", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    {task, worker} = pause_authorized(ctx, id)
    # Recovery never replaces a consumed claim. Inject a new fence to test
    # the old worker's check independently of either lease or intent state.
    assert %{rows: [[generation]]} =
             SQL.query!(
               Repo,
               "UPDATE outbound_deliveries SET claim_generation = claim_generation + 1 WHERE id = $1 RETURNING claim_generation",
               [Ecto.UUID.dump!(id)]
             )

    SupportDBCase.disable_automation(ctx)
    assert :ok = resume_authorized(task, worker)

    assert %{rows: [["sending", nil, 1, ^generation, %NaiveDateTime{} = marker]]} =
             dispatch_history(ctx)

    SupportDBCase.advance_clock(ctx, 5)
    assert :ok = Recovery.delivery_deadline(id)
    assert %{rows: [["unknown", nil, 1, ^generation, ^marker]]} = dispatch_history(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "an already UNKNOWN authorization is never cancelled by the original worker", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    {task, worker} = pause_authorized(ctx, id)
    SupportDBCase.advance_clock(ctx, 5)
    assert :ok = Recovery.delivery_deadline(id)

    assert %{rows: [["unknown", nil, 1, generation, %NaiveDateTime{} = marker]]} =
             dispatch_history(ctx)

    SupportDBCase.disable_automation(ctx)
    assert :ok = resume_authorized(task, worker)
    assert %{rows: [["unknown", nil, 1, ^generation, ^marker]]} = dispatch_history(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  defp pause_authorized(ctx, id) do
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :authorization_barrier, parent))
    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_authorized, worker}, 1_000
    {task, worker}
  end

  defp resume_authorized(task, worker) do
    send(worker, :resume_delivery_authorization)
    Task.await(task, 5_000)
  end

  defp dispatch_history(ctx) do
    SupportDBCase.delivery_rows(
      ctx,
      "state, reason_code, attempt_count, claim_generation, dispatch_authorized_at"
    )
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
               "SELECT event, reason_code FROM audit_events WHERE delivery_target_id = $1 AND actor_kind = 'staff'",
               [Ecto.UUID.dump!(id)]
             )

    assert :ok = Delivery.deliver(id)
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "an untrusted caller cannot mint or forge operator storage authority", ctx do
    alias VoelgoedAi.Support.{Ownership, WorkStore}

    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)

    assert {:ok, :denied} =
             Repo.transact(fn ->
               assert {:ok, row} = Ownership.get(OutboundDelivery, id)
               attrs = %{read_sequence: row.read_sequence + 1}

               audit_attrs = %{
                 actor_kind: :staff,
                 actor_staff_id: ctx.operator.id,
                 target_kind: :outbound_delivery,
                 delivery_target_id: id,
                 event: :abandon_delivery,
                 reason_code: :local_operator,
                 correlation_id: row.correlation_id,
                 operational_before: %{status: :unknown, ownership_epoch: row.ownership_epoch},
                 operational_after: %{status: :abandoned, ownership_epoch: row.ownership_epoch}
               }

               assert {:error, :denied} =
                        WorkStore.update(&work_store_owner/0, row, :abandon, attrs)

               assert {:error, :denied} =
                        WorkStore.create(
                          &work_store_owner/0,
                          AuditEvent,
                          :append_support_operator,
                          audit_attrs
                        )

               ref = make_ref()
               actor = %WorkStore{ref: ref}

               try do
                 Process.put(WorkStore, {ref, OutboundDelivery, :abandon, &work_store_owner/0})

                 assert {:error, %Ash.Error.Forbidden{}} =
                          Ash.update(row, attrs, action: :abandon, actor: actor)

                 Process.put(
                   WorkStore,
                   {ref, AuditEvent, :append_support_operator, &work_store_owner/0}
                 )

                 assert {:error, %Ash.Error.Forbidden{}} =
                          Ash.create(AuditEvent, audit_attrs,
                            action: :append_support_operator,
                            actor: actor
                          )
               after
                 Process.delete(WorkStore)
               end

               {:ok, :denied}
             end)

    assert %{rows: [["unknown"]]} = SupportDBCase.delivery_rows(ctx, "state")

    assert [["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"]] =
             SupportDBCase.audit_rows(:delivery_target_id, id)
  end

  defp work_store_owner, do: Support

  test "storage ownership grants each module only its own actions" do
    alias VoelgoedAi.Support.{
      Delivery,
      Ingress,
      Ownership,
      Recovery,
      RunProcessing,
      SupportSession,
      SystemAudit,
      WorkStore
    }

    for {module, resource, action} <- [
          {Support, OutboundDelivery, :abandon},
          {Support, SupportSession, :return_to_bot},
          {Support, AuditEvent, :append_support_operator},
          {Delivery, OutboundDelivery, :authorize_dispatch},
          {SystemAudit, AuditEvent, :append_system}
        ] do
      assert WorkStore.owns?(module, resource, action)
    end

    for {module, resource, action} <- [
          {Ingress, SupportSession, :return_to_bot},
          {Delivery, OutboundDelivery, :abandon},
          {Recovery, OutboundDelivery, :authorize_dispatch},
          {RunProcessing, OutboundDelivery, :confirm_sent},
          {Ownership, AuditEvent, :append_support_operator},
          {SystemAudit, AuditEvent, :append_support_operator},
          {Support, AuditEvent, :append_system},
          {__MODULE__, OutboundDelivery, :abandon}
        ] do
      refute WorkStore.owns?(module, resource, action)
    end
  end

  test "Ash actions enforce original states and own their target state", ctx do
    alias VoelgoedAi.Support.{InboundEvent, SupportRun, SupportSession}

    for {row, action, attrs, field} <- [
          {%OutboundDelivery{state: :sent}, :abandon, %{read_sequence: 1}, :state},
          {%OutboundDelivery{state: :unknown}, :safe_retry, %{claim_generation: 1}, :state},
          {%SupportRun{state: :completed}, :claim, %{}, :state},
          {%SupportSession{state: :closed}, :return_to_bot, %{}, :state},
          {%InboundEvent{state: :dispatched}, :dispatch, %{}, :state},
          {%InboundEvent{state: :dispatched, disposition: :covered}, :record_disposition,
           %{disposition: :triage}, :disposition},
          {%OutboundDelivery{state: :sending, dispatch_authorized_at: ctx.event.received_at},
           :safe_retry, %{claim_generation: 1}, :dispatch_authorized_at},
          {%OutboundDelivery{state: :pending}, :authorize_dispatch,
           %{dispatch_authorized_at: ctx.event.received_at}, :state},
          {%OutboundDelivery{state: :sending, dispatch_authorized_at: ctx.event.received_at},
           :authorize_dispatch, %{dispatch_authorized_at: ctx.event.received_at},
           :dispatch_authorized_at}
        ] do
      changeset = Ash.Changeset.for_update(row, action, attrs)

      assert Enum.any?(changeset.errors, fn error ->
               match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: ^field,
                   message: "cannot apply this action from the current state"
                 },
                 error
               )
             end),
             "expected the original state guard on #{inspect(row.__struct__)}.#{action}"
    end

    row = %OutboundDelivery{state: :unknown}
    legal = Ash.Changeset.for_update(row, :abandon, %{read_sequence: 1})
    assert legal.valid?
    assert Ash.Changeset.get_attribute(legal, :state) == :abandoned

    for attrs <- [%{state: :failed}, %{attempt_count: 0}] do
      refute Ash.Changeset.for_update(row, :abandon, attrs).valid?
    end
  end

  test "PostgreSQL refuses to change a terminal delivery or run state", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    assert :ok = Delivery.deliver(id)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "outbound_deliveries_terminal_state"}}} =
             SQL.query(
               Repo,
               "UPDATE outbound_deliveries SET state = 'cancelled', confirmed_at = NULL WHERE id = $1",
               [Ecto.UUID.dump!(id)]
             )

    assert {:error, %Postgrex.Error{postgres: %{constraint: "support_runs_terminal_state"}}} =
             SQL.query(
               Repo,
               """
               UPDATE support_runs SET state = 'queued', decision = NULL, finished_at = NULL
               WHERE id = (SELECT run_id FROM outbound_deliveries WHERE id = $1)
               """,
               [Ecto.UUID.dump!(id)]
             )
  end

  for closure <- [:resolved, :operator] do
    test "#{closure} closure carries an unknown delivery's inhibit into the next generation",
         ctx do
      id = SupportDBCase.prepare_reply(ctx)
      first = SupportDBCase.session_id(ctx)
      SupportDBCase.write_mode(ctx, :timeout)
      assert :ok = Delivery.deliver(id)

      case unquote(closure) do
        :resolved ->
          observe_resolution(ctx)
          Agent.update(ctx.fake, &put_in(&1.observation.status, :pending))

        :operator ->
          assert {:ok, %{state: :closed}} = Support.close_session(ctx.operator, first)
      end

      assert %{rows: [["closed", true]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, human_inhibit FROM support_sessions WHERE id = $1",
                 [Ecto.UUID.dump!(first)]
               )

      assert ["triage", _] = process_next_input(ctx, 1)

      assert %{rows: [[current, "unverified", true]]} =
               SQL.query!(
                 Repo,
                 "SELECT id::text, state, human_inhibit FROM support_sessions WHERE conversation_id = $1 AND generation = 2",
                 [ctx.event.conversation_id]
               )

      assert {:ok, %{state: :abandoned}} =
               Support.abandon_delivery(ctx.operator, id, :acknowledge_uncertainty)

      assert %{rows: [["human_active", true]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, human_inhibit FROM support_sessions WHERE id = $1",
                 [Ecto.UUID.dump!(current)]
               )

      assert ["triage", _] = process_next_input(ctx, 2)
      assert [_] = SupportDBCase.writes(ctx)

      assert {:ok, %{state: :bot_active}} = Support.return_to_bot(ctx.operator, current)
      assert ["covered", "accepted"] = process_next_input(ctx, 3)
    end
  end

  test "a reopened legacy generation blocks and inherits takeover from an older unknown delivery",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)
    first = SupportDBCase.session_id(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)
    assert {:ok, %{state: :closed}} = Support.close_session(ctx.operator, first)

    # Reproduce a closed generation persisted before closure inherited the hold.
    assert %{num_rows: 1} =
             SQL.query!(Repo, "UPDATE support_sessions SET human_inhibit = false WHERE id = $1", [
               Ecto.UUID.dump!(first)
             ])

    assert ["triage", "awaiting_operator"] = process_next_input(ctx, 1)

    assert {:ok, %{state: :abandoned}} =
             Support.abandon_delivery(ctx.operator, id, :acknowledge_uncertainty)

    assert ["triage", "scope_denied"] = process_next_input(ctx, 2)
    assert [_] = SupportDBCase.writes(ctx)
  end

  test "signed human takeover fences an authorized delivery before POST", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :authorization_barrier, parent))

    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_authorized, worker}, 1_000
    human = %{ctx.event | kind: :human_outbound, message_id: ctx.event.message_id + 1}
    assert {:ok, _} = Ingress.accept(human)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    send(worker, :resume_delivery_authorization)
    assert :ok = Task.await(task)
    assert [] = SupportDBCase.writes(ctx)
  end

  for phase <- [:pending, :claimed, :authorized] do
    test "signed takeover fences a #{phase} handoff and survives reopen", ctx do
      id = prepare_handoff(ctx)

      {resume, expected} =
        case unquote(phase) do
          :pending ->
            {fn -> :ok end, ["cancelled", "human_takeover", nil, 0]}

          :claimed ->
            SupportDBCase.block_after_claim(ctx, self())
            task = Task.async(fn -> Delivery.deliver(id) end)
            assert_receive {:delivery_claimed, worker}, 1_000

            resume = fn ->
              send(worker, :resume_delivery_claim)
              Task.await(task, 5_000)
            end

            {resume, ["cancelled", "human_takeover", nil, 0]}

          :authorized ->
            {task, worker} = pause_authorized(ctx, id)
            {fn -> resume_authorized(task, worker) end, ["unknown", nil, "human_takeover", 1]}
        end

      assert Agent.get(ctx.fake, & &1.observation.assignee) == :bot
      assert signed_takeover(ctx) == 204
      assert %{rows: [["human_active", true]]} = session_state(ctx, "state, human_inhibit")

      assert %{rows: [^expected]} =
               handoff_rows(ctx, "state, reason_code, uncertainty_reason, attempt_count")

      assert :ok = resume.()
      assert [] = SupportDBCase.writes(ctx)
      assert :ok = Delivery.deliver(id)
      assert :ok = Recovery.reconcile(id)

      assert %{rows: [^expected]} =
               handoff_rows(ctx, "state, reason_code, uncertainty_reason, attempt_count")

      assert signed_takeover(ctx) == 204
      assert_handoff_sticky_after_reopen(ctx, id, Enum.take(expected, 2))
      assert signed_takeover(ctx) == 204
      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "a qualified existing handoff goal records already_human and survives reopen", ctx do
    id = prepare_handoff(ctx)

    Agent.update(
      ctx.fake,
      &%{&1 | observation: %{&1.observation | status: :open, assignee: :human}}
    )

    assert :ok = Delivery.deliver(id)

    assert %{rows: [["sent", "already_human", 0, nil, %NaiveDateTime{}]]} =
             handoff_rows(
               ctx,
               "state, reason_code, attempt_count, dispatch_authorized_at, confirmed_at"
             )

    assert %{rows: [["human_active", true]]} = session_state(ctx, "state, human_inhibit")
    assert :ok = Delivery.deliver(id)
    assert_handoff_sticky_after_reopen(ctx, id, ["sent", "already_human"])
  end

  defp signed_takeover(ctx) do
    SupportDBCase.signed_request(ctx, fn payload ->
      Map.merge(payload, %{
        "id" => ctx.event.message_id + 10,
        "message_type" => "outgoing",
        "sender" => %{"type" => "user", "id" => 82}
      })
    end).status
  end

  defp assert_handoff_sticky_after_reopen(ctx, id, result) do
    observe_resolution(ctx)

    Agent.update(
      ctx.fake,
      &%{&1 | observation: %{&1.observation | status: :pending, assignee: :bot}}
    )

    assert ["triage", "scope_denied"] = process_next_input(ctx, 20)

    assert %{rows: [[1, "closed", true], [2, "unverified", true]]} =
             SQL.query!(
               Repo,
               """
               SELECT generation, state, human_inhibit FROM support_sessions
               WHERE conversation_id = $1 ORDER BY generation
               """,
               [ctx.event.conversation_id]
             )

    assert :ok = Delivery.deliver(id)

    assert %{rows: [^result]} =
             SQL.query!(
               Repo,
               "SELECT state, reason_code FROM outbound_deliveries WHERE id = $1",
               [
                 Ecto.UUID.dump!(id)
               ]
             )

    assert [] = SupportDBCase.writes(ctx)
  end

  test "a resolved observation fences an authorized delivery before POST", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    parent = self()
    Agent.update(ctx.fake, &Map.put(&1, :authorization_barrier, parent))

    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:delivery_authorized, worker}, 1_000
    observe_resolution(ctx)
    assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

    assert %{rows: [["closed", true]]} =
             SQL.query!(
               Repo,
               "SELECT state, human_inhibit FROM support_sessions WHERE conversation_id = $1",
               [ctx.event.conversation_id]
             )

    send(worker, :resume_delivery_authorization)
    assert :ok = Task.await(task)
    assert [] = SupportDBCase.writes(ctx)
  end

  defp observe_resolution(ctx) do
    Agent.update(ctx.fake, &put_in(&1.observation.status, :resolved))

    assert SupportDBCase.signed_request(ctx, &Map.put(&1, "event", "conversation_updated")).status ==
             204

    assert %{rows: [[receipt]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM inbound_events WHERE conversation_id = $1 AND message_id IS NULL",
               [ctx.event.conversation_id]
             )

    assert :ok = RunProcessing.process_event(receipt)
  end

  defp process_next_input(ctx, offset) do
    message = ctx.event.message_id + offset
    SupportDBCase.append_public_input(ctx, message)
    assert {:ok, receipt} = Ingress.accept(%{ctx.event | message_id: message})
    assert :ok = RunProcessing.process_event(receipt)

    assert %{rows: [row]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(receipt)]
             )

    row
  end

  test "sweep fences an expired worker even while its write callback is blocked", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.block_next_write(ctx, self())
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          assert %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(parent, {:wire_backend, self(), backend})
          Delivery.deliver(id)
        end)
      end)

    assert_receive {:wire_backend, worker, backend}, 1_000
    assert_receive {:chatwoot_write, ^worker}, 1_000

    assert %{rows: [["idle", nil]]} =
             SQL.query!(
               Repo,
               """
               SELECT state, xact_start FROM pg_stat_activity
               WHERE pid = $1 AND pid <> pg_backend_pid()
               """,
               [backend]
             )

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
