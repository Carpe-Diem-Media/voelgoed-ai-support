defmodule VoelgoedAi.Governance.EmbeddingAccountingTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.Governance.EmbeddingAccounting
  alias VoelgoedAi.Intelligence.EmbeddingProfile

  test "price uses integer ceiling and rejects overflow and malformed usage" do
    price = %{version: "fixture-v1", rate_nano_usd: 5, token_unit: 2, max_input_tokens: 8192}
    assert {:ok, 3} = EmbeddingAccounting.cost(1, price)
    assert {:ok, 8} = EmbeddingAccounting.cost(3, price)
    assert {:ok, 22_517_998_136_852_483} = EmbeddingAccounting.cost(9_007_199_254_740_993, price)
    assert {:error, :invalid_usage} = EmbeddingAccounting.cost(1.0, price)
    max = 9_223_372_036_854_775_807
    assert {:error, :amount_overflow} = EmbeddingAccounting.cost(max, price)

    assert {:ok, ^max} =
             EmbeddingAccounting.cost(max, %{price | rate_nano_usd: max, token_unit: max})

    assert {:error, :invalid_usage} = EmbeddingAccounting.cost(max + 1, price)
  end

  test "article embedding serializes scoped content deterministically" do
    content =
      VoelgoedAi.KnowledgeFixtures.payload()
      |> Map.put("applicability", %{"event" => ["evt"], "brand" => ["brand"]})

    assert {:ok, input} = EmbeddingProfile.input(content, "en-ZA")

    assert [
             1,
             "en-ZA",
             "Synthetic FAQ",
             [],
             "Synthetic answer.",
             [["brand", ["brand"]], ["event", ["evt"]]]
           ] = Jason.decode!(input)
  end

  test "a vector has exact dimension and a finite nonzero float32 representation" do
    assert {:ok, _} = EmbeddingProfile.vector([1.0 | List.duplicate(0.0, 1535)])
    assert {:error, :invalid_vector} = EmbeddingProfile.vector(List.duplicate(0.0, 1536))
    assert {:error, :invalid_vector} = EmbeddingProfile.vector(List.duplicate(1.0e-60, 1536))
    assert {:error, :invalid_vector} = EmbeddingProfile.vector(List.duplicate(1.0e100, 1536))
    assert {:error, :invalid_vector} = EmbeddingProfile.vector([1.0])
  end
end
