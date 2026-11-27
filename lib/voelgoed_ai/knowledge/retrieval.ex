defmodule VoelgoedAi.Knowledge.Retrieval do
  @moduledoc """
  Searches and revalidates approved evidence under the live support claim.
  The control lock serializes eligibility changes with each database phase.
  Transport runs between those phases, after the dispatch fence commits.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  @enforce_keys [:ref]
  defstruct [:ref]

  @impl Ash.Policy.Check
  def describe(_), do: "the current support claim holds the capability for this action"

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Intelligence.EmbeddingProfile
  alias VoelgoedAi.Knowledge.Content
  alias VoelgoedAi.Knowledge.Retrieval.Reference
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, Delivery}

  # All entry points use this CTE. Control is locked before it runs, and
  # editorial and grant changes take the same lock before writing.
  @eligible """
  WITH eligible AS MATERIALIZED (
    SELECT r.id AS revision_id, a.id AS article_id, a.article_ref, c.id AS collection_id,
           c.security_epoch AS collection_epoch, r.content_hash, r.active_index_generation,
           r.index_epoch, v.vector, r.content, variant.value AS variant
    FROM assistant_knowledge_grants pinned
    JOIN assistant_knowledge_grants live
      ON live.collection_id = pinned.collection_id AND live.assistant_revision_id = $2
    JOIN knowledge_collections c ON c.id = live.collection_id
    JOIN articles a ON a.collection_id = c.id
    JOIN article_revisions r ON r.id = a.current_revision_id AND r.article_id = a.id
    JOIN article_embeddings v ON v.revision_id = r.id AND v.generation = r.active_index_generation
    CROSS JOIN LATERAL jsonb_array_elements(r.content->'localized_content') AS variant(value)
    WHERE pinned.assistant_revision_id = $1 AND c.audience = 'public' AND c.status = 'active'
      AND a.status = 'active' AND r.status = 'published' AND r.review_hash = r.content_hash
      AND r.approved_at IS NOT NULL AND r.approved_by_id IS NOT NULL
      AND v.state = 'ready' AND v.vector IS NOT NULL AND v.locale = $3
      AND variant.value->>'locale' = $3 AND v.content_hash = r.content_hash
      AND r.active_index_profile_id = $4 AND v.profile_id = $4
      AND r.content->>'response_mode' IN ('exact', 'grounded')
      AND coalesce(r.content->>'sensitive', 'false') = 'false'
      AND (r.content->>'effective_from')::timestamptz <= $5
      AND (r.content->>'expires_at' IS NULL OR (r.content->>'expires_at')::timestamptz > $5)
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_each(r.content->'applicability') AS restriction(key, allowed)
        WHERE NOT coalesce(restriction.allowed ? ($6::jsonb->>restriction.key), false)
      )
  )
  """
  @projection """
    e.revision_id, e.article_id, e.article_ref, e.collection_id, e.collection_epoch,
    e.content_hash, e.active_index_generation, e.index_epoch, e.content
  """
  if Mix.env() == :test do
    alias VoelgoedAi.Intelligence.Embedding
    alias VoelgoedAi.Knowledge.ArticleRevision
    alias VoelgoedAi.Knowledge.Retrieval.Scope
    alias VoelgoedAi.Support.{Ownership, RunProcessing}

    @scope_keys [:brand, :product, :event, :service]
    @authority_key {__MODULE__, :authority}
    @inbox_keys [:installation_ref, :external_account_id, :external_inbox_id]
    @manifest_key {__MODULE__, :manifest}
    @query_key {__MODULE__, :query}
    @rank_measurement_key {__MODULE__, :rank_measurement}

    @manifest_limit 4
    @lexeme_byte_limit 2_048

    @rank """
    , words AS (
      SELECT to_tsquery('simple', string_agg(quote_literal(lexeme), ' | ')) AS query
      FROM unnest($7::text[]) AS lexeme
    ), semantic AS (
      SELECT revision_id, row_number() OVER (ORDER BY distance, revision_id) AS rank
      FROM (
        SELECT revision_id, vector <=> $8::vector AS distance
        FROM eligible
        ORDER BY distance, revision_id LIMIT 10
      ) ranked
    ), lexical AS (
      SELECT revision_id, row_number() OVER (ORDER BY score DESC, revision_id) AS rank
      FROM (
        SELECT revision_id, ts_rank(document, query) AS score
        FROM eligible CROSS JOIN words
        CROSS JOIN LATERAL (
          SELECT to_tsvector('simple', concat_ws(' ', variant->>'title',
            (SELECT string_agg(question, ' ') FROM jsonb_array_elements_text(
              variant->'alternative_questions') AS question),
            variant->>'approved_answer')) AS document
        ) text
        WHERE document @@ query
        ORDER BY score DESC, revision_id LIMIT 10
      ) ranked
    )
    SELECT #{@projection}, semantic.rank, lexical.rank
    FROM (semantic FULL JOIN lexical USING (revision_id))
    JOIN eligible e USING (revision_id)
    """

    # Use the same lexemes as the ranker. Remove only function words and
    # politeness markers, retaining negations, actions, qualifiers and IDs.
    @function_words %{
      "en-ZA" => ~w(a an and the please),
      "af-ZA" => ~w('n aan asseblief die en oor)
    }

    @coverage """
    , topic AS (
      SELECT tsvector_to_array(to_tsvector('simple', $7::text)) AS current_words,
             tsvector_to_array(to_tsvector('simple', $8::text)) AS prior_words
    ), query_terms AS (
      SELECT ARRAY(SELECT unnest(current_words) EXCEPT SELECT unnest($9::text[])) AS current_terms,
             ARRAY(SELECT unnest(prior_words) EXCEPT SELECT unnest($9::text[])) AS prior_terms
      FROM topic
    ), covering AS (
      SELECT e.revision_id,
             jsonb_array_length(coalesce(e.variant->'escalation_conditions', '[]')) > 0
               AS conditional,
             bool_and(NOT (authored.terms <@ q.current_terms)) AS needs_prior
      FROM eligible e CROSS JOIN query_terms q
      CROSS JOIN LATERAL jsonb_array_elements_text(
        coalesce(e.variant->'alternative_questions', '[]') || jsonb_build_array(e.variant->>'title')
      ) AS question(value)
      CROSS JOIN LATERAL (
        SELECT ARRAY(
          SELECT unnest(tsvector_to_array(to_tsvector('simple', question.value)))
          EXCEPT SELECT unnest($9::text[])
        ) AS terms
      ) AS authored
      WHERE cardinality(q.current_terms) BETWEEN 1 AND 64
        AND cardinality(q.prior_terms) <= 64
        AND q.current_terms <@ authored.terms
        AND (authored.terms <@ q.current_terms
          OR (q.prior_terms <@ authored.terms AND authored.terms <@ (q.current_terms || q.prior_terms)))
      GROUP BY e.revision_id, conditional
    )
    SELECT revision_id, conditional, needs_prior FROM covering ORDER BY revision_id LIMIT 2
    """

    @impl Ash.Policy.SimpleCheck
    def match?(%__MODULE__{ref: ref}, %{subject: %Ash.ActionInput{} = input}, _)
        when is_reference(ref) do
      input.resource == ArticleRevision and
        case authority() do
          %{refs: refs} -> refs[input.action.name] == ref
          nil -> false
        end
    end

    def match?(_, _, _), do: false

    @doc false
    def authorize_query(ref) when is_reference(ref) do
      case Process.delete(@query_key) do
        {^ref, mode} -> {:ok, mode}
        _ -> {:error, :denied}
      end
    end

    def authorize_query(_), do: {:error, :denied}

    @doc "Issue process-bound search and validation capabilities for a synthetic claim."
    def with_fixture(%{locale: locale, scope: scope} = context, operation)
        when locale in ["af-ZA", "en-ZA"] and is_map(scope) and is_function(operation, 2) do
      with true <- Map.keys(scope) -- @scope_keys == [],
           {:ok, scope} <- Ash.Type.cast_input(Scope, scope),
           {:ok, scope} <- Ash.Type.apply_constraints(Scope, scope, []) do
        fixture_context = Map.take(context, [:run_id, :claim_generation, :inbox, :locale])
        with_authority(Map.put(fixture_context, :scope, scope), operation)
      else
        _ -> {:error, :denied}
      end
    end

    def with_fixture(_, _), do: {:error, :denied}

    @doc false
    def with_shadow(owner, run, session, observation, receipts, locale, {query, prior}, operation) do
      if worker_owner?(owner) do
        context = %{
          run_id: run.id,
          claim_generation: run.claim_generation,
          inbox: Map.take(session, @inbox_keys),
          locale: locale,
          scope: %{},
          shadow_query: query,
          prior_query: prior,
          observation: observation,
          receipts: receipts
        }

        with_authority(context, fn search, _validate -> operation.(search) end)
      else
        {:error, :denied}
      end
    end

    defp with_authority(context, operation) do
      with nil <- authority(),
           false <- Repo.in_transaction?(),
           {:ok, hash} when is_binary(hash) <-
             qualified(context, fn _config, _run, revision, _now, _ ->
               {:ok, revision.config_hash}
             end) do
        search = %__MODULE__{ref: make_ref()}
        validate = %__MODULE__{ref: make_ref()}
        refs = %{search_published: search.ref, validate_evidence: validate.ref}
        Process.put(@authority_key, Map.merge(context, %{refs: refs, pin_hash: hash}))

        try do
          operation.(search, validate)
        after
          Process.delete(@manifest_key)
          Process.delete(@authority_key)
        end
      else
        _ -> {:error, :denied}
      end
    end

    @doc false
    def worker_owner?(owner) when is_function(owner, 0) do
      info = Function.info(owner)

      info[:type] == :local and info[:module] == RunProcessing and
        info[:name] == :evidence_owner
    end

    def worker_owner?(_), do: false

    @doc false
    def generation_guard(owner, items, observation) do
      with true <- worker_owner?(owner),
           %{shadow_query: _} = context <- authority(),
           [_ | _] <- items,
           manifest = Process.get(@manifest_key, %{}),
           true <- Enum.all?(items, &(&1.mode == :grounded and manifest[&1.citation_id] == &1)) do
        # The Req task has no manifest in its process dictionary. The closure
        # carries only this selected set and requalifies it under its own locks.
        {:ok,
         fn config, session, run, revision ->
           with :ok <- qualified_mode(%{context | observation: observation}, config, session, run) do
             requalify_selected(context, config, run, revision, items)
           end
         end}
      else
        _ -> {:error, :stale_evidence}
      end
    end

    @doc false
    def with_rank_measurement(callback, operation)
        when is_function(callback, 3) and is_function(operation, 0) do
      previous = Process.put(@rank_measurement_key, callback)

      try do
        operation.()
      after
        if previous do
          Process.put(@rank_measurement_key, previous)
        else
          Process.delete(@rank_measurement_key)
        end
      end
    end

    defp authority, do: Process.get(@authority_key)

    @impl Ash.Resource.Actions.Implementation
    def run(input, _, %{actor: actor}) do
      cond do
        not match?(actor, %{subject: input}, []) ->
          {:error, "support retrieval capability required"}

        Repo.in_transaction?() ->
          {:error, "retrieval requires its own transaction"}

        true ->
          execute(input.action.name, input.arguments, authority())
      end
    end

    defp execute(:search_published, %{query: query}, context) do
      Process.delete(@manifest_key)

      case minimize(query) do
        {:ok, query} ->
          if Map.get(context, :shadow_query, query) == query,
            do: search(context, query),
            else: outcome(:denied)

        :error ->
          outcome(:no_evidence)
      end
    end

    defp execute(:validate_evidence, %{citations: ids, used_links: links}, context) do
      manifest = Process.get(@manifest_key, %{})
      selected = Enum.map(ids, &Map.get(manifest, &1))

      with true <- ids != [] and Enum.uniq(ids) == ids and Enum.uniq(links) == links,
           false <- Enum.any?(selected, &is_nil/1),
           {:ok, evidence} <- revalidate(context, selected),
           true <- Enum.all?(links, &Enum.any?(evidence, fn item -> &1 in item.links end)) do
        outcome(:evidence, evidence)
      else
        _ -> outcome(:denied)
      end
    end

    defp search(context, query) do
      with {:ok, {query, lexemes, coverage}} <-
             qualified(context, fn config, run, _revision, now, _ ->
               bindings = params(context, config, run, now)

               with :ok <- check_shadow_lexemes(context),
                    :ok <- has_eligible(bindings),
                    {:ok, coverage} <- coverage(context, bindings),
                    {:ok, query} when is_binary(query) <- rank_query(context, query, coverage),
                    {:ok, %{rows: [[lexemes]]}} <-
                      sql("SELECT tsvector_to_array(to_tsvector('simple', $1))", [query]),
                    true <- length(lexemes) in 1..64 do
                 {:ok, {query, lexemes, coverage}}
               else
                 false -> {:ok, :no_evidence}
                 other -> other
               end
             end),
           context = Map.put(context, :coverage, coverage),
           {:ok, {:query_vector, vector}} <- embed(context, query),
           {:ok, evidence} when is_list(evidence) <- rank(context, lexemes, vector) do
        Process.put(@manifest_key, Map.new(evidence, &{&1.citation_id, &1}))
        outcome(if(evidence == [], do: :no_evidence, else: :evidence), evidence)
      else
        {:ok, status} when status in [:no_evidence, :denied] -> outcome(status)
        _ -> outcome(:unavailable)
      end
    end

    # PostgreSQL drops lexemes at its byte limit. Check the raw parser
    # tokens before the tsvector can erase part of either question.
    defp check_shadow_lexemes(%{shadow_query: query, prior_query: prior})
         when byte_size(query) >= @lexeme_byte_limit or byte_size(prior) >= @lexeme_byte_limit do
      statement = """
      SELECT EXISTS (
        SELECT 1
        FROM unnest(ARRAY[$1::text, $2::text]) AS input(text)
        CROSS JOIN LATERAL ts_parse('default', input.text) AS parsed
        WHERE octet_length(parsed.token) >= $3
      )
      """

      case sql(statement, [query, prior, @lexeme_byte_limit]) do
        {:ok, %{rows: [[true]]}} -> {:ok, :no_evidence}
        {:ok, %{rows: [[false]]}} -> :ok
        error -> error
      end
    end

    defp check_shadow_lexemes(_), do: :ok

    defp rank_query(%{prior_query: prior}, query, [{_, false, true}]) do
      case minimize(query <> "\n" <> prior) do
        {:ok, _} = bounded -> bounded
        :error -> {:ok, :no_evidence}
      end
    end

    defp rank_query(_, query, _), do: {:ok, query}

    defp embed(context, query) do
      ref = make_ref()
      mode = if Map.has_key?(context, :shadow_query), do: :shadow, else: :fixture
      Process.put(@query_key, {ref, mode})

      try do
        Embedding.query(ref, query, fn work ->
          qualified(context, fn config, run, _revision, now, deadline ->
            with :ok <- check_search_pin(context, config, run, now),
                 true <- DateTime.before?(ChatwootAdapter.now(), deadline) do
              work.(config.control, run, deadline)
            else
              _ -> {:error, :stale_request}
            end
          end)
        end)
      after
        Process.delete(@query_key)
      end
    end

    defp rank(context, lexemes, vector) do
      qualified(context, fn config, run, revision, now, _ ->
        bindings = params(context, config, run, now) ++ [lexemes, vector]

        with :ok <- check_rank_pin(context, config, run, now),
             {:ok, %{rows: rows}} <- measured_rank(bindings),
             {:ok, ranked} when is_list(ranked) <- select_ranked(context, sort_ranked(rows)) do
          evidence =
            Enum.flat_map(ranked, fn {_, _, row} ->
              case project(row, context, run, revision, Ash.UUIDv7.generate()) do
                {:ok, item} -> [item]
                :error -> []
              end
            end)

          {:ok, Enum.take(evidence, @manifest_limit)}
        end
      end)
    end

    defp measured_rank(bindings) do
      statement = @eligible <> @rank
      result = sql(statement, bindings)

      if callback = Process.get(@rank_measurement_key),
        do: callback.(statement, bindings, result)

      result
    end

    # Ranking finds bounded candidates. A nearest neighbour, rank advantage
    # or UUID tie break cannot supply missing coverage or resolve a conflict.
    defp select_ranked(%{coverage: [{covered, false, _}]}, ranked) do
      shortlist = Enum.take(ranked, @manifest_limit)
      {:ok, Enum.filter(shortlist, fn {id, _, _} -> id == covered end)}
    end

    defp select_ranked(%{coverage: []}, _), do: {:ok, :no_evidence}
    defp select_ranked(%{coverage: :fixture}, ranked), do: {:ok, ranked}
    defp select_ranked(_, _), do: {:ok, :denied}

    @doc false
    def sort_fixture_ranks(rows), do: sort_ranked(rows)

    defp sort_ranked(rows) do
      rows
      |> Enum.map(fn row ->
        {data, [semantic, lexical]} = Enum.split(row, -2)
        {hd(data), rrf(semantic, lexical), data}
      end)
      |> Enum.sort(fn {left_id, {ln, ld}, _}, {right_id, {rn, rd}, _} ->
        ln * rd > rn * ld or (ln * rd == rn * ld and left_id <= right_id)
      end)
    end

    defp rrf(nil, rank), do: {1, 60 + rank}
    defp rrf(rank, nil), do: {1, 60 + rank}
    defp rrf(semantic, lexical), do: {120 + semantic + lexical, (60 + semantic) * (60 + lexical)}

    defp revalidate(context, selected) do
      qualified(context, fn config, run, revision, now, _ ->
        with {:ok, current} <- reproject(config, run, revision, selected, now),
             true <- current == selected do
          {:ok, selected}
        else
          false -> {:error, :stale_evidence}
          error -> error
        end
      end)
    end

    @doc false
    def at_decision(owner, config, run, citations) when is_list(citations) do
      with true <- stage_owner?(owner, RunProcessing),
           %{run_id: id, claim_generation: claim} = context <- authority(),
           true <- id == run.id and claim == run.claim_generation and claim > 0,
           true <- run.state == :running,
           true <- length(citations) in 1..4 and Enum.uniq(citations) == citations,
           manifest = Process.get(@manifest_key, %{}),
           selected = Enum.map(citations, &Map.get(manifest, &1)),
           false <- Enum.any?(selected, &is_nil/1),
           {:ok, revision} <- Configuration.current_revision(config.assistant),
           true <- revision.config_hash == context.pin_hash,
           {:ok, current} <- requalify_selected(context, config, run, revision, selected) do
        {:ok, current}
      else
        {:error, error} when is_exception(error) -> {:error, error}
        _ -> {:error, :stale_evidence}
      end
    end

    defp qualified(%{run_id: id, inbox: inbox, claim_generation: claim} = context, work) do
      RunProcessing.with_run(id, fn config, session, run, now ->
        with true <- run.session_id == session.id and session.binding_id == config.binding.id,
             true <-
               inbox == Map.take(session, @inbox_keys) and
                 inbox == Map.take(config.binding, @inbox_keys),
             true <- RunProcessing.valid_run?(config, session, run),
             :ok <- qualified_mode(context, config, session, run),
             true <- run.state == :running and run.claim_generation == claim and claim > 0,
             deadline = Enum.min([run.deadline_at, run.lease_expires_at], DateTime),
             :lt <- DateTime.compare(now, deadline),
             {:ok, revision} <- Configuration.current_revision(config.assistant),
             true <-
               revision.id == run.assistant_revision_id and
                 revision.assistant_id == config.assistant.id,
             true <- Map.get(context, :pin_hash, revision.config_hash) == revision.config_hash do
          work.(config, run, revision, now, deadline)
        else
          _ -> {:error, :stale_claim}
        end
      end)
      |> case do
        {:ok, :missing} -> {:error, :stale_claim}
        result -> result
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end

    defp qualified(_, _), do: {:error, :stale_claim}

    defp qualified_mode(
           %{shadow_query: _, observation: observation, receipts: receipts},
           config,
           session,
           run
         ) do
      with true <- Ownership.shadow_evaluation_enabled?(config),
           true <- Ownership.eligible_bot?(config, session, observation),
           {:ok, ^receipts} <- RunProcessing.covered_receipts(session, run),
           {:ok, false} <- Ownership.pending_input?(session) do
        :ok
      else
        _ -> {:error, :stale_claim}
      end
    end

    defp qualified_mode(_, config, _, _) do
      if Ownership.write_enabled?(config) or Ownership.shadow_evaluation_enabled?(config),
        do: :ok,
        else: {:error, :stale_claim}
    end

    defp requalify_selected(context, config, run, revision, selected) do
      now = ChatwootAdapter.now()

      with {:ok, current} <- reproject(config, run, revision, selected, now),
           true <- current == selected,
           :ok <- check_coverage(context, config, run, now, selected) do
        {:ok, current}
      else
        {:error, error} when is_exception(error) -> {:error, error}
        _ -> {:error, :stale_evidence}
      end
    end

    # Pin the bounded coverage result across embedding. An unrelated decoy
    # may appear in either rank branch but cannot replace a lost subject.
    defp check_search_pin(context, config, run, now) do
      bindings = params(context, config, run, now)

      with :ok <- has_eligible(bindings),
           {:ok, current} <- coverage(context, bindings),
           true <- current == context.coverage do
        :ok
      else
        _ -> {:error, :stale_evidence}
      end
    end

    defp check_rank_pin(%{shadow_query: _} = context, config, run, now),
      do: check_search_pin(context, config, run, now)

    defp check_rank_pin(_, _, _, _), do: :ok

    defp check_coverage(%{shadow_query: _} = context, config, run, now, [%{revision_id: id}]) do
      selected = uuid(id)

      case coverage(context, params(context, config, run, now)) do
        {:ok, [{^selected, false, _}]} -> :ok
        {:error, _} = error -> error
        _ -> {:error, :stale_evidence}
      end
    end

    defp check_coverage(%{shadow_query: _}, _, _, _, _), do: {:error, :stale_evidence}
    defp check_coverage(_, _, _, _, _), do: :ok

    # Each current term must be covered by the same authored title or
    # alternative. Only an explicit, topically linked continuation can use
    # prior contact terms to fill a missing part. Inspect at most two subjects
    # so a conflicting variant outside the rank limits still forces triage.
    defp coverage(%{shadow_query: query, prior_query: prior, locale: locale}, bindings) do
      with {:ok, %{rows: rows}} <-
             sql(@eligible <> @coverage, bindings ++ [query, prior, @function_words[locale]]) do
        {:ok, Enum.map(rows, &List.to_tuple/1)}
      end
    end

    defp coverage(_, _), do: {:ok, :fixture}

    defp has_eligible(params) do
      case sql(@eligible <> "SELECT EXISTS (SELECT 1 FROM eligible)", params) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, %{rows: [[false]]}} -> {:ok, :no_evidence}
        error -> error
      end
    end

    defp minimize(text) when byte_size(text) <= 12_000 do
      if String.valid?(text) and not String.contains?(text, <<0>>) and
           length(String.codepoints(text)) <= 3_000,
         do: {:ok, String.trim(text)},
         else: :error
    end

    defp minimize(_), do: :error

    defp outcome(status, evidence \\ []), do: {:ok, %{status: status, evidence: evidence}}
  else
    @impl Ash.Policy.SimpleCheck
    def match?(_, _, _), do: false

    @impl Ash.Resource.Actions.Implementation
    def run(_, _, _), do: {:error, "support retrieval is disabled"}
  end

  @doc false
  def at_dispatch(owner, config, %{state: :completed, claim_generation: claim} = run)
      when claim > 0 do
    with true <- stage_owner?(owner, Delivery),
         refs when is_list(refs) and length(refs) in 1..4 <- run.evidence_refs,
         {:ok, revision} <- Configuration.current_revision(config.assistant),
         true <- revision.id == run.assistant_revision_id,
         {:ok, current} <- reproject(config, run, revision, refs, ChatwootAdapter.now()),
         true <- Enum.map(current, &Reference.from_evidence/1) == refs do
      {:ok, current}
    else
      {:error, error} when is_exception(error) -> {:error, error}
      _ -> {:error, :stale_evidence}
    end
  end

  def at_dispatch(_, _, _), do: {:error, :stale_evidence}

  defp stage_owner?(owner, module) when is_function(owner, 0) do
    info = Function.info(owner)

    Repo.in_transaction?() and info[:type] == :local and info[:module] == module and
      info[:name] == :evidence_owner
  end

  defp stage_owner?(_, _), do: false

  defp reproject(config, run, revision, [first | _] = selected, now) do
    ids = Enum.map(selected, &uuid(&1.revision_id))

    with true <- Enum.uniq(ids) == ids,
         true <- Enum.all?(selected, &(&1.locale == first.locale and &1.scope == first.scope)),
         {:ok, %{rows: rows}} <-
           sql(
             @eligible <>
               "SELECT #{@projection} FROM eligible e WHERE e.revision_id = ANY($7::uuid[])",
             params(first, config, run, now) ++ [ids]
           ) do
      by_id = Map.new(rows, &{hd(&1), &1})
      observed_at = ChatwootAdapter.now()

      Enum.zip(ids, selected)
      |> Enum.reduce_while({:ok, []}, fn {id, item}, {:ok, evidence} ->
        row = by_id[id]

        with true <- current_at?(row, observed_at),
             {:ok, current} <- project(row, first, run, revision, Map.get(item, :citation_id)) do
          {:cont, {:ok, [current | evidence]}}
        else
          _ -> {:halt, {:error, :stale_evidence}}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    else
      false -> {:error, :stale_evidence}
      error -> error
    end
  end

  defp current_at?([_, _, _, _, _, _, _, _, %{"expires_at" => expires}], now)
       when is_binary(expires) do
    with {:ok, expiry, _} <- DateTime.from_iso8601(expires), do: DateTime.before?(now, expiry)
  end

  defp current_at?(row, _now), do: is_list(row)

  defp project(
         [id, article, ref, collection, epoch, hash, generation, index_epoch, raw],
         context,
         run,
         revision,
         citation
       ) do
    with {:ok, content} <- Content.parse(raw),
         true <- raw == content and Content.hash(content) == hash,
         %{"title" => title, "approved_answer" => answer} = variant <-
           Enum.find(content["localized_content"], &(&1["locale"] == context.locale)) do
      links =
        content["source_references"]
        |> Enum.map(& &1["public_link"])
        |> Enum.filter(&Content.public_link_allowed?/1)
        |> Enum.uniq()

      {:ok,
       %{
         citation_id: citation,
         run_id: run.id,
         claim_generation: run.claim_generation,
         assistant_revision_id: revision.id,
         assistant_hash: revision.config_hash,
         article_id: Ecto.UUID.load!(article),
         revision_id: Ecto.UUID.load!(id),
         article_ref: ref,
         locale: context.locale,
         content_hash: hash,
         mode: mode(content["response_mode"]),
         profile_id: EmbeddingProfile.id(),
         generation: generation,
         index_epoch: index_epoch,
         collection_id: Ecto.UUID.load!(collection),
         collection_epoch: epoch,
         scope: context.scope,
         assistant_epoch: run.assistant_epoch,
         binding_epoch: run.binding_epoch,
         control_epoch: run.control_epoch,
         ownership_epoch: run.ownership_epoch,
         title: title,
         answer: answer,
         steps: Map.get(variant, "steps", []),
         links: links
       }}
    else
      _ -> :error
    end
  end

  defp project(_, _, _, _, _), do: :error
  defp mode("exact"), do: :exact
  defp mode("grounded"), do: :grounded

  defp params(context, config, run, now) do
    [
      uuid(run.assistant_revision_id),
      uuid(config.assistant.active_revision_id),
      context.locale,
      EmbeddingProfile.id(),
      now,
      context.scope
    ]
  end

  defp sql(statement, params) do
    with {:ok, _} <-
           SQL.query(Repo, "SET LOCAL statement_timeout = '750ms'", [],
             log: false,
             telemetry_event: nil,
             timeout: 1_000
           ) do
      SQL.query(Repo, statement, params, log: false, telemetry_event: nil, timeout: 1_000)
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
