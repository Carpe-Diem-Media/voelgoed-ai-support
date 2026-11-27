defmodule VoelgoedAiWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  import VoelgoedAiWeb.StaffSession,
    only: [protect_csrf: 2, knowledge_headers: 2, require_knowledge_origin: 2]

  import VoelgoedAiWeb.KnowledgeExportController, only: [parse_form: 2]

  pipeline :staff_session do
    plug(VoelgoedAiWeb.StaffSession)
    plug(:protect_csrf)
  end

  pipeline :staff_export do
    plug(VoelgoedAiWeb.StaffSession)
    plug(:parse_form)
    plug(:protect_csrf)
  end

  pipeline :staff_knowledge do
    plug(:knowledge_headers)
    plug(:require_knowledge_origin)
    plug(:fetch_query_params, length: 4_096)
  end

  get("/health", VoelgoedAiWeb.HealthController, :show)

  scope "/staff", VoelgoedAiWeb do
    pipe_through(:staff_session)

    get("/entra", StaffAuthController, :request, log: false)
    get("/entra/callback", StaffAuthController, :callback, log: false)
    get("/session", StaffAuthController, :session, log: false)
    post("/sign-out", StaffAuthController, :sign_out, log: false)
  end

  scope "/staff", VoelgoedAiWeb, log: false do
    pipe_through([:staff_knowledge, :staff_export])

    post("/knowledge/collections/:id/export", KnowledgeExportController, :download)
  end

  if Mix.env() == :test do
    scope "/staff", VoelgoedAiWeb, log: false do
      pipe_through([:staff_knowledge, :staff_session])

      live_session :staff_gaps,
        root_layout: {VoelgoedAiWeb.KnowledgeLive.Components, :gap_root} do
        live("/gaps", GapLive, :index)
      end
    end
  end

  scope "/staff/knowledge", VoelgoedAiWeb, log: false do
    pipe_through([:staff_knowledge, :staff_session])

    get("/denied", KnowledgeLive.DenialController, :show)

    live_session :staff_knowledge,
      root_layout: {VoelgoedAiWeb.KnowledgeLive.Components, :root},
      on_mount: VoelgoedAiWeb.KnowledgeLive.Auth do
      live("/", KnowledgeLive.Index, :index)
      live("/import", KnowledgeLive.Import, :show)
      live("/collections/:id/articles/new", KnowledgeLive.Draft, :new_article)
      live("/articles/:id/revisions/new", KnowledgeLive.Draft, :new_revision)
      live("/articles/:id/revisions/:revision_id/edit", KnowledgeLive.Draft, :edit)
      live("/collections/:id", KnowledgeLive.Index, :collection)
      live("/articles/:id", KnowledgeLive.Article, :show)
      live("/articles/:id/revisions/:revision_id", KnowledgeLive.Revision, :show)
    end
  end
end
