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
