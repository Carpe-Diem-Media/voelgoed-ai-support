defmodule VoelgoedAiWeb.Router do
  @moduledoc false
  use Phoenix.Router

  get("/health", VoelgoedAiWeb.HealthController, :show)
end
