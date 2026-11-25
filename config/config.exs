import Config

config :voelgoed_ai, ecto_repos: [VoelgoedAi.Repo]

config :voelgoed_ai, VoelgoedAiWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: VoelgoedAiWeb.ErrorJSON], layout: false]

config :phoenix, :json_library, Jason
