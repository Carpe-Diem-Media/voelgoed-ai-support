defmodule VoelgoedAi.Vgas29MigrationProbeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Support.{Delivery, Recovery}

  @version 20_261_127_195_725
  @outbox_version 20_261_128_100_000

  test "populated predecessor data survives upgrade and recorded attention blocks rollback" do
    assert System.get_env("VGAS29_REHEARSE") == "1"
    assert Repo.config()[:port] == 55436
    assert Repo.config()[:hostname] == "127.0.0.1"
    assert System.get_env("VGAS_F04_DISPOSABLE") == "1"

    Code.require_file("priv/repo/migrations/20261127195725_vgas29_operations.exs")
    Code.require_file("priv/repo/migrations/20261128100000_queue_circuit_alert_openings.exs")
    migration = Module.concat(VoelgoedAi.Repo.Migrations, Vgas29Operations)
    outbox = Module.concat(VoelgoedAi.Repo.Migrations, QueueCircuitAlertOpenings)
    ctx = SupportDBCase.setup()
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.write_mode(ctx, :timeout)
    assert :ok = Delivery.deliver(id)
    SupportDBCase.disable_automation(ctx)
    previous = facts(id)
    assert [[_intent, _session, _run]] = previous
    assert :ok = Ecto.Migrator.down(Repo, @outbox_version, outbox, log: false)
    assert :ok = Ecto.Migrator.down(Repo, @version, migration, log: false)
    assert facts(id) == previous
    assert :ok = Ecto.Migrator.up(Repo, @version, migration, log: false)
    assert :ok = Ecto.Migrator.up(Repo, @outbox_version, outbox, log: false)
    assert facts(id) == previous

    for _ <- 1..2, do: assert(:ok = Recovery.sweep())

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM support_alert_episodes WHERE binding_id = $1",
               [
                 Ecto.UUID.dump!(ctx.binding_id)
               ]
             )

    assert_raise Postgrex.Error, ~r/rollback would remove operational safety state/, fn ->
      Ecto.Migrator.down(Repo, @version, migration, log: false)
    end

    assert @version in Ecto.Migrator.migrated_versions(Repo)
    assert facts(id) == previous

    SQL.query!(
      Repo,
      "INSERT INTO support_circuit_alerts_pending VALUES ($1, 1, now())",
      [Ecto.UUID.dump!(ctx.binding_id)]
    )

    assert_raise Postgrex.Error, ~r/rollback would remove unprojected circuit openings/, fn ->
      Ecto.Migrator.down(Repo, @outbox_version, outbox, log: false)
    end

    assert @outbox_version in Ecto.Migrator.migrated_versions(Repo)
    assert :ok = Recovery.sweep()

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM support_circuit_alerts_pending")
  end

  defp facts(id) do
    SQL.query!(
      Repo,
      """
      SELECT to_jsonb(d), to_jsonb(s), to_jsonb(r) - 'assisted_draft'
      FROM outbound_deliveries d
      JOIN support_sessions s ON s.id = d.session_id
      JOIN support_runs r ON r.id = d.run_id
      WHERE d.id = $1
      """,
      [Ecto.UUID.dump!(id)]
    ).rows
  end
end
