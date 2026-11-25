defmodule VoelgoedAi.Support.DeliveryRecoveryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Support.{Delivery, Ingress, Recovery, RunProcessing}

  setup do
    SupportDBCase.setup()
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
end
