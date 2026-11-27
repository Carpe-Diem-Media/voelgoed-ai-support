defmodule VoelgoedAi.Knowledge.Content do
  @moduledoc """
  Builds a bounded editorial snapshot shared by staff actions and portable files.

  Version 1 hashes UTF-8 JSON with keys ordered lexically, applicability sets and
  locales sorted, and offset dates normalized to UTC. Text and ordered lists
  retain their original bytes and order. Approval and transport data stay outside
  this snapshot.
  """

  @locales ["af-ZA", "en-ZA"]
  @source_kinds ["document", "sharepoint", "git", "website"]
  @identifier ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,79}\z/
  @email ~r/[^\s@]+@[^\s@]+\.[^\s@]+/u
  @contact_digits ~r/(?:\+?\d[ .()\-]?){10,}/u
  @minute_timestamp ~r/(?<![\p{L}\p{N}_:+-])(?<!\d[ .()\-])([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2})(?![\p{L}\p{N}_:+-]|[ .()\-]\+?\d)/u
  @hash_version 1

  def parse(input) do
    fields = [
      {"category", {:one_of, ["faq"]}},
      {"applicability", {:object, scope_fields()}},
      {"primary_locale", {:one_of, @locales}},
      {"localized_content", {:list, 1, 2, {:object, locale_fields()}}},
      {"source_references", {:list, 0, 8, {:object, source_fields()}}},
      {"response_mode", {:one_of, ["exact", "grounded", "escalate_only"]}},
      {"effective_from", :utc},
      {"expires_at", {:optional, :utc}},
      {"review_due_at", {:optional, :utc}},
      {"sensitive", {:optional, :boolean}},
      {"time_sensitive", {:optional, :boolean}}
    ]

    with {:ok, content} <- value({:object, fields}, input),
         locales = Enum.map(content["localized_content"], & &1["locale"]),
         true <- length(locales) == length(Enum.uniq(locales)),
         true <- content["primary_locale"] in locales,
         true <- valid_dates?(content),
         true <-
           content["response_mode"] == "escalate_only" or
             Enum.all?(content["localized_content"], &Map.has_key?(&1, "approved_answer")) do
      {:ok,
       content
       |> Map.update!("localized_content", &Enum.sort_by(&1, fn variant -> variant["locale"] end))
       |> Map.update!(
         "applicability",
         &Map.new(&1, fn {kind, refs} -> {kind, Enum.sort(Enum.uniq(refs))} end)
       )}
    else
      _ -> {:error, :invalid_content}
    end
  end

  def reviewable?(content), do: content["source_references"] != []

  def version, do: @hash_version

  def hash(content) do
    bytes = Jason.encode!([@hash_version, ordered_json(content)])
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  def identifier?(text), do: match?({:ok, _}, value(:identifier, text))

  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, ordered_json(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value

  defp scope_fields do
    Enum.map(~w(brand product event service), &{&1, {:optional, {:list, 1, 8, :identifier}}})
  end

  # Locale content and source references are distinct, closed value objects.
  defp locale_fields do
    [
      {"locale", {:one_of, @locales}},
      {"title", {:text, 160}},
      {"alternative_questions", {:optional, {:list, 0, 8, {:text, 320}}}},
      {"approved_answer", {:optional, {:text, 4_096}}},
      {"steps", {:optional, {:list, 0, 12, {:text, 480}}}},
      {"escalation_conditions", {:optional, {:list, 0, 8, {:text, 320}}}}
    ]
  end

  defp source_fields do
    [
      {"kind", {:one_of, @source_kinds}},
      {"ref", :identifier},
      {"version", {:optional, :identifier}},
      {"date", {:optional, :date}},
      {"public_link", {:optional, :public_link}}
    ]
  end

  defp valid_dates?(content) do
    {effective, expiry} = {content["effective_from"], content["expires_at"]}

    case expiry do
      nil ->
        content["time_sensitive"] != true

      timestamp ->
        {:ok, starts, _} = DateTime.from_iso8601(effective)
        {:ok, ends, _} = DateTime.from_iso8601(timestamp)
        DateTime.compare(starts, ends) == :lt
    end
  end

  defp value({:object, fields}, input) when is_map(input) do
    if Enum.all?(Map.keys(input), &List.keymember?(fields, &1, 0)) do
      Enum.reduce_while(fields, {:ok, %{}}, fn {key, type}, {:ok, fields} ->
        case {Map.fetch(input, key), type} do
          {:error, {:optional, _}} ->
            {:cont, {:ok, fields}}

          {{:ok, item}, type} ->
            case value(type, item) do
              {:ok, normalized} -> {:cont, {:ok, Map.put(fields, key, normalized)}}
              :error -> {:halt, :error}
            end

          _ ->
            {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp value({:optional, type}, item), do: value(type, item)

  defp value({:list, min, max, type}, items) when is_list(items) do
    if Enum.count_until(items, max + 1) in min..max do
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, reversed} ->
        case value(type, item) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | reversed]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp value({:one_of, allowed}, item), do: if(item in allowed, do: {:ok, item}, else: :error)
  defp value(:boolean, item) when is_boolean(item), do: {:ok, item}

  defp value(:identifier, text) when is_binary(text) and byte_size(text) in 1..80 do
    if Regex.match?(@identifier, text) and not Regex.match?(@contact_digits, text),
      do: {:ok, text},
      else: :error
  end

  defp value({:text, max}, text) when is_binary(text) and byte_size(text) in 1..max//1 do
    if String.valid?(text) and String.trim(text) != "" and not String.contains?(text, <<0>>) and
         not Regex.match?(@email, text) and
         not Regex.match?(@contact_digits, mask_timestamps(text)),
       do: {:ok, text},
       else: :error
  end

  defp value(:utc, text) when is_binary(text) and byte_size(text) in 20..32 do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} ->
        {microseconds, _precision} = dt.microsecond
        precision = if microseconds == 0, do: 0, else: 6
        {:ok, DateTime.to_iso8601(%{dt | microsecond: {microseconds, precision}})}

      _ ->
        :error
    end
  end

  defp value(:date, text) when is_binary(text) and byte_size(text) == 10 do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> :error
    end
  end

  defp value(:public_link, text) when is_binary(text) and byte_size(text) in 1..512 do
    if public_link_allowed?(text), do: {:ok, text}, else: :error
  end

  defp value(_, _), do: :error

  defp mask_timestamps(text) do
    # Break digit runs in the scan copy only. The original bytes are hashed and stored.
    Regex.replace(@minute_timestamp, text, fn original, date, time ->
      with {:ok, _} <- Date.from_iso8601(date),
           {:ok, _} <- Time.from_iso8601(time <> ":00") do
        "|"
      else
        _ -> original
      end
    end)
  end

  @doc false
  def public_link_allowed?(text), do: text in public_link_fixture()

  # Real public links await the owner's policy. No source is fetched here.
  if Mix.env() == :test do
    defp public_link_fixture, do: ["https://faq.example.test/synthetic"]
  else
    defp public_link_fixture, do: []
  end
end
