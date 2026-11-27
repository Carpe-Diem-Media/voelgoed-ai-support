defmodule VoelgoedAi.Support.DecisionTemplates do
  @moduledoc "Versioned server-owned text and deterministic routes for the shadow workflow."

  alias VoelgoedAi.Support.{DecisionContext, SupportDecision}

  @version "shadow-v1"

  @human_requests [
    "human please",
    "agent please",
    "i want to speak to a human",
    "can i speak to a human",
    "mens asseblief",
    "agent asseblief",
    "ek wil met 'n mens praat",
    "kan ek met 'n mens praat"
  ]
  @greetings ["hi", "hello", "hey", "hallo", "goeiedag", "good morning", "goeiemôre"]
  @clarifications ["help", "please help", "help asseblief", "kan julle help"]
  @off_topic ["tell me a joke", "vertel my 'n grap"]
  @account_specific ["check my account balance", "gaan my rekeningsaldo na"]

  @templates %{
    "en-ZA" => %{
      "greeting" => "Hello! How can we help you?",
      "clarify" => "What do you need help with?",
      "decline" => "I can help with Voelgoed support questions.",
      "handoff" => "Our support team can help with this."
    },
    "af-ZA" => %{
      "greeting" => "Hallo! Hoe kan ons jou help?",
      "clarify" => "Waarmee het jy hulp nodig?",
      "decline" => "Ek kan help met Voelgoed-ondersteuningsvrae.",
      "handoff" => "Ons ondersteuningspan kan hiermee help."
    }
  }

  @doc false
  def version, do: @version

  @doc "Classify exact shortcuts and leave unresolved input for staff."
  @spec decide(DecisionContext.t(), :af | :en, boolean()) :: {:ok, SupportDecision.t()} | :error
  def decide(%DecisionContext{current: [_ | _] = current}, locale, clarification_available?) do
    phrases = Enum.map(current, &normalize(&1.text))
    {decision, reason} = route(phrases, clarification_available?)

    SupportDecision.cast(%{
      "schema_version" => 1,
      "locale" => if(locale == :af, do: "af-ZA", else: "en-ZA"),
      "decision" => decision,
      "reason_code" => reason,
      "evidence_revision_ids" => [],
      "reply_text" => nil
    })
  end

  defp route(phrases, clarification_available?) do
    cond do
      Enum.any?(phrases, &(&1 in @human_requests)) ->
        {"handoff", "human_requested"}

      Enum.any?(phrases, &(&1 in @account_specific)) ->
        {"handoff", "account_specific"}

      Enum.all?(phrases, &(&1 in @greetings)) ->
        {"greeting", "greeting"}

      Enum.all?(phrases, &(&1 in @off_topic)) ->
        {"decline", "off_topic"}

      clarification_available? and Enum.all?(phrases, &(&1 in @clarifications)) ->
        {"clarify", "ambiguous"}

      true ->
        {"handoff", "missing_evidence"}
    end
  end

  defp normalize(text),
    do:
      text
      |> String.trim()
      |> String.downcase()
      |> String.trim_trailing("!")
      |> String.trim_trailing("?")

  @doc "Render the approved template for a deterministic decision and pinned version."
  @spec render(SupportDecision.t(), String.t()) :: {:ok, String.t()} | :error
  def render(%SupportDecision{locale: locale, decision: decision, reply_text: nil}, @version) do
    case get_in(@templates, [locale, decision]) do
      text when is_binary(text) -> {:ok, text}
      nil -> :error
    end
  end

  def render(_, _), do: :error
end
