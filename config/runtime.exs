import Config

local_database_prefix =
  case config_env() do
    :dev -> "DEV"
    :test -> "TEST"
    :prod -> nil
  end

if local_database_prefix do
  config :voelgoed_ai, VoelgoedAi.Repo,
    hostname: System.fetch_env!("#{local_database_prefix}_DATABASE_HOST"),
    port: String.to_integer(System.fetch_env!("#{local_database_prefix}_DATABASE_PORT")),
    database: System.fetch_env!("#{local_database_prefix}_DATABASE_NAME"),
    username: System.fetch_env!("#{local_database_prefix}_DATABASE_USERNAME"),
    password: System.fetch_env!("#{local_database_prefix}_DATABASE_PASSWORD")

  config :voelgoed_ai, VoelgoedAiWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))]
else
  config :voelgoed_ai, VoelgoedAi.Repo, url: System.fetch_env!("DATABASE_URL")

  config :voelgoed_ai, VoelgoedAiWeb.Endpoint,
    url: [host: System.fetch_env!("PHX_HOST"), scheme: "https", port: 443],
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: System.get_env("PHX_SERVER") == "true"
end

if config_env() == :dev do
  config :voelgoed_ai, :development_ai, VoelgoedAi.DevelopmentAiConfig.load(System.get_env())
end
