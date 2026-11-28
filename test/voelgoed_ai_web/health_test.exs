defmodule VoelgoedAiWeb.HealthTest do
  use ExUnit.Case, async: false

  test "the endpoint responds to a health check" do
    response =
      Plug.Test.conn(:get, "/health")
      |> VoelgoedAiWeb.Endpoint.call(VoelgoedAiWeb.Endpoint.init([]))

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"status" => "ok"}
  end

  test "readiness checks local storage without creating jobs or reservations" do
    counts = fn ->
      Ecto.Adapters.SQL.query!(
        VoelgoedAi.Repo,
        "SELECT (SELECT count(*) FROM oban_jobs), (SELECT count(*) FROM usage_reservations)"
      ).rows
    end

    before = counts.()

    response =
      Plug.Test.conn(:get, "/ready")
      |> VoelgoedAiWeb.Endpoint.call(VoelgoedAiWeb.Endpoint.init([]))

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"status" => "ready"}
    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]
    assert counts.() == before
  end

  for mode <- [nil, :en] do
    test "readiness requires a current enabled fixture for #{inspect(mode)}" do
      ctx = VoelgoedAi.SupportDBCase.setup(shadow: unquote(mode))
      fixture = Application.fetch_env!(:voelgoed_ai, :support_fixture)
      remote = Agent.get(ctx.fake, & &1)

      ready = fn ->
        Plug.Test.conn(:get, "/ready")
        |> VoelgoedAiWeb.Endpoint.call(VoelgoedAiWeb.Endpoint.init([]))
      end

      assert ready.().status == 200

      try do
        Application.put_env(:voelgoed_ai, :support_fixture, %{fixture | locale: :invalid})
        response = ready.()
        assert response.status == 503
        assert Jason.decode!(response.resp_body) == %{"status" => "unavailable"}
      after
        Application.put_env(:voelgoed_ai, :support_fixture, fixture)
      end

      assert ready.().status == 200
      assert Agent.get(ctx.fake, & &1) == remote
    end
  end

  test "missing job storage returns a generic 503" do
    alias Ecto.Adapters.SQL
    alias VoelgoedAi.Repo

    assert {:error, :restore_table} =
             Repo.transact(fn ->
               SQL.query!(Repo, "ALTER TABLE oban_jobs RENAME TO readiness_probe_hidden_jobs")

               response =
                 Plug.Test.conn(:get, "/ready")
                 |> VoelgoedAiWeb.Endpoint.call(VoelgoedAiWeb.Endpoint.init([]))

               assert response.status == 503
               assert Jason.decode!(response.resp_body) == %{"status" => "unavailable"}
               Repo.rollback(:restore_table)
             end)
  end

  test "the Repo connects to the designated TEST database and role" do
    result = Ecto.Adapters.SQL.query!(VoelgoedAi.Repo, "SELECT current_database(), current_user")
    assert result.rows == [["vgas_test", "vgas_test"]]
  end
end
