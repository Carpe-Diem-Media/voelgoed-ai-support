defmodule VoelgoedAi.Support.EmergencyOverrideTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Governance.{AutomationControl, EmergencyOverride}
  alias VoelgoedAi.Support.{ChatwootAdapter, Delivery, Ingress, RunProcessing}

  setup do
    ctx = SupportDBCase.setup()
    original = Application.get_env(:voelgoed_ai, :emergency_override)
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
end
