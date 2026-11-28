defmodule VoelgoedAi.Support.OperationalAlertTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase, SupportFixtures}
  alias VoelgoedAi.Support.{Configuration, Delivery, InboxBinding, Ingress, Recovery}

  setup do
    SupportDBCase.setup()
  end

  test "a permanent circuit inhibit commits under an alert lock and its opening survives recovery",
       ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :forbidden)

    with_alert_lock(fn ->
      assert :ok = Delivery.deliver(id)

      assert %{rows: [[true, true]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT permanent_epoch IS NOT NULL, retry_at IS NOT NULL
                 FROM support_binding_circuits WHERE binding_id = $1
                 """,
                 [Ecto.UUID.dump!(ctx.binding_id)]
               )

      assert {:error, :alert_projection_unavailable} = Recovery.sweep()

      for action <- [:disable, :enable] do
        assert {:ok, _} =
                 SupportFixtures.invoke(InboxBinding, action, %{id: ctx.binding_id}, ctx.admin)
      end

      assert {:ok, :closed} =
               Configuration.recover_circuit(ctx.admin, SupportDBCase.session_id(ctx))

      assert [["staff", "inbox_binding", "recover_circuit", "local_admin"]] =
               Enum.filter(
                 SupportDBCase.audit_rows(:binding_target_id, ctx.binding_id),
                 &(Enum.at(&1, 2) == "recover_circuit")
               )
    end)

    assert :ok = Recovery.sweep()
    assert :ok = Recovery.sweep()
    assert [["circuit_open", 1], ["delivery_unknown", 1]] = alerts(ctx)
  end

  test "an ambiguous delivery commits with its audit while alert storage waits", ctx do
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)

    with_alert_lock(fn ->
      assert :ok = Delivery.deliver(id)
      assert %{rows: [["unknown", 1]]} = SupportDBCase.delivery_rows(ctx, "state, attempt_count")

      assert [["support_worker", "outbound_delivery", "delivery_unknown", "ambiguous_write"]] =
               SupportDBCase.audit_rows(:delivery_target_id, id)

      assert {:error, :alert_projection_unavailable} = Recovery.sweep()
      assert [_] = SupportDBCase.writes(ctx)
    end)

    assert :ok = Recovery.sweep()
    assert :ok = Recovery.sweep()
    assert [["delivery_unknown", 1]] = alerts(ctx)
  end

  test "a locked alert table cannot prevent recovery scheduling", ctx do
    event = [:voelgoed_ai, :support, :alert_projection_failed]
    handler = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               event,
               fn _, _, metadata, owner ->
                 send(owner, {:alert_projection_failed, metadata})
               end,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, id} = Ingress.accept(ctx.event)

    assert %{num_rows: 1} =
             SQL.query!(Repo, "DELETE FROM oban_jobs WHERE args->>'event_id' = $1", [id])

    SupportDBCase.advance_clock(ctx, 46)

    with_alert_lock(fn ->
      assert {:error, :alert_projection_unavailable} = Recovery.sweep()

      assert_received {:alert_projection_failed,
                       %{binding_id: binding_id, reason: :alert_projection_unavailable}}

      assert binding_id == ctx.binding_id

      assert %{rows: [[1]]} =
               SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = $1", [
                 id
               ])
    end)

    assert :ok = Recovery.sweep()
    assert :ok = Recovery.sweep()
    assert [["queue_overdue", 1]] = alerts(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  defp alerts(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT kind, count(*) FROM support_alert_episodes
      WHERE binding_id = $1 GROUP BY kind ORDER BY kind
      """,
      [Ecto.UUID.dump!(ctx.binding_id)]
    ).rows
  end

  defp with_alert_lock(operation) do
    owner = self()

    holder =
      Task.async(fn ->
        Repo.transact(
          fn ->
            SQL.query!(Repo, "LOCK TABLE support_alert_episodes IN ACCESS EXCLUSIVE MODE")
            send(owner, :alert_table_locked)

            receive do
              :unlock -> {:ok, :released}
            after
              20_000 -> {:error, :lock_test_timed_out}
            end
          end,
          timeout: 25_000
        )
      end)

    try do
      assert_receive :alert_table_locked, 2_000
      operation.()
    after
      send(holder.pid, :unlock)
      assert {:ok, :released} = Task.await(holder)
    end
  end
end
