defmodule VoelgoedAiWeb.HealthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

    case VoelgoedAi.Support.Readiness.check() do
      :ok -> json(conn, %{status: "ready"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "unavailable"})
    end
  end
end
