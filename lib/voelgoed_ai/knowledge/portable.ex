defmodule VoelgoedAi.Knowledge.Portable do
  @moduledoc "Validates version 1 portable editorial documents before draft-only import."

  alias VoelgoedAi.Knowledge.Content

  @limit 262_144
  @max_articles 10
  @max_revision 9_223_372_036_854_775_807
  @slug ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  def max_articles, do: @max_articles

  def decode(bytes, slug) when is_binary(bytes) and byte_size(bytes) <= @limit do
    with {:ok, raw} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, %{"schema_version" => 1, "collection_slug" => ^slug, "articles" => entries} = doc}
         when map_size(doc) == 3 and is_list(entries) <- unique_objects(raw, 0),
         true <- Enum.count_until(entries, @max_articles + 1) in 1..@max_articles,
         {:ok, entries} <- validate_entries(entries),
         true <- unique?(entries, "slug") and unique?(entries, "article_ref") do
      {:ok, entries}
    else
      _ -> {:error, :invalid_portable_document}
    end
  end

  def decode(_, _), do: {:error, :invalid_portable_document}

  def encode(slug, entries) do
    bytes =
      Jason.encode!(%{"schema_version" => 1, "collection_slug" => slug, "articles" => entries})

    if byte_size(bytes) <= @limit,
      do: {:ok, bytes},
      else: {:error, :export_limit}
  end

  defp validate_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, valid} ->
      case validate_entry(entry) do
        {:ok, entry} -> {:cont, {:ok, [entry | valid]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp validate_entry(
         %{
           "article_ref" => ref,
           "slug" => slug,
           "source_revision_number" => number,
           "source_content_hash" => hash,
           "content" => input
         } = entry
       )
       when map_size(entry) == 5 and is_binary(slug) and is_integer(number) and
              number in 1..@max_revision and is_binary(hash) do
    with true <-
           Content.identifier?(ref) and Regex.match?(@slug, slug) and Content.identifier?(slug),
         {:ok, content} <- Content.parse(input),
         true <- Content.hash(content) == hash do
      {:ok, %{entry | "content" => content}}
    else
      _ -> :error
    end
  end

  defp validate_entry(_), do: :error

  defp unique?(entries, key), do: length(Enum.uniq_by(entries, & &1[key])) == length(entries)

  defp unique_objects(_, depth) when depth > 12, do: :error

  defp unique_objects(%Jason.OrderedObject{values: pairs}, depth) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, found} ->
      with false <- Map.has_key?(found, key),
           {:ok, checked} <- unique_objects(value, depth + 1) do
        {:cont, {:ok, Map.put(found, key, checked)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp unique_objects(values, depth) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, found} ->
      case unique_objects(value, depth + 1) do
        {:ok, checked} -> {:cont, {:ok, [checked | found]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp unique_objects(value, _depth), do: {:ok, value}
end
