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
  usd_to_nano = fn value ->
    value
    |> Decimal.new()
    |> Decimal.mult(1_000_000_000)
    |> Decimal.to_integer()
  end

  config :voelgoed_ai, :development_ai,
    model: System.get_env("VGAS_AI_MODEL", "openai:gpt-6-luna"),
    reasoning_effort: System.get_env("VGAS_AI_REASONING_EFFORT", "none"),
    max_output_tokens: String.to_integer(System.get_env("VGAS_AI_MAX_OUTPUT_TOKENS", "500")),
    embedding_model: System.get_env("VGAS_EMBEDDING_MODEL", "openai:text-embedding-3-small"),
    embedding_dimensions: String.to_integer(System.get_env("VGAS_EMBEDDING_DIMENSIONS", "1536")),
    live_calls_enabled: System.get_env("VGAS_AI_LIVE_CALLS_ENABLED") == "true",
    daily_budget_nano_usd: usd_to_nano.(System.get_env("VGAS_AI_DAILY_BUDGET_USD", "0.25")),
    monthly_budget_nano_usd: usd_to_nano.(System.get_env("VGAS_AI_MONTHLY_BUDGET_USD", "2.00")),
    max_concurrent_requests:
      String.to_integer(System.get_env("VGAS_AI_MAX_CONCURRENT_REQUESTS", "2"))
end
