defmodule VoelgoedAiWeb.HealthTest do
  use ExUnit.Case, async: true

  test "the endpoint responds to a health check" do
    response =
      Plug.Test.conn(:get, "/health")
      |> VoelgoedAiWeb.Endpoint.call(VoelgoedAiWeb.Endpoint.init([]))

    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"status" => "ok"}
  end

  test "the Repo connects to the designated TEST database and role" do
    result = Ecto.Adapters.SQL.query!(VoelgoedAi.Repo, "SELECT current_database(), current_user")
    assert result.rows == [["vgas_test", "vgas_test"]]
  end
end
