defmodule VoelgoedAi.Support.EvidenceReply do
  @moduledoc """
  Renders exact replies and validates grounded replies against the selected
  public projection. These checks confer no authority to claim or send.
  """

  alias VoelgoedAi.Knowledge.Content
  alias VoelgoedAi.Support.SupportDecision

  @link_fact "https?:\\/\\/[^\\s<>\"()\\[\\]]+|[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}.-]+\\.[\\p{L}]{2,}"
  # Keep the scale with its number so a cited R25 cannot validate R25 miljoen.
  @amount_scale ~S"(?:\s+|[-‑])?(?:hundreds?|honderde?|thousands?|duisende?|millions?|miljoene?|billions?|miljarde?|biljoene?|trillions?|triljoene?|k|m|mn|mm|b|bn|tn)(?![\p{L}\p{N}_])"
  @facts ~r/#{@link_fact}|(?:\p{Sc}|(?<!\p{L})(?:ZAR|USD|EUR|GBP|R)\s?)?[-+]?\p{N}+(?:[.,:\/ -]\p{N}+)*(?:#{@amount_scale})*(?:\s*%)?/iu
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
