defmodule VoelgoedAi.Intelligence.EmbeddingProfile do
  @moduledoc "Versioned profile and the single-locale projection of an approved article."
  @provider "openai"
  @model "text-embedding-3-small"
  @dimensions 1536
  @serialization_version 1
  @max_input_bytes 32_768
  @id :crypto.hash(
        :sha256,
        Jason.encode!([@provider, @model, @dimensions, "cosine", @serialization_version])
      )
      |> Base.encode16(case: :lower)

  def id, do: @id
  def provider, do: @provider
  def model, do: @model
  def dimensions, do: @dimensions

  def input(content, locale) do
    with %{"title" => title, "approved_answer" => answer} = variant <-
           Enum.find(content["localized_content"], &(&1["locale"] == locale)),
         scope = for({key, values} <- Enum.sort(content["applicability"]), do: [key, values]),
         text =
           Jason.encode!([
             @serialization_version,
             locale,
             title,
             Map.get(variant, "alternative_questions", []),
             answer,
             scope
           ]),
         true <- bounded_input?(text) do
      {:ok, text}
    else
      _ -> {:error, :invalid_content}
    end
  end

  @doc "Check the byte envelope used by the synthetic single-input embedding profile."
  def bounded_input?(text) when is_binary(text),
    do: byte_size(text) in 1..@max_input_bytes and String.valid?(text)

  def bounded_input?(_), do: false

  def vector(values) when is_list(values) and length(values) == @dimensions do
    # Reject float32 infinity and detect underflow to zero after rounding.
    with true <- Enum.all?(values, &(is_number(&1) and abs(&1) <= 3.4028234663852886e38)),
         {:ok, vector} <- Ash.Vector.new(values),
         true <- Enum.any?(Ash.Vector.to_list(vector), &(&1 != 0.0)) do
      {:ok, vector}
    else
      _ -> {:error, :invalid_vector}
    end
  end

  def vector(_), do: {:error, :invalid_vector}
end
