defmodule VoelgoedAi.RepoFoundationTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  test "the restricted test allocation runs PostgreSQL 18 with the foundation migration" do
    # DevCore reports the session zone as UTC and the CI image as Etc/UTC.
    # Assert the zero offset rather than the zone name.
    assert %{rows: [["vgas_test", "vgas_test", false, false, false, false, 18, true]]} =
             SQL.query!(Repo, """
             SELECT current_database(), current_user, rolsuper, rolcreatedb, rolcreaterole,
                    rolreplication, current_setting('server_version_num')::integer / 10000,
                    EXTRACT(TIMEZONE FROM now()) = 0
             FROM pg_roles WHERE rolname = current_user
             """)

    assert %{rows: [[20_261_125_141_215]]} =
             SQL.query!(
               Repo,
               "SELECT version FROM schema_migrations WHERE version = 20261125141215"
             )
  end

  test "staff and audit preserve identity, UUIDv7, UTC precision and restrictive references" do
    assert %{rows: [[2, "bigint", 6, 6, true]]} =
             SQL.query!(Repo, """
             SELECT

               (SELECT count(*) FROM information_schema.columns
                WHERE table_name IN ('staff_users', 'audit_events') AND column_name = 'id'
                  AND data_type = 'uuid' AND column_default = 'uuidv7()'),
               (SELECT data_type FROM information_schema.columns
                  WHERE table_name = 'staff_users' AND column_name = 'session_generation'),
               (SELECT datetime_precision FROM information_schema.columns
                  WHERE table_name = 'staff_users' AND column_name = 'last_authenticated_at'),
               (SELECT datetime_precision FROM information_schema.columns
                  WHERE table_name = 'audit_events' AND column_name = 'occurred_at'),
               (SELECT indisunique AND pg_get_indexdef(indexrelid) LIKE '%(identity_issuer, identity_subject)'
                  FROM pg_index WHERE indexrelid = 'staff_users_issuer_subject_index'::regclass)
             """)

    assert %{rows: [["audit_events_actor_staff_id_fkey"], ["audit_events_target_id_fkey"]]} =
             SQL.query!(Repo, """
             SELECT conname FROM pg_constraint
             WHERE conrelid = 'audit_events'::regclass AND confrelid = 'staff_users'::regclass
               AND confdeltype = 'r' AND confupdtype = 'r' AND convalidated
             ORDER BY conname
             """)

    assert %{
             rows: [
               ["staff_users_generation_nonnegative"],
               ["staff_users_roles"],
               ["staff_users_status_timestamps"]
             ]
           } =
             SQL.query!(Repo, """
             SELECT conname FROM pg_constraint
             WHERE conrelid = 'staff_users'::regclass AND contype = 'c' AND convalidated
             ORDER BY conname
             """)
  end

  test "support uniqueness and qualified references are enforced in PostgreSQL" do
    assert %{rows: [[7, true]]} =
             SQL.query!(Repo, """
             SELECT count(*), bool_and(indisunique AND indpred IS NOT NULL)
             FROM pg_index
             WHERE indexrelid::regclass::text IN (
               'support_sessions_one_current', 'inbound_events_message_key',
               'inbound_events_stable_event_key', 'support_runs_one_active',
               'outbound_deliveries_one_reply', 'outbound_deliveries_one_handoff',
               'run_inputs_one_current'
             )
             """)

    assert %{rows: [[4, true]]} =
             SQL.query!(Repo, """
             SELECT count(*), bool_and(cardinality(conkey) > 1 AND confdeltype = 'r' AND convalidated)
             FROM pg_constraint
             WHERE conname IN (
               'support_sessions_binding_id_fkey', 'inbound_events_session_id_fkey',
               'outbound_deliveries_run_id_fkey', 'support_runs_parent_run_id_fkey'
             )
             """)
  end

  test "Oban v14 uses the application Repo in manual mode with no worker queues" do
    assert %{repo: Repo, testing: :manual, queues: [], plugins: []} = Oban.config()
    assert 14 == Oban.Migration.migrated_version(repo: Repo)
  end

  test "Oban insertion participates in the caller transaction" do
    reference = Ash.UUIDv7.generate()

    job =
      Oban.Job.new(%{reference: reference},
        queue: :storage_probe,
        worker: "VoelgoedAi.RepoFoundationTest.StorageProbe"
      )

    visible = fn ->
      SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'reference' = $1", [reference])
    end

    assert {:error, :rollback_probe} =
             Repo.transact(fn ->
               assert {:ok, %Oban.Job{}} = Oban.insert(job)
               assert %{rows: [[1]]} = visible.()
               assert %{rows: [[0]]} = Task.async(visible) |> Task.await(5_000)
               {:error, :rollback_probe}
             end)

    assert %{rows: [[0]]} = visible.()
  end

  @tag :requires_vgas001_upgrade
  test "the predecessor upgrade preserves existing staff and audit facts" do
    assert %{
             rows: [
               [
                 "019ac560-0000-7000-8000-000000000001",
                 "vgas001-upgrade-fixture",
                 "invited",
                 ["admin"],
                 0,
                 "019ac560-0000-7000-8000-000000000002",
                 "019ac560-0000-7000-8000-000000000003",
                 "bootstrap",
                 "staff-bootstrap",
                 "staff_user",
                 "provisioned",
                 "allowlisted",
                 %{"status" => "invited", "roles" => ["admin"], "session_generation" => 0},
                 nil,
                 nil
               ]
             ]
           } =
             SQL.query!(Repo, """
             SELECT s.id::text, s.identity_subject, s.status, s.roles, s.session_generation,
                    a.id::text, a.correlation_id::text, a.actor_kind, a.operator_ref, a.target_kind,
                    a.event, a.reason_code, a.after_state, a.operational_before, a.operational_after
             FROM staff_users s JOIN audit_events a ON a.target_id = s.id
             WHERE s.id = '019ac560-0000-7000-8000-000000000001'
             """)
  end

  @tag :requires_pgvector
  test "the pre-provisioned vector extension executes a cosine distance query" do
    assert %{rows: [[true]]} =
             SQL.query!(Repo, """
             SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')
             """)

    assert %{rows: [[1.0]]} =
             SQL.query!(Repo, "SELECT '[1,0]'::vector <=> '[0,1]'::vector")
  end
end
