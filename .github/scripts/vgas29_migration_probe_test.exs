defmodule VoelgoedAi.Vgas29MigrationProbeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Support.OperationalAlert

  @version 20_261_127_195_725

  test "populated predecessor data survives upgrade and recorded attention blocks rollback" do
    assert System.get_env("VGAS29_REHEARSE") == "1"
    assert Repo.config()[:port] == 55436
    assert Repo.config()[:hostname] == "127.0.0.1"
    assert System.get_env("VGAS_F04_DISPOSABLE") == "1"

    Code.require_file("priv/repo/migrations/20261127195725_vgas29_operations.exs")
    migration = Module.concat(VoelgoedAi.Repo.Migrations, Vgas29Operations)
    ctx = SupportDBCase.setup()
    id = SupportDBCase.prepare_reply(ctx)
    SupportDBCase.disable_automation(ctx)
    previous = facts(id)
    assert [[_intent, _session, _run]] = previous
    assert :ok = Ecto.Migrator.down(Repo, @version, migration, log: false)
    assert facts(id) == previous
    assert :ok = Ecto.Migrator.up(Repo, @version, migration, log: false)
    assert facts(id) == previous

    for _ <- 1..2 do
      assert :ok =
               OperationalAlert.record(ctx.binding_id, :delivery_unknown, id, DateTime.utc_now())
    end

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
