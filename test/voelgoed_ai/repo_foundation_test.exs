defmodule VoelgoedAi.RepoFoundationTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  test "the restricted test allocation runs PostgreSQL 18 with the foundation migration" do
    assert %{rows: [["vgas_test", "vgas_test", false, false, false, false, 18, "UTC"]]} =
             SQL.query!(Repo, """
             SELECT current_database(), current_user, rolsuper, rolcreatedb, rolcreaterole,
                    rolreplication, current_setting('server_version_num')::integer / 10000,
                    current_setting('TimeZone')
             FROM pg_roles WHERE rolname = current_user
             """)

    assert %{rows: [[20_261_125_141_215]]} =
             SQL.query!(
               Repo,
               "SELECT version FROM schema_migrations WHERE version = 20261125141215"
             )
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
