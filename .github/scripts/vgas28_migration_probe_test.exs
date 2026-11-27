defmodule VoelgoedAi.Support.RetentionMigrationProbe do
  use ExUnit.Case, async: false
  import VoelgoedAi.ShadowWorkflowFixture
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  @version 20_261_127_191_005

  test "populated predecessor reclassifies without changing evidence and refuses a destructive downgrade" do
    assert System.get_env("VGAS_VGAS28_REHEARSE") == "1"
    assert System.get_env("VGAS_VERIFY_PGVECTOR") == "true"
    assert Repo.config()[:port] == 55436
    assert Repo.config()[:hostname] == "127.0.0.1"

    assert %{rows: [["vgas_test", "vgas_test", "180007", "0.8.7"]]} =
             SQL.query!(Repo, """
             SELECT current_database(), current_user, current_setting('server_version_num'),
               (SELECT extversion FROM pg_extension WHERE extname = 'vector')
             """)

    Code.require_file("priv/repo/migrations/20261127191005_vgas_28_reply_retention.exs")
    migration = Module.concat(VoelgoedAi.Repo.Migrations, Vgas28ReplyRetention)
    ctx = setup_faq(:en, "grounded")
    configure(ctx, generation: &response(&1, ctx))
    id = queue(ctx, question(:en))
    assert :ok = perform(id)
    previous = facts(id)
    assert [[_run, _attempts, _audit]] = previous

    # With only PRESENT rows, the downgrade reaches the exact predecessor
    # schema and preserves the populated records. Reapply from that schema.
    assert :ok = Ecto.Migrator.down(Repo, @version, migration, log: false)
    assert facts(id) == previous
    assert :ok = Ecto.Migrator.up(Repo, @version, migration, log: false)
    assert facts(id) == previous
    assert run(id).retention_state == :present
    assert run(id).typed_decision.reply_text == paraphrase(:en)

    finished = run(id).finished_at
    Agent.update(ctx.support.fake, &%{&1 | now: DateTime.add(finished, 7 * 86_400)})

    inbox =
      Map.take(ctx.support.event, [:installation_ref, :external_account_id, :external_inbox_id])

    capability = Ash.UUIDv7.generate()

    Application.put_env(:voelgoed_ai, :retention_fixture, %{
      inbox: inbox,
      capability: capability,
      batch_size: 25
    })

    on_exit(fn -> Application.delete_env(:voelgoed_ai, :retention_fixture) end)
    assert :ok = VoelgoedAi.Support.Workers.Retention.perform(job("capability", capability))
    after_purge = run(id)

    assert after_purge.retention_state == :purged

    assert_raise Postgrex.Error, ~r/cannot roll back recorded reply retention transitions/, fn ->
      Ecto.Migrator.down(Repo, @version, migration, log: false)
    end

    assert @version in Ecto.Migrator.migrated_versions(Repo)
    assert run(id) == after_purge
  end

  defp facts(id) do
    SQL.query!(
      Repo,
      """
      SELECT to_jsonb(r) - 'retention_state' - 'retention_occurrence',
        (SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM inference_runs i WHERE support_run_id = r.id),
        (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM audit_events a WHERE run_target_id = r.id)
      FROM support_runs r WHERE id = $1
      """,
      [uuid(id)]
    ).rows
  end
end
