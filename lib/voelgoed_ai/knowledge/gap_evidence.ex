defmodule VoelgoedAi.Knowledge.GapEvidence do
  @moduledoc false

  # This authority is local to TEST until the owner approves a real topic and
  # staff mapping. Neither the webhook nor a model can supply any of it.
  if Mix.env() == :test do
    alias Ecto.Adapters.SQL
    alias VoelgoedAi.Intelligence.EmbeddingProfile
    alias VoelgoedAi.Knowledge.Content
    alias VoelgoedAi.Repo

    @topic "synthetic_rehearsal_day"
    @reference "synthetic-rehearsal-day-v1"
    @query_options [log: false, telemetry_event: nil, timeout: 1_000]
    @questions %{"en-ZA" => "Synthetic rehearsal day", "af-ZA" => "Sintetiese repetisiedag"}
    @facts %{
      "en-ZA" => %{
        "The rehearsal is on Monday." => :monday,
        "The rehearsal is on Friday." => :friday
      },
      "af-ZA" => %{
        "Die repetisie is op Maandag." => :monday,
        "Die repetisie is op Vrydag." => :friday
      }
    }

    def fixture, do: Application.get_env(:voelgoed_ai, :knowledge_gap_fixture)

    def qualified?(%{prior: [], current: [%{text: text}]}, locale),
      do: Map.fetch(@questions, locale) == {:ok, text}

    def qualified?(_, _), do: false

    def find(%{binding: binding, assistant: assistant}, run, locale, now) do
      with %{binding_id: binding_id, assistant_id: assistant_id, collection_id: collection} <-
             fixture(),
           true <- binding.id == binding_id and assistant.id == assistant_id,
           true <- binding.installation_ref == "synthetic",
           {:ok, rows} <-
             sources(binding_id, assistant_id, collection, run.assistant_revision_id, now),
           {:ok, cause, evidence} <- classify(rows, locale) do
        {:ok,
         %{
           binding_id: binding_id,
           assistant_id: assistant_id,
           collection_id: collection,
           assistant_revision_id: run.assistant_revision_id,
           support_run_id: run.id,
           topic: @topic,
           locale: locale,
           applicability: "general",
           cause: cause,
           evidence: evidence
         }}
      else
        _ -> :none
      end
    end

    def addressable?(gap, revision_id, now) do
      with %{binding_id: binding, assistant_id: assistant, collection_id: collection} <- fixture(),
           true <-
             {binding, assistant, collection} ==
               {gap.binding_id, gap.assistant_id, gap.collection_id},
           {:ok, rows} <- sources(binding, assistant, collection, gap.assistant_revision_id, now),
           true <- gap.topic == @topic and gap.applicability == "general" do
        Enum.any?(rows, fn row ->
          case source(row) do
            {:ok, {^revision_id, _, _, _, facts}} -> Map.has_key?(facts, gap.locale)
            _ -> false
          end
        end)
      else
        _ -> false
      end
    end

    # Start with a positive proof of scope. A missing or withdrawn grant is
    # distinguishable from an empty topic. Keep inactive topic history in the
    # bounded lookup so a revoked or unready source cannot look like absence.
    defp sources(binding, assistant, collection, pin, now) do
      statement = """
      WITH scope AS (
        SELECT c.id, c.security_epoch, s.active_revision_id
        FROM inbox_bindings b
        JOIN assistants s ON s.id = b.assistant_id
        JOIN assistant_revisions current ON current.id = s.active_revision_id
          AND current.assistant_id = s.id AND current.status = 'published'
        JOIN assistant_revisions original ON original.id = $4 AND original.assistant_id = s.id
        JOIN assistant_knowledge_grants live ON live.assistant_revision_id = current.id
        JOIN assistant_knowledge_grants pinned ON pinned.assistant_revision_id = original.id
          AND pinned.collection_id = live.collection_id
        JOIN knowledge_collections c ON c.id = live.collection_id
        WHERE b.id = $1 AND s.id = $2 AND c.id = $3
          AND b.installation_ref = 'synthetic' AND b.status = 'enabled'
          AND b.operating_mode = 'shadow' AND s.status = 'active'
          AND c.audience = 'public' AND c.status = 'active'
          AND NOT EXISTS (
            SELECT 1 FROM assistant_knowledge_grants other
            WHERE other.assistant_revision_id IN (original.id, current.id)
              AND other.collection_id <> c.id
          )
      )
      SELECT scope.security_epoch, scope.active_revision_id, r.id, r.content_hash,
             r.active_index_generation, r.index_epoch, r.content,
             (r.article_status = 'active' AND r.current_revision_id = r.id
              AND r.status = 'published' AND r.review_hash = r.content_hash
              AND r.approved_at IS NOT NULL AND r.approved_by_id IS NOT NULL
              AND r.active_index_profile_id = $7
              AND (r.content->>'effective_from')::timestamptz <= $6
              AND (r.content->>'expires_at' IS NULL OR (r.content->>'expires_at')::timestamptz > $6)),
             ARRAY(
               SELECT e.locale FROM article_embeddings e
               WHERE e.revision_id = r.id AND e.generation = r.active_index_generation
                 AND e.state = 'ready' AND e.vector IS NOT NULL
                 AND e.content_hash = r.content_hash AND e.profile_id = $7
             )
      FROM scope
      LEFT JOIN LATERAL (
        SELECT revisions.*, article.status AS article_status, article.current_revision_id
        FROM articles article
        JOIN article_revisions revisions ON revisions.article_id = article.id
        WHERE article.collection_id = scope.id
          AND revisions.content->>'category' = 'faq'
          AND revisions.content->'applicability' = '{}'::jsonb
          AND revisions.content->'source_references' @> jsonb_build_array(
            jsonb_build_object('kind', 'document', 'ref', $5::text)
          )
          AND revisions.status <> 'superseded'
        ORDER BY revisions.id LIMIT 5
      ) r ON true
      """

      parameters = Enum.map([binding, assistant, collection, pin], &Ecto.UUID.dump!/1)

      with {:ok, %{rows: [_ | _] = rows}} <-
             proof_query(statement, parameters ++ [@reference, now, EmbeddingProfile.id()]),
           true <- length(rows) < 5 do
        {:ok, rows}
      else
        _ -> :none
      end
    end

    @doc false
    def proof_query(statement, parameters) do
      SQL.query!(Repo, "SAVEPOINT knowledge_gap_proof", [], @query_options)

      try do
        with {:ok, _} <-
               SQL.query(Repo, "SET LOCAL statement_timeout = '750ms'", [], @query_options) do
          SQL.query(Repo, statement, parameters, @query_options)
        end
      after
        # This proof only reads. Roll back even on success so its timeout and
        # any query error stay inside the savepoint the caller owns.
        SQL.query!(Repo, "ROLLBACK TO SAVEPOINT knowledge_gap_proof", [], @query_options)
        SQL.query!(Repo, "RELEASE SAVEPOINT knowledge_gap_proof", [], @query_options)
      end
    end

    defp classify([[epoch, active, nil | _]], _locale), do: {:ok, :missing, {epoch, active, []}}

    defp classify([[epoch, active | _] | _] = rows, locale) do
      with sources <- Enum.map(rows, &source/1),
           true <- Enum.all?(sources, &match?({:ok, _}, &1)) do
        inspected = Enum.map(sources, fn {:ok, checked} -> checked end)
        requested = Enum.filter(inspected, &Map.has_key?(elem(&1, 4), locale))
        values = Enum.uniq(Enum.map(requested, &Map.fetch!(elem(&1, 4), locale)))

        case values do
          [] -> {:ok, :insufficient, {epoch, active, Enum.take(inspected, 1)}}
          [_, _] -> {:ok, :conflicting, {epoch, active, incompatible_pair(requested, locale)}}
          [_] -> :none
        end
      else
        _ -> :none
      end
    end

    defp incompatible_pair([first | rest], locale) do
      other = Enum.find(rest, &(elem(&1, 4)[locale] != elem(first, 4)[locale]))
      [first, other]
    end

    defp source([_, _, id, hash, generation, epoch, raw, true, indexed]) do
      with {:ok, ^raw} <- Content.parse(raw),
           true <- Content.hash(raw) == hash,
           true <- raw["response_mode"] == "exact" and raw["sensitive"] != true,
           facts = Map.new(raw["localized_content"], &fact/1),
           true <-
             Enum.all?(facts, fn {locale, value} -> locale in indexed and not is_nil(value) end) do
        {:ok, {Ecto.UUID.load!(id), hash, generation, epoch, facts}}
      else
        _ -> :none
      end
    end

    defp source(_), do: :none

    defp fact(%{"locale" => locale, "title" => title, "approved_answer" => answer} = variant) do
      value =
        if title == @questions[locale] and Map.get(variant, "escalation_conditions", []) == [] and
             Map.get(variant, "steps", []) == [],
           do: get_in(@facts, [locale, answer])

      {locale, value}
    end
  end
end
