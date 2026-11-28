defmodule VoelgoedAi.Support.EmergencyOverrideTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Governance.{AutomationControl, EmergencyOverride}
  alias VoelgoedAi.Support.{ChatwootAdapter, Delivery, Ingress, RunProcessing}

  setup do
    ctx = SupportDBCase.setup()
    original = Application.get_env(:voelgoed_ai, :emergency_override, false)
    on_exit(fn -> Application.put_env(:voelgoed_ai, :emergency_override, original) end)
    ctx
  end

  test "an override asserted after the last DB dispatch check stops the wire and survives clearing the setting",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)
    owner = self()

    fixture =
      Map.put(ChatwootAdapter.fixture(), :before_wire, fn ->
        send(owner, {:before_wire, self()})

        receive do
          :continue -> :ok
        after
          3_000 -> :timeout
        end
      end)

    Application.put_env(:voelgoed_ai, :support_fixture, fixture)

    task = Task.async(fn -> Delivery.deliver(id) end)
    assert_receive {:before_wire, worker}, 2_000
    assert %{rows: [["sending", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    Application.put_env(:voelgoed_ai, :emergency_override, true)
    assert :ignore = EmergencyOverride.start_link()

    send(worker, :continue)
    assert :ok = Task.await(task)
    assert %{rows: [["cancelled", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
    assert [] = SupportDBCase.writes(ctx)

    Application.put_env(:voelgoed_ai, :emergency_override, false)

    assert %{rows: [[true]]} =
             SQL.query!(Repo, "SELECT emergency_latched FROM automation_controls")

    next = SupportDBCase.next_conversation(ctx, 1)
    assert {:ok, receipt} = Ingress.accept(next.event)
    assert :ok = RunProcessing.process_event(receipt)

    assert %{rows: [["triage", "disabled"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(receipt)]
             )

    SupportDBCase.disable_automation(ctx)
    Application.put_env(:voelgoed_ai, :emergency_override, true)

    assert {:error, _} =
             VoelgoedAi.SupportFixtures.invoke(
               AutomationControl,
               :enable_automation,
               %{binding_id: ctx.binding_id},
               ctx.admin
             )

    Application.put_env(:voelgoed_ai, :emergency_override, false)
    SupportDBCase.enable_automation(ctx)
    assert :ok = Delivery.deliver(id)
    assert [] = SupportDBCase.writes(ctx)
  end

  for purpose <- [:reply, :handoff], denial <- [:disable, :changed_epoch, :latch, :storage] do
    test "#{purpose} is cancelled when #{denial} invalidates the last write check", ctx do
      id = prepare(ctx, unquote(purpose))
      owner = self()
      Application.put_env(:voelgoed_ai, :emergency_override, false)

      fixture =
        Map.put(ChatwootAdapter.fixture(), :before_wire, fn ->
          send(owner, {:before_wire, self()})

          receive do
            :continue -> :ok
          end
        end)

      Application.put_env(:voelgoed_ai, :support_fixture, fixture)
      task = Task.async(fn -> Delivery.deliver(id) end)
      assert_receive {:before_wire, worker}, 2_000
      assert %{rows: [["sending", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")
      invalidate(ctx, unquote(denial), worker)
      assert :ok = Task.await(task)

      assert %{rows: [["cancelled", "dispatch_denied", 1]]} =
               SupportDBCase.delivery_rows(ctx, "state, reason_code, attempt_count")

      assert :ok = Delivery.deliver(id)
      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "the direct Enable action requires the Oban supervisor and leaves no enable audit", ctx do
    SupportDBCase.disable_automation(ctx)

    assert %{rows: [[id, epoch]]} =
             SQL.query!(
               Repo,
               "SELECT id::text, security_epoch FROM automation_controls WHERE singleton AND status = 'disabled'"
             )

    audit = SupportDBCase.audit_rows(:control_target_id, id)
    assert :ok = Supervisor.terminate_child(VoelgoedAi.Supervisor, Oban)

    try do
      assert Oban.whereis(Oban) == nil

      assert {:error, _} =
               VoelgoedAi.SupportFixtures.invoke(
                 AutomationControl,
                 :enable_automation,
                 %{binding_id: ctx.binding_id},
                 ctx.admin
               )

      assert %{rows: [["disabled", "disabled", ^epoch]]} =
               SQL.query!(
                 Repo,
                 "SELECT status, mode, security_epoch FROM automation_controls WHERE singleton"
               )

      assert SupportDBCase.audit_rows(:control_target_id, id) == audit
    after
      assert {:ok, _} = Supervisor.restart_child(VoelgoedAi.Supervisor, Oban)
    end

    SupportDBCase.enable_automation(ctx)

    assert SupportDBCase.audit_rows(:control_target_id, id) ==
             audit ++ [["staff", "automation_control", "enable_automation", "local_admin"]]
  end

  defp prepare(ctx, :reply), do: SupportDBCase.prepare_reply(ctx)

  defp prepare(ctx, :handoff) do
    assert {:ok, receipt} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(receipt)
    assert {:ok, _} = Support.request_handoff(ctx.operator, SupportDBCase.session_id(ctx))
    assert %{rows: [[id]]} = SupportDBCase.delivery_rows(ctx, "id::text")
    id
  end

  defp invalidate(ctx, :disable, worker) do
    SupportDBCase.disable_automation(ctx)
    send(worker, :continue)
  end

  defp invalidate(ctx, :changed_epoch, worker) do
    SupportDBCase.disable_automation(ctx)
    SupportDBCase.enable_automation(ctx)
    send(worker, :continue)
  end

  defp invalidate(_, :latch, worker) do
    SQL.query!(Repo, "UPDATE automation_controls SET emergency_latched = true WHERE singleton")
    send(worker, :continue)
  end

  defp invalidate(_, :storage, worker) do
    assert {:ok, :lock_released} =
             Repo.transact(fn ->
               SQL.query!(Repo, "LOCK TABLE automation_controls IN ACCESS EXCLUSIVE MODE")
               send(worker, :continue)

               assert Enum.any?(1..40, fn _ ->
                        %{rows: [[waiting]]} =
                          SQL.query!(Repo, """
                          SELECT EXISTS (SELECT 1 FROM pg_locks
                            WHERE relation = 'automation_controls'::regclass
                              AND mode = 'AccessShareLock' AND NOT granted)
                          """)

                        if not waiting, do: Process.sleep(5)
                        waiting
                      end)

               # Release after the first checkout expires, while a retry could still succeed.
               Process.sleep(325)
               {:ok, :lock_released}
             end)
  end
end
