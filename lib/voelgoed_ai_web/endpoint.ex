defmodule VoelgoedAiWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :voelgoed_ai

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(VoelgoedAiWeb.Router)
end
