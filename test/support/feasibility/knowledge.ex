defmodule VoelgoedAi.Feasibility.Knowledge do
  @moduledoc """
  Disposable F04–F05 indexing and retrieval fixture. Staff and worker roles
  are trusted test inputs. Tables and SQL are confined to the feasibility run.
  """
  alias VoelgoedAi.Feasibility.TransportEvidence
  alias VoelgoedAi.Repo

  @model "openai:text-embedding-3-small"
  @profile "openai:text-embedding-3-small/1536/cosine/v1"
  @dimensions 1536

  def create! do
    token = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    store = %{
      collections: "f04_c_" <> token,
      revisions: "f04_r_" <> token,
      variants: "f04_v_" <> token
    }

    query!("""
    CREATE TABLE #{store.collections} (
      id bigint PRIMARY KEY, public boolean NOT NULL, enabled boolean NOT NULL,
      granted boolean NOT NULL
    )
    """)

    query!("""
    CREATE TABLE #{store.revisions} (
      id bigint PRIMARY KEY, article bigint NOT NULL,
      collection bigint NOT NULL REFERENCES #{store.collections},
      scope text NOT NULL, content jsonb NOT NULL, hash text,
      state text NOT NULL DEFAULT 'draft',
      starts timestamptz NOT NULL, expires timestamptz,
      CHECK (expires IS NULL OR expires > starts)
    )
    """)

    query!("CREATE UNIQUE INDEX ON #{store.revisions} (article) WHERE state = 'published'")

    query!("""
    CREATE TABLE #{store.variants} (
      revision bigint NOT NULL REFERENCES #{store.revisions},
      locale text NOT NULL CHECK (locale IN ('af-ZA','en-ZA')),
      profile text NOT NULL, hash text NOT NULL, generation bigint NOT NULL,
      state text NOT NULL, embedding vector(1536),
      PRIMARY KEY (revision, locale),
      CHECK ((state = 'ready') = (embedding IS NOT NULL))
    )
    """)

    store
  end

  def drop!(store) do
    query!("DROP TABLE #{store.variants}, #{store.revisions}, #{store.collections}")
  end

  def collection!(store, id, public, enabled, granted) do
    query!(
      """
      INSERT INTO #{store.collections} VALUES ($1,$2,$3,$4)
      ON CONFLICT (id) DO UPDATE SET public=$2, enabled=$3, granted=$4
      """,
      [id, public, enabled, granted]
    )
  end

  def draft!(store, id, article, collection, content, options) do
    scope = options[:scope] || "public-support"
    starts = options[:starts] || ~U[2026-01-01 00:00:00Z]

    query!(
      """
      INSERT INTO #{store.revisions} (id,article,collection,scope,content,starts,expires)
      VALUES ($1,$2,$3,$4,$5,$6,$7)
      """,
      [id, article, collection, scope, content, starts, options[:expires]]
    )
  end

  def edit(store, id, content) do
    update(
      "UPDATE #{store.revisions} SET content=$2 WHERE id=$1 AND state='draft'",
      [id, content],
      :immutable
    )
  end

  def submit(store, id, :editor) do
    locked(store, id, fn
      %{state: "draft", content: content} = revision ->
        if map_size(content) in 1..2 and
             Enum.all?(content, fn {locale, text} ->
               locale in ["af-ZA", "en-ZA"] and is_binary(text) and byte_size(text) in 1..4096
             end) do
          update(
            "UPDATE #{store.revisions} SET state='in_review', hash=$2 WHERE id=$1",
            [id, content_hash(revision)],
            :stale
          )
        else
          {:error, :invalid_content}
        end

      _ ->
        {:error, :stale}
    end)
  end

  def submit(_store, _id, _actor), do: {:error, :forbidden}

  def approve(store, id, :reviewer) do
    locked(store, id, fn
      %{state: "in_review", hash: hash} = revision ->
        if hash == content_hash(revision) do
          update("UPDATE #{store.revisions} SET state='approved' WHERE id=$1", [id], :stale)
        else
          {:error, :stale}
        end

      _ ->
        {:error, :stale}
    end)
  end

  def approve(_store, _id, _actor), do: {:error, :forbidden}

  def queue(store, id, @profile = profile, :reviewer) do
    locked(store, id, fn
      %{state: state, hash: hash, content: content, scope: scope}
      when state in ["approved", "failed"] ->
        jobs =
          content
          |> Enum.sort()
          |> Enum.map(fn {locale, text} ->
            %{rows: [[generation]]} =
              query!(
                """
                INSERT INTO #{store.variants} AS v (revision,locale,profile,hash,generation,state)
                VALUES ($1,$2,$3,$4,1,'queued')
                ON CONFLICT (revision,locale) DO UPDATE
                SET generation=v.generation+1, profile=$3, hash=$4, state='queued', embedding=NULL
                RETURNING generation
                """,
                [id, locale, profile, hash]
              )

            %{
              revision: id,
              locale: locale,
              text: text,
              scope: scope,
              profile: profile,
              hash: hash,
              generation: generation
            }
          end)

        :ok = update("UPDATE #{store.revisions} SET state='publishing' WHERE id=$1", [id], :stale)
        {:ok, jobs}

      _ ->
        {:error, :not_approved}
    end)
  end

  def queue(_store, _id, _profile, :reviewer), do: {:error, :unsupported_profile}
  def queue(_store, _id, _profile, _actor), do: {:error, :forbidden}

  def claim(store, job, now \\ ~U[2026-11-25 12:00:00Z]) do
    with_job(store, job, "queued", fn ->
      update(
        """
        UPDATE #{store.variants} v SET state='running'
        FROM #{store.revisions} r
        WHERE v.revision=$1 AND v.locale=$2 AND r.id=v.revision
          AND r.starts <= $3 AND (r.expires IS NULL OR r.expires > $3)
        """,
        [job.revision, job.locale, now],
        :not_current
      )
    end)
  end

  def index(store, ledger, %{profile: @profile} = job, attempt, now) do
    with :ok <- claim(store, job, now) do
      result =
        TransportEvidence.run(
          ledger,
          attempt,
          DateTime.to_date(now),
          "text-embedding-3-small",
          [daily: 20_000_000, monthly: 20_000_000, concurrent: 4],
          fn binding ->
            AshAi.EmbeddingModels.ReqLLM.generate([serialized(job.locale, job.text, job.scope)],
              model: @model,
              dimensions: @dimensions,
              max_batch_size: 1,
              req_opts: [
                api_key: "synthetic-placeholder",
                dimensions: @dimensions,
                total_timeout: 5000,
                req_http_options: TransportEvidence.options(binding, __MODULE__)
              ]
            )
          end
        )

      case result do
        {:ok, [vector]} -> finish(store, job, vector)
        {:error, reason} -> fail(store, job, reason)
      end
    end
  end

  def index(_store, _ledger, _job, _attempt, _now), do: {:error, :unsupported_profile}

  def finish(store, job, vector) do
    if valid_vector?(vector) do
      with_job(store, job, "running", fn ->
        update(
          "UPDATE #{store.variants} SET state='ready', embedding=$3::text::vector WHERE revision=$1 AND locale=$2",
          [job.revision, job.locale, Jason.encode!(vector)],
          :stale
        )
      end)
    else
      fail(store, job, :invalid_vector)
    end
  end

  def revoke(store, id, :reviewer) do
    locked(store, id, fn _ ->
      with :ok <-
             update(
               """
               UPDATE #{store.revisions} SET state='revoked'
               WHERE id=$1 AND state IN ('approved','publishing','failed','published')
               """,
               [id],
               :not_revocable
             ) do
        query!(
          "UPDATE #{store.variants} SET state='invalidated', embedding=NULL WHERE revision=$1",
          [id]
        )

        :ok
      end
    end)
  end

  def revoke(_store, _id, _actor), do: {:error, :forbidden}

  def publish(store, id, expected, now, :reviewer) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        query!("LOCK TABLE #{store.revisions} IN SHARE ROW EXCLUSIVE MODE")

        with %{state: "publishing", article: article, hash: hash, content: content} <-
               revision(store, id),
             :ok <- ready(store, id, hash, map_size(content), now),
             {:ok, ^expected} <- pointer(store, article) do
          query!(
            "UPDATE #{store.revisions} SET state='superseded' WHERE article=$1 AND state='published'",
            [article]
          )

          update("UPDATE #{store.revisions} SET state='published' WHERE id=$1", [id], :not_ready)
        else
          {:ok, _} -> {:error, :stale_pointer}
          _ -> {:error, :not_ready}
        end
      end)

    outcome
  end

  def publish(_store, _id, _expected, _now, _actor), do: {:error, :forbidden}

  def search(_store, _text, _vector, _locale, :unresolved, @profile, _now) do
    %{vector: [], lexical: [], selected: [], evidence: [], decision: :clarify, duration_us: 0}
  end

  def search(store, text, query_vector, locale, scope, @profile, now) do
    started = System.monotonic_time(:microsecond)

    %{rows: [[semantic, lexical]]} =
      query!(
        """
        WITH eligible AS MATERIALIZED (
          SELECT r.id, r.hash, v.locale, r.content->>v.locale AS content, v.embedding
          FROM #{store.revisions} r
          JOIN #{store.collections} c ON c.id = r.collection
          JOIN #{store.variants} v ON v.revision = r.id
          WHERE r.state='published' AND c.public AND c.enabled AND c.granted
            AND r.scope=$3 AND r.starts <= $4 AND (r.expires IS NULL OR r.expires > $4)
            AND v.locale=$5 AND v.state='ready' AND v.profile=$6 AND v.hash=r.hash
        ), query_words AS (
          SELECT to_tsquery('simple', string_agg(quote_literal(lexeme), ' | ')) AS words
          FROM unnest(tsvector_to_array(to_tsvector('simple', $1))) AS lexeme
        ), semantic AS (
          SELECT id, embedding <=> $2::text::vector AS distance FROM eligible
          WHERE embedding <=> $2::text::vector < 1
          ORDER BY distance, id LIMIT 10
        ), lexical AS (
          SELECT id, ts_rank(to_tsvector('simple', content), words) AS rank
          FROM eligible CROSS JOIN query_words
          WHERE to_tsvector('simple', content) @@ words
          ORDER BY rank DESC, id LIMIT 10
        )
        SELECT
          coalesce((SELECT array_agg(id ORDER BY distance,id) FROM semantic), '{}'::bigint[]),
          coalesce((SELECT array_agg(id ORDER BY rank DESC,id) FROM lexical), '{}'::bigint[])
        """,
        [text, Jason.encode!(query_vector), scope, now, locale, @profile]
      )

    selected = fuse(semantic, lexical)
    # Recheck current eligibility when materializing content.
    evidence = project(store, selected, locale, scope, now)
    selected = Enum.map(evidence, & &1.id)

    %{
      vector: semantic,
      lexical: lexical,
      selected: selected,
      evidence: evidence,
      decision: if(selected == [], do: :clarify, else: :evidence),
      duration_us: System.monotonic_time(:microsecond) - started
    }
  end

  def search(_store, _text, _vector, _locale, _scope, _profile, _now),
    do: %{vector: [], lexical: [], selected: [], evidence: [], decision: :clarify, duration_us: 0}

  defp project(_store, [], _locale, _scope, _now), do: []

  defp project(store, ids, locale, scope, now) do
    query!(
      """
      SELECT r.id, v.locale, r.hash, r.content->>v.locale
      FROM unnest($1::bigint[]) WITH ORDINALITY AS selected(id, rank)
      JOIN #{store.revisions} r ON r.id=selected.id
      JOIN #{store.collections} c ON c.id=r.collection
      JOIN #{store.variants} v ON v.revision=r.id
      WHERE r.state='published' AND c.public AND c.enabled AND c.granted
        AND r.scope=$3 AND r.starts <= $4 AND (r.expires IS NULL OR r.expires > $4)
        AND v.locale=$2 AND v.state='ready' AND v.profile=$5 AND v.hash=r.hash
      ORDER BY selected.rank
      """,
      [ids, locale, scope, now, @profile]
    ).rows
    |> Enum.map(fn [id, language, hash, text] ->
      %{id: id, locale: language, hash: hash, text: text}
    end)
  end

  defp fuse(semantic, lexical) do
    [semantic, lexical]
    |> Enum.reduce(%{}, fn ids, scores ->
      ids
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {id, rank}, acc ->
        score = 1 / (60 + rank)
        Map.update(acc, id, score, &(&1 + score))
      end)
    end)
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
    |> Enum.take(4)
    |> Enum.map(&elem(&1, 0))
  end

  defp fail(store, job, reason) do
    with_job(store, job, "running", fn ->
      query!(
        "UPDATE #{store.variants} SET state='invalidated', embedding=NULL WHERE revision=$1",
        [job.revision]
      )

      query!("UPDATE #{store.revisions} SET state='failed' WHERE id=$1", [job.revision])
      {:error, reason}
    end)
  end

  defp with_job(store, job, expected, action) do
    locked(store, job.revision, fn
      %{state: "publishing", hash: hash, scope: scope}
      when hash == job.hash and scope == job.scope ->
        case query!(
               """
               SELECT 1 FROM #{store.variants} v JOIN #{store.revisions} r ON r.id=v.revision
               WHERE v.revision=$1 AND v.locale=$2 AND v.profile=$3 AND v.hash=$4
                 AND v.generation=$5 AND v.state=$6 AND (r.content->>$2)=$7
               """,
               [
                 job.revision,
                 job.locale,
                 job.profile,
                 job.hash,
                 job.generation,
                 expected,
                 job.text
               ]
             ).rows do
          [[1]] -> action.()
          [] -> {:error, :stale}
        end

      _ ->
        {:error, :stale}
    end)
  end

  defp ready(store, id, hash, count, now) do
    case query!(
           """
           SELECT count(v.locale) FROM #{store.revisions} r
           JOIN #{store.variants} v ON v.revision=r.id
           WHERE r.id=$1 AND v.state='ready' AND v.hash=$2 AND v.profile=$4
             AND r.starts <= $3 AND (r.expires IS NULL OR r.expires > $3)
           """,
           [id, hash, now, @profile]
         ).rows do
      [[^count]] when count > 0 -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp pointer(store, article) do
    case query!("SELECT id FROM #{store.revisions} WHERE article=$1 AND state='published'", [
           article
         ]).rows do
      [[id]] -> {:ok, id}
      [] -> {:ok, nil}
    end
  end

  defp locked(store, id, action) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          query!("LOCK TABLE #{store.revisions} IN SHARE ROW EXCLUSIVE MODE")
          action.(revision(store, id))
        end,
        log: false
      )

    result
  end

  defp revision(store, id) do
    case query!(
           "SELECT article,state,hash,content,scope FROM #{store.revisions} WHERE id=$1 FOR UPDATE",
           [id]
         ).rows do
      [[article, state, hash, content, scope]] ->
        %{article: article, state: state, hash: hash, content: content, scope: scope}

      [] ->
        nil
    end
  end

  defp update(sql, params, failure) do
    case query!(sql, params).num_rows do
      1 -> :ok
      _ -> {:error, failure}
    end
  end

  defp content_hash(revision) do
    bytes =
      for {locale, text} <- Enum.sort(revision.content),
          do: serialized(locale, text, revision.scope)

    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  defp serialized(locale, text, scope),
    do: Jason.OrderedObject.new(locale: locale, text: text, scope: scope) |> Jason.encode!()

  defp valid_vector?(values) when is_list(values) and length(values) == @dimensions do
    Enum.all?(values, &(is_float(&1) and abs(&1) <= 3.4028234663852886e38)) and
      Enum.any?(values, &(&1 != 0.0))
  end

  defp valid_vector?(_values), do: false
  defp query!(sql, params \\ []), do: Repo.query!(sql, params, log: false)
end
