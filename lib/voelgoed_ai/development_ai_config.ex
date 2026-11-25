defmodule VoelgoedAi.DevelopmentAiConfig do
  @moduledoc """
  Loads the approved development inference settings from an environment map.

  Budget values are integer nano-USD. A zero cap leaves no spending allowance.
  Invalid settings raise with the variable name so startup fails without
  printing supplied values.
  """

  @spec load(%{optional(String.t()) => String.t()}) :: keyword()
  def load(env) do
    [
      model: fixed(env, "VGAS_AI_MODEL", "openai:gpt-6-luna"),
      reasoning_effort: fixed(env, "VGAS_AI_REASONING_EFFORT", "none"),
      max_output_tokens: positive_integer(env, "VGAS_AI_MAX_OUTPUT_TOKENS", "500"),
      embedding_model: fixed(env, "VGAS_EMBEDDING_MODEL", "openai:text-embedding-3-small"),
      embedding_dimensions:
        fixed(env, "VGAS_EMBEDDING_DIMENSIONS", "1536") |> String.to_integer(),
      live_calls_enabled: live_calls_enabled(env),
      daily_budget_nano_usd: budget(env, "VGAS_AI_DAILY_BUDGET_USD", "0.25"),
      monthly_budget_nano_usd: budget(env, "VGAS_AI_MONTHLY_BUDGET_USD", "2.00"),
      max_concurrent_requests: positive_integer(env, "VGAS_AI_MAX_CONCURRENT_REQUESTS", "2")
    ]
  end

  defp fixed(env, name, approved) do
    case Map.get(env, name, approved) do
      ^approved -> approved
      _ -> invalid!(name)
    end
  end

  defp positive_integer(env, name, default) do
    case Integer.parse(Map.get(env, name, default)) do
      {value, ""} when value > 0 -> value
      _ -> invalid!(name)
    end
  end

  defp budget(env, name, default) do
    value = Map.get(env, name, default)

    case Regex.run(~r/\A([0-9]+)(?:\.([0-9]{1,9}))?\z/, value) do
      [_, whole] -> String.to_integer(whole) * 1_000_000_000
      [_, whole, fraction] -> String.to_integer(whole <> String.pad_trailing(fraction, 9, "0"))
      nil -> invalid!(name)
    end
  end

  defp live_calls_enabled(env) do
    name = "VGAS_AI_LIVE_CALLS_ENABLED"

    case Map.get(env, name, "false") do
      "true" -> true
      "false" -> false
      _ -> invalid!(name)
    end
  end

  defp invalid!(name), do: raise(ArgumentError, "Invalid value for #{name}")
end
