defmodule VoelgoedAi.DevelopmentAiConfigTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.DevelopmentAiConfig

  test "defaults use the approved development profiles and disable live calls" do
    assert DevelopmentAiConfig.load(%{}) == [
             model: "openai:gpt-6-luna",
             reasoning_effort: "none",
             max_output_tokens: 500,
             embedding_model: "openai:text-embedding-3-small",
             embedding_dimensions: 1536,
             live_calls_enabled: false,
             daily_budget_nano_usd: 250_000_000,
             monthly_budget_nano_usd: 2_000_000_000,
             max_concurrent_requests: 2
           ]
  end

  test "supports an explicit live opt-in and exact budgets, including zero" do
    config =
      DevelopmentAiConfig.load(%{
        "VGAS_AI_LIVE_CALLS_ENABLED" => "true",
        "VGAS_AI_DAILY_BUDGET_USD" => "0",
        "VGAS_AI_MONTHLY_BUDGET_USD" => "0.000000001",
        "VGAS_AI_MAX_OUTPUT_TOKENS" => "250",
        "VGAS_AI_MAX_CONCURRENT_REQUESTS" => "1"
      })

    assert config[:live_calls_enabled]
    assert config[:daily_budget_nano_usd] == 0
    assert config[:monthly_budget_nano_usd] == 1
    assert config[:max_output_tokens] == 250
    assert config[:max_concurrent_requests] == 1
  end

  for {name, value} <- [
        {"VGAS_AI_MAX_OUTPUT_TOKENS", "-1"},
        {"VGAS_AI_MAX_OUTPUT_TOKENS", "0"},
        {"VGAS_AI_MAX_OUTPUT_TOKENS", "500tokens"},
        {"VGAS_AI_DAILY_BUDGET_USD", "-0.25"},
        {"VGAS_AI_MONTHLY_BUDGET_USD", "NaN"},
        {"VGAS_AI_MONTHLY_BUDGET_USD", "0.0000000001"},
        {"VGAS_AI_MAX_CONCURRENT_REQUESTS", "0"},
        {"VGAS_EMBEDDING_DIMENSIONS", "0"},
        {"VGAS_EMBEDDING_DIMENSIONS", "768"},
        {"VGAS_AI_REASONING_EFFORT", "high"},
        {"VGAS_AI_MODEL", "openai:unapproved"},
        {"VGAS_EMBEDDING_MODEL", "openai:unapproved"},
        {"VGAS_AI_LIVE_CALLS_ENABLED", "TRUE"}
      ] do
    @tag name: name, value: value
    test "rejects #{name} set to #{value}", %{name: name, value: value} do
      assert_raise ArgumentError, "Invalid value for #{name}", fn ->
        DevelopmentAiConfig.load(%{name => value})
      end
    end
  end
end
