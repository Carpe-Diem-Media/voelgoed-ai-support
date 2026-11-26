import Config

config :voelgoed_ai,
  ecto_repos: [VoelgoedAi.Repo],
  ash_domains: [
    VoelgoedAi.Accounts,
    VoelgoedAi.Governance,
    VoelgoedAi.Intelligence,
    VoelgoedAi.Support
  ]

config :voelgoed_ai, VoelgoedAi.Repo, log: false

# Job storage is available. Execution requires a separate activation decision.
config :voelgoed_ai, Oban,
  repo: VoelgoedAi.Repo,
  queues: false,
  plugins: false,
  peer: false,
  stager: false

config :voelgoed_ai, VoelgoedAiWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: VoelgoedAiWeb.ErrorJSON], layout: false]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "secret", "token", "code", "state", "assertion"]

config :req_llm, load_dotenv: false
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  # Oban manual mode suppresses automatic Cron insertion. Tests perform the
  # same bounded sweep worker explicitly.
  config :voelgoed_ai, Oban,
    testing: :manual,
    cron: [crontab: [{"* * * * *", VoelgoedAi.Support.Workers.Sweep}]]

  config :voelgoed_ai, :entra_fixture_transport, {Req.Test, VoelgoedAi.StaffEntraFixture}

  config :ash_authentication,
         :http_adapter,
         {VoelgoedAi.Feasibility.EntraDiscoveryAdapter,
          [plug: {Req.Test, VoelgoedAi.Feasibility.EntraProvider}, retry: false, redirect: false]}
end
