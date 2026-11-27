defmodule VoelgoedAi.Support.EvidenceReply do
  @moduledoc """
  Renders exact replies and validates grounded replies against the selected
  public projection. These checks confer no authority to claim or send.
  """

  alias VoelgoedAi.Knowledge.Content
  alias VoelgoedAi.Support.SupportDecision

  @link_fact "https?:\\/\\/[^\\s<>\"()\\[\\]]+|[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}.-]+\\.[\\p{L}]{2,}"
  @amount_scale ~S"(?:hundreds?|honderde?|thousands?|duisende?|millions?|miljoene?|billions?|miljarde?|biljoene?|trillions?|triljoene?|k|m|mn|mln|mm|b|bn|bln|tn|trn)"
  @currency_code ~S"(?:ZAR|USD|EUR|GBP|AUD|CAD|CHF|CNY|INR|JPY|NZD|R)"
  @currency_name ~S"(?:(?:South\s+African|Suid[-‑ ]Afrikaanse|Australian|Canadian|New\s+Zealand|US|U\.S\.|British)\s+)?(?:rande?|dollars?|euros?|pounds?|ponde?|cents?|sente?|penny|pennies|pence|yen|yuan|rupees?|roepees?|francs?|franke?)"
  @currency_label "(?:#{@currency_code}|#{@currency_name})"
  @currency_prefix "(?:\\p{Sc}|(?<![\\p{L}\\p{N}_])#{@currency_label})"
  @minor_currency_suffix ~S"(?:c|ct|cts|p)"
  @percentage_unit ~S"(?:percent(?:age\s+points?)?|persent(?:punt(?:e)?)?|per[-\s]+(?:cent|sent))"

  @english_number ~S"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion|half|quarter)"
  @afrikaans_number ~S"(?:nul|een|twee|drie|vier|vyf|ses|sewe|agt|nege|tien|elf|twaalf|dertien|veertien|vyftien|sestien|sewentien|agtien|ne[ëe]ntien|twintig|dertig|veertig|vyftig|sestig|sewentig|tagtig|negentig|honderd|duisend|miljoen|miljard|biljoen|triljoen|half|kwart)"
  @number_word "(?:#{@english_number}|#{@afrikaans_number})"
  @word_join ~S"[\h‑-]*(?:(?:and|en|point|punt|komma)[\h‑-]*)?"

  # Written quantities are compared as written, including hyphenated and
  # joined Afrikaans number words. Numeric equivalents are not substitutes.
  @written_number ~S"(?<![\p{L}\p{M}\p{N}_])" <>
                    "#{@number_word}(?:#{@word_join}#{@number_word})*" <>
                    ~S"(?![\p{L}\p{M}\p{N}_])"
  @sign ~S"(?:[-+−]\s*|(?:minus|negative|negatief)\h+)"

  # Keep signs, currencies, scales and percent units in the same fact as the
  # quantity. A cited count of 25 cannot validate 25 rand or 25 percent.
  @facts ~r/
    #{@link_fact}
    |
    (?:#{@sign}#{@currency_prefix}\s*|#{@currency_prefix}\s*#{@sign}?|#{@sign}?)
    (?:\p{N}+(?:(?:[.,:\/-]|\h+)\p{N}+)*|#{@written_number})
    (?:(?:\s+|[-‑])?(?:#{@amount_scale}|\p{Sc}|#{@currency_label}|#{@minor_currency_suffix})(?![\p{L}\p{N}_]))*
    (?:\s*(?:%|#{@percentage_unit}(?![\p{L}\p{N}_])))?
  /iux
  @bare_host ~r|\b[a-z][a-z0-9+.-]*://|iu
  @bare_domain ~r/\b(?:[\p{L}\p{N}-]+\.)+[\p{L}]{2,}\b/u
  @unsafe ~r/[\x00-\x08\x0b-\x1f\x7f<>]|!\[|(?:\]\(|\]:)|(?:javascript|data|file|mailto|tel):|\bwww\.|\b(?:password|passwd|api[_ -]?key|secret|bearer|access[_ -]?token)\b|\b(?:sk|ghp|gho)[_\-][a-zA-Z0-9_\-]{8,}/iu

  @doc "Render only when the ordered, locale-qualified references match the decision."
  def render(%SupportDecision{} = decision, evidence) when evidence != [] do
    if Enum.map(evidence, & &1.revision_id) == decision.evidence_revision_ids and
         Enum.all?(evidence, &(&1.locale == decision.locale)) do
      render_answer(decision, evidence)
    else
      {:error, :stale_evidence}
    end
  end

  def render(_, _), do: {:error, :stale_evidence}

  defp render_answer(%{decision: "answer_exact"}, [%{mode: :exact, answer: answer}]),
    do: {:ok, answer}

  defp render_answer(%{decision: "answer_grounded", reply_text: reply}, evidence) do
    if Enum.all?(evidence, &(&1.mode == :grounded)) and safe_grounded?(reply, evidence) do
      {:ok, reply}
    else
      {:error, :stale_evidence}
    end
  end

  defp render_answer(_, _), do: {:error, :stale_evidence}

  defp safe_grounded?(reply, evidence) when is_binary(reply) do
    sources = Enum.flat_map(evidence, &[&1.title, &1.answer | &1.steps ++ &1.links])
    approved_facts = sources |> Enum.flat_map(&facts/1) |> MapSet.new()
    links = Enum.flat_map(evidence, & &1.links)

    plain = Regex.replace(~r/#{@link_fact}/iu, reply, " ")

    not Regex.match?(@unsafe, reply) and not Regex.match?(@bare_host, plain) and
      not Regex.match?(@bare_domain, plain) and
      Enum.all?(facts(reply), fn fact ->
        MapSet.member?(approved_facts, fact) and
          (not String.starts_with?(String.downcase(fact), "http") or
             (fact in links and Content.public_link_allowed?(fact)))
      end)
  end

  defp safe_grounded?(_, _), do: false

  defp facts(text) do
    @facts
    |> Regex.scan(text)
    |> Enum.map(fn [fact] -> String.trim_trailing(fact) end)
  end

  @doc "Commit to the exact rendered bytes and the qualified immutable decision."
  def digest(run, text) do
    body =
      {1, run.id, run.claim_generation, run.typed_decision, run.evidence_refs, run.context_digest,
       text}

    :crypto.hash(:sha256, :erlang.term_to_binary(body, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
