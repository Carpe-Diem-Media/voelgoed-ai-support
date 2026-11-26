defmodule VoelgoedAi.Knowledge.ArticleEmbedding do
  @moduledoc "One derived locale vector for a specific approved publication generation."

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.Storage

  postgres do
    table("article_embeddings")
    repo(VoelgoedAi.Repo)

    migration_types(generation: :bigint)

    references do
      reference(:revision, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:state, "article_embeddings_shape",
        check: """
        locale IN ('af-ZA', 'en-ZA') AND generation > 0 AND attempt_count >= 0
        AND content_hash ~ '^[a-f0-9]{64}$'
        AND state IN ('queued', 'running', 'ready', 'failed', 'invalidated')
        AND (state = 'ready') = (vector IS NOT NULL)
        AND (vector IS NULL OR vector_norm(vector) > 0)
        AND (attempt_count > 0) = (last_attempt_id IS NOT NULL)
        AND (state NOT IN ('running', 'ready') OR last_attempt_id IS NOT NULL)
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:locale, :string, allow_nil?: false, constraints: [match: ~r/\A(?:af-ZA|en-ZA)\z/])
    attribute(:profile_id, :string, allow_nil?: false)
    attribute(:content_hash, :string, allow_nil?: false)
    attribute(:generation, :integer, allow_nil?: false, constraints: [min: 1])

    attribute(:state, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :running, :ready, :failed, :invalidated]]
    )

    attribute(:vector, :vector, constraints: [dimensions: 1536], sensitive?: true)
    attribute(:attempt_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:last_attempt_id, :uuid)

    attribute(:error_code, :atom,
      constraints: [
        one_of: [
          :deadline,
          :stale_request,
          :transport_unknown,
          :invalid_vector,
          :admission_denied
        ]
      ]
    )

    attribute(:deadline_at, :utc_datetime_usec, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:revision, VoelgoedAi.Knowledge.ArticleRevision, allow_nil?: false)
  end

  identities do
    identity(:variant_generation, [:revision_id, :locale, :generation])
  end

  actions do
    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :generation_rows do
      argument(:revision_id, :uuid, allow_nil?: false)
      argument(:generation, :integer, allow_nil?: false)
      filter(expr(revision_id == ^arg(:revision_id) and generation == ^arg(:generation)))
      prepare(build(sort: [:id]))
    end

    read :revision_rows do
      argument(:revision_ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(revision_id in ^arg(:revision_ids)))
      prepare(build(sort: [:id]))
    end

    create :insert_row do
      transaction?(false)
      accept([:revision_id, :locale, :profile_id, :content_hash, :generation, :deadline_at])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)
      accept([:state, :vector, :attempt_count, :last_attempt_id, :error_code])
    end
  end

  policies do
    policy action([:storage_row, :insert_row, :change_row, :generation_rows, :revision_rows]) do
      authorize_if(Storage)
    end
  end
end
