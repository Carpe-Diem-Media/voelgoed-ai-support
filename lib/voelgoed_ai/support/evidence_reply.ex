defmodule VoelgoedAi.Support.EvidenceReply do
  @moduledoc """
  Renders exact replies and validates grounded replies against the selected
  public projection. These checks confer no authority to claim or send.
  """

  alias VoelgoedAi.Knowledge.Content
  alias VoelgoedAi.Support.SupportDecision

  @url_token ~S|https?:\/\/[^\s<>"]+|
  @link_fact ~r/
    (?<=\()#{@url_token}(?=\)[.,!?;:]*(?:\z|[\s<>"]))
    | #{@url_token}
    | [\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}
  /iux
  @amount_scale ~S"(?:hundreds?|honderde?|thousands?|duisende?|millions?|miljoene?|billions?|miljarde?|biljoene?|trillions?|triljoene?|k|m|mn|mln|mm|b|bn|bln|tn|trn)"
  @currency_code ~S"(?:ZAR|USD|EUR|GBP|AUD|CAD|CHF|CNY|INR|JPY|NZD|R)"
  @currency_name ~S"(?:(?:South\s+African|Suid[-‑ ]Afrikaanse|Australian|Canadian|New\s+Zealand|US|U\.S\.|British)\s+)?(?:rande?|dollars?|euros?|pounds?|ponde?|cents?|sente?|penny|pennies|pence|yen|yuan|rupees?|roepees?|francs?|franke?)"
  @currency_label "(?:#{@currency_code}|#{@currency_name})"
  @currency_prefix "(?:\\p{Sc}|(?<![\\p{L}\\p{N}_])#{@currency_label})"
  @minor_currency_suffix ~S"(?:c|ct|cts|p)"
  @percentage_unit ~S"(?:percent(?:age[\h\p{Pd}]+points?)?|persent(?:punt(?:e)?)?|per[\h\p{Pd}]+(?:cent|sent))"
  @article ~S"(?:a|an|['’]n)"
  @percentage_join "(?:[\\h\\p{Pd}]+(?:(?:of|van)\\h+)?(?:#{@article}\\h+)?)?"

  @english_number ~S"(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)"
  @afrikaans_number ~S"(?:nul|een|twee|drie|vier|vyf|ses|sewe|agt|nege|tien|elf|twaalf|dertien|veertien|vyftien|sestien|sewentien|agtien|ne[ëe]ntien|twintig|dertig|veertig|vyftig|sestig|sewentig|tagtig|negentig|honderd|duisend|miljoen|miljard|biljoen|triljoen)"
  @fraction_word ~S"(?:half|halves|halwe|kwarte?|(?:third|quarter|fourth|fifth|sixth|seventh|eighth|ninth|tenth|hundredth|thousandth|derde|vierde|vyfde|sesde|sewende|agtste|negende|tiende|honderdste|duisendste)s?)"
  @number_word "(?:#{@english_number}|#{@afrikaans_number}|#{@fraction_word})"
  @word_join ~S"[\h\p{Pd}]*(?:(?:and|en|point|punt|komma)[\h\p{Pd}]*)?"
  @implicit_one "(?:#{@article}[\\h\\p{Pd}]+(?=(?:#{@amount_scale}|#{@fraction_word})\\b))?"

  # Written quantities are compared as written, including hyphenated and
  # joined Afrikaans number words. Numeric equivalents are not substitutes.
  @written_number ~S"(?<![\p{L}\p{M}\p{N}_])" <>
                    "#{@implicit_one}#{@number_word}(?:#{@word_join}#{@implicit_one}#{@number_word})*" <>
                    ~S"(?![\p{L}\p{M}\p{N}_])"
  @sign ~S"(?:[-+−]\s*|(?:minus|negative|negatief)\h+)"

  @month ~S"(?:jan(?:uary|uarie)?|feb(?:ruary|ruarie)?|mar(?:ch)?|mrt|maart|apr(?:il)?|may|mei|jun(?:e|ie)?|jul(?:y|ie)?|aug(?:ust(?:us)?)?|sept?(?:ember)?|oct(?:ober)?|okt(?:ober)?|nov(?:ember)?|dec(?:ember)?|des(?:ember)?)"
  @ordinal_day ~S"(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|(?:thir|four|fif|six|seven|eigh|nine)teenth|twentieth|thirtieth|eerste|tweede|derde|vierde|vyfde|sesde|sewende|agtste|negende|tiende|elfde|twaalfde|dertien(?:de)?|veertiende|vyftiende|sestiende|sewentiende|agtiende|ne[ëe]ntiende|twintigste|dertigste)"
  @date_day "(?:\\p{N}{1,2}(?:st|nd|rd|th|ste|de)?|" <>
              "(?:(?:twenty|thirty)[\\h\\p{Pd}]+)?#{@ordinal_day}|#{@written_number})"
  @date_year ~S"(?:\.?(?:,\h*|\h+)\p{N}{2,4})"
  @weekday ~S"(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:rs(?:day)?|r)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|maandag|dinsdag|woensdag|donderdag|vrydag|saterdag|sondag)"
  @weekday_prefix "#{@weekday}\\.?(?:,\\h*|\\h+)"
  @numeric_date ~S"(?:\p{N}{4}-\p{N}{2}-\p{N}{2}|\p{N}{1,2}[.\/-]\p{N}{1,2}[.\/-]\p{N}{2,4})"
  @named_date """
  (?:
    #{@date_day}[\\h\\p{Pd}]+(?:(?:of|van)\\h+)?#{@month}#{@date_year}?
    | #{@month}\\.?[\\h\\p{Pd}]+(?:(?:the|die)\\h+)?(?:#{@date_day}#{@date_year}?|\\p{N}{4})
  )
  """
  @calendar_date "(?:#{@named_date}|#{@numeric_date})"
  @calendar_fact """
  (?:
    #{@weekday}\\.?\\h*\\(\\h*#{@calendar_date}\\h*\\)
    | #{@calendar_date}\\h*\\(\\h*#{@weekday}\\.?\\h*\\)
    | #{@weekday_prefix}#{@calendar_date}
    | #{@named_date}
    | #{@weekday}
  )
  (?![\\p{L}\\p{M}\\p{N}_])
  """

  @number_digits ~S"\p{N}+(?:(?:[.,:\/-]|\h+)\p{N}+)*"
  @mixed_part """
  [\\h\\p{Pd}]+(?:and|en)[\\h\\p{Pd}]+
  (?:\\p{N}+\\h*/\\h*\\p{N}+|(?:#{@written_number}[\\h\\p{Pd}]+)?#{@implicit_one}#{@fraction_word})
  (?![\\p{L}\\p{M}\\p{N}_])
  """
  @quantity """
  (?:#{@sign}#{@currency_prefix}\\s*|#{@currency_prefix}\\s*#{@sign}?|#{@sign}?)
  (?:#{@number_digits}(?:#{@mixed_part})?|#{@written_number})
  (?:(?:\\s+|[-‑])?(?:#{@amount_scale}|\\p{Sc}|#{@currency_label}|#{@minor_currency_suffix})(?![\\p{L}\\p{N}_]))*
  (?:\\s*%|#{@percentage_join}#{@percentage_unit}(?![\\p{L}\\p{M}\\p{N}_]))?
  """
  @between ~r/(?<![\p{L}\p{M}\p{N}_])(?:between|tussen)\h+\z/iu
  @between_join ~r/\A\h+(?:and|en)\h+\z/iu
  @range_join ~r/\A(?:\h*[\p{Pd}−]\h*|\h+(?:to|through|until|till|tot(?:\h+en\h+met)?)\h+)\z/iu
  @horizontal_gap ~r/\A\h*\z/u
  @meridiem ~S"(?:am|pm|vm|nm|[apvn]\.m\.?)"
  @utc_offset ~S"[-+−]\p{N}{2}:?\p{N}{2}"
  @zone "(?:(?:UTC|GMT|SAST|CAT|Z)(?:\\h*#{@utc_offset})?|#{@utc_offset})"
  @clock ~r/
    (?<![\p{L}\p{M}\p{N}_])
    (?:#{@numeric_date}T)?#{@sign}?
    (?:\p{N}{1,2}(?:[:.h]\p{N}{2}(?::\p{N}{2})?)?\h*#{@meridiem}|\p{N}{1,2}[:h]\p{N}{2}(?::\p{N}{2})?)
    (?:\h*(?:#{@zone}|\(\h*#{@zone}\h*\)))*
    (?![\p{L}\p{M}\p{N}_])
  /iux

  # Compare complete calendar dates and quantity expressions. Date qualifiers,
  # range endpoints and units cannot borrow support from separate source facts.
  @fact_patterns [
    calendar: ~r/(?<![\p{L}\p{M}\p{N}_])#{@calendar_fact}/iux,
    clock: @clock,
    quantity: ~r/#{@quantity}/iux
  ]
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

    plain = Regex.replace(@link_fact, reply, " ")

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
    links = fact_spans(text, @link_fact, :link)

    # Mask addresses before scanning other facts. The mask keeps byte offsets
    # and stops matches at the address without discarding adjacent text.
    without_links = Regex.replace(@link_fact, text, &:binary.copy(<<0>>, byte_size(&1)))

    other =
      Enum.flat_map(@fact_patterns, fn {kind, pattern} ->
        fact_spans(without_links, pattern, kind)
      end)

    spans = Enum.sort_by(links ++ other, fn {start, length, _} -> {start, -length} end)

    {_, matched} =
      Enum.reduce(spans, {0, []}, fn
        {start, length, kind}, {next, matches} when start >= next ->
          {start + length, [{start, length, kind} | matches]}

        _, acc ->
          acc
      end)

    matched
    |> Enum.reverse()
    |> join_ranges(text)
    |> Enum.map(&fact_text(&1, text))
  end

  defp fact_spans(text, pattern, kind) do
    for [{start, length}] <- Regex.scan(pattern, text, return: :index, capture: :first) do
      {start, length, kind}
    end
  end

  defp join_ranges(
         [{start, length, kind} = first, {right, width, right_kind} = second | rest],
         text
       )
       when kind != :link and right_kind != :link do
    stop = start + length
    separator = binary_part(text, stop, right - stop)

    signed_right? =
      right_kind == :quantity and String.starts_with?(binary_part(text, right, width), ["-", "−"])

    case range_start(text, start, separator, signed_right?) do
      nil -> [first | join_ranges([second | rest], text)]
      left -> join_ranges([{left, right + width - left, kind} | rest], text)
    end
  end

  defp join_ranges([first | rest], text), do: [first | join_ranges(rest, text)]
  defp join_ranges([], _), do: []

  defp range_start(text, start, separator, signed_right?) do
    cond do
      Regex.match?(@range_join, separator) ->
        start

      signed_right? and Regex.match?(@horizontal_gap, separator) ->
        start

      Regex.match?(@between_join, separator) ->
        between_start(text, start)

      true ->
        nil
    end
  end

  defp fact_text({start, length, :link}, text), do: binary_part(text, start, length)

  defp fact_text({start, length, _}, text) do
    # A written-number span can already contain its two endpoints and "and".
    left = between_start(text, start) || start
    binary_part(text, left, start + length - left)
  end

  defp between_start(text, start) do
    case Regex.run(@between, binary_part(text, 0, start), return: :index) do
      [{left, _}] -> left
      nil -> nil
    end
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
