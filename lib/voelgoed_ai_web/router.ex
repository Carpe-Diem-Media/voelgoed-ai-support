defmodule VoelgoedAiWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import VoelgoedAiWeb.StaffSession, only: [protect_csrf: 2]

  pipeline :staff_session do
    plug(VoelgoedAiWeb.StaffSession)
    plug(:protect_csrf)
  end

  get("/health", VoelgoedAiWeb.HealthController, :show)

  scope "/staff", VoelgoedAiWeb do
    pipe_through(:staff_session)

    get("/entra", StaffAuthController, :request, log: false)
    get("/entra/callback", StaffAuthController, :callback, log: false)
    get("/session", StaffAuthController, :session, log: false)
    post("/sign-out", StaffAuthController, :sign_out, log: false)
  end
end
