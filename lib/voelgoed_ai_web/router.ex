defmodule VoelgoedAiWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  import VoelgoedAiWeb.StaffSession,
    only: [protect_csrf: 2, knowledge_headers: 2, require_knowledge_origin: 2]

  pipeline :staff_session do
    plug(VoelgoedAiWeb.StaffSession)
    plug(:protect_csrf)
  end

  pipeline :staff_knowledge do
    plug(:knowledge_headers)
    plug(:require_knowledge_origin)
  end

  get("/health", VoelgoedAiWeb.HealthController, :show)

  scope "/staff", VoelgoedAiWeb do
    pipe_through(:staff_session)

    get("/entra", StaffAuthController, :request, log: false)
    get("/entra/callback", StaffAuthController, :callback, log: false)
    get("/session", StaffAuthController, :session, log: false)
    post("/sign-out", StaffAuthController, :sign_out, log: false)
  end

  scope "/staff/knowledge", VoelgoedAiWeb do
    pipe_through([:staff_knowledge, :staff_session])

    get("/denied", KnowledgeLive.DenialController, :show, log: false)

    live_session :staff_knowledge,
      root_layout: {VoelgoedAiWeb.KnowledgeLive.Components, :root},
      on_mount: VoelgoedAiWeb.KnowledgeLive.Auth do
      live("/", KnowledgeLive.Index, :index, metadata: %{log: false})
      live("/collections/:id", KnowledgeLive.Index, :collection, metadata: %{log: false})
      live("/articles/:id", KnowledgeLive.Article, :show, metadata: %{log: false})

      live("/articles/:id/revisions/:revision_id", KnowledgeLive.Revision, :show,
        metadata: %{log: false}
      )
    end
  end
end
