defmodule VoelgoedAi.Support.WorkflowTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Support.{Ingress, Recovery, RunProcessing}
  alias VoelgoedAi.Support.Workers.{Deliver, ProcessEvent, ProcessRun}

  setup do
    SupportDBCase.setup()
  end

  test "the durable receipt produces an accepted fixed reply", ctx do
    assert {:ok, %{id: receipt_id}} = SupportDBCase.signed_receipt(ctx)
    assert :ok = ProcessEvent.perform(%Oban.Job{args: %{"event_id" => receipt_id}})

    assert %{rows: [[run_id]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM support_runs WHERE session_id IN (SELECT id FROM support_sessions WHERE conversation_id = $1)",
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

  test "deadline is sampled after a contended session lock", ctx do
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
