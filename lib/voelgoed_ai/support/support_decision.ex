defmodule VoelgoedAi.Support.SupportDecision do
  @moduledoc """
  Versioned decision value stored as JSON on the completed run. Casting checks
  shape and bounds. Evidence eligibility and authority belong to the caller.
  """

  use Ash.Type

  @decisions ~w(answer_exact answer_grounded clarify decline handoff greeting)
  @locales ~w(af-ZA en-ZA)
  @reasons ~w(supported ambiguous off_topic human_requested account_specific missing_evidence conflicting_evidence unsafe unavailable greeting)
  @fields [:schema_version, :decision, :locale, :reason_code, :evidence_revision_ids, :reply_text]
  @uuid_v7 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @enforce_keys @fields
  defstruct @fields ++ [purged?: false]

  @type t :: %__MODULE__{
          schema_version: 1,
          decision: String.t(),
          locale: String.t(),
          reason_code: String.t(),
          evidence_revision_ids: [String.t()],
          reply_text: String.t() | nil,
          purged?: boolean()
        }

  @doc "Validate an exact string-keyed map without coercing its values."
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(
        %{
          "schema_version" => 1,
          "decision" => decision,
          "locale" => locale,
          "reason_code" => reason,
          "evidence_revision_ids" => refs,
          "reply_text" => reply
        } = value
      )
      when map_size(value) == 6 and decision in @decisions and locale in @locales and
             reason in @reasons and is_list(refs) and length(refs) <= 6 do
    if valid_refs?(refs) and valid_payload?(decision, refs, reply) do
      {:ok,
       %__MODULE__{
         schema_version: 1,
         decision: decision,
         locale: locale,
         reason_code: reason,
         evidence_revision_ids: refs,
         reply_text: reply
       }}
    else
      :error
    end
  end

  def cast(_), do: :error

  defp valid_refs?(refs) do
    Enum.uniq(refs) == refs and
      Enum.all?(refs, &(is_binary(&1) and byte_size(&1) == 36 and Regex.match?(@uuid_v7, &1)))
  end

  defp valid_payload?("answer_exact", [_], nil), do: true
  defp valid_payload?("answer_grounded", [_ | _], reply), do: valid_reply?(reply, 3_000)
  defp valid_payload?("clarify", [], reply), do: is_nil(reply) or valid_reply?(reply, 500)
  defp valid_payload?(decision, [], nil) when decision in ~w(decline handoff greeting), do: true
  defp valid_payload?(_, _, _), do: false

  defp valid_reply?(text, limit) do
    is_binary(text) and byte_size(text) in 1..limit and String.valid?(text) and
      String.trim(text) != ""
  end

  @impl true
  def storage_type(_), do: :map

  @impl true
  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(%__MODULE__{} = value, _), do: value |> encode() |> cast_persisted()
  def cast_input(value, _), do: cast(value)

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(value, _), do: cast_persisted(value)

  # Omission distinguishes a purged reply from an original decision with a
  # null reply. The public proposal decoder still requires all six fields.
  defp cast_persisted(%{"decision" => kind} = value)
       when kind in ["answer_grounded", "clarify"] and not is_map_key(value, "reply_text") do
    with {:ok, validated} <- cast(Map.put(value, "reply_text", "x")) do
      {:ok, %{validated | reply_text: nil, purged?: true}}
    end
  end

  defp cast_persisted(value), do: cast(value)

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}

  def dump_to_native(%__MODULE__{} = value, _) do
    encoded = encode(value)
    with {:ok, _} <- cast_persisted(encoded), do: {:ok, encoded}
  end

  def dump_to_native(_, _), do: :error

  defp encode(%{purged?: true} = value), do: value |> fields() |> Map.delete("reply_text")
  defp encode(value), do: fields(value)

  defp fields(value), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(value, &1)})
end
