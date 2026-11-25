defmodule VoelgoedAiWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :voelgoed_ai

  plug(Plug.RequestId)

  plug(Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :request_log_level, []}
  )

  plug(VoelgoedAiWeb.Router)

  def request_log_level(%{path_info: ["staff" | _]}), do: false
  def request_log_level(_), do: :info
end
