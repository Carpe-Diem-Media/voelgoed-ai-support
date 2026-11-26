defmodule VoelgoedAi.Intelligence.InferenceRun do
  @moduledoc "Durable purpose-bound embedding attempt and one-shot dispatch fence."

  use Ash.Resource,
    domain: VoelgoedAi.Intelligence,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Intelligence.Embedding
  alias VoelgoedAi.Knowledge.Storage

  postgres do
    table("inference_runs")
    repo(VoelgoedAi.Repo)

    migration_types(input_tokens: :bigint)

    references do
      reference(:article_embedding, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:state, "inference_runs_shape",
        check: """
        purpose = 'article_embedding' AND ordinal > 0 AND (input_tokens IS NULL OR input_tokens > 0)
        AND state IN ('queued', 'running', 'succeeded', 'failed', 'unknown', 'rejected', 'cancelled', 'abandoned')
        AND (dispatched_at IS NULL OR started_at IS NOT NULL)
        AND (state NOT IN ('succeeded', 'failed', 'unknown', 'abandoned') OR dispatched_at IS NOT NULL)
        AND (state IN ('queued', 'running')) = (finished_at IS NULL)
        AND (provider_request_id IS NULL) = (input_tokens IS NULL)
        AND (state NOT IN ('succeeded', 'failed') OR input_tokens IS NOT NULL)
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:purpose, :atom,
      default: :article_embedding,
      allow_nil?: false,
      constraints: [one_of: [:article_embedding]]
    )

    attribute(:provider, :string, allow_nil?: false)
    attribute(:model_id, :string, allow_nil?: false)
    attribute(:profile_id, :string, allow_nil?: false)
    attribute(:ordinal, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:deadline_at, :utc_datetime_usec, allow_nil?: false)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [
        one_of: [
          :queued,
          :running,
          :succeeded,
          :failed,
          :unknown,
          :rejected,
          :cancelled,
          :abandoned
        ]
      ]
    )

    attribute(:dispatch_fence, :uuid, allow_nil?: false)
    attribute(:dispatched_at, :utc_datetime_usec)
    attribute(:started_at, :utc_datetime_usec)
    attribute(:finished_at, :utc_datetime_usec)
    attribute(:provider_request_id, :string, constraints: [max_length: 128], sensitive?: true)
    attribute(:input_tokens, :integer, constraints: [min: 1])

    attribute(:reason_code, :atom,
      constraints: [
        one_of: [
          :deadline,
          :stale_request,
          :transport_unknown,
          :invalid_vector,
          :amount_overflow,
          :over_reserve,
          :conservative_closure,
          :admission_denied
        ]
      ]
    )

    attribute(:correlation_id, :uuid, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:article_embedding, VoelgoedAi.Knowledge.ArticleEmbedding, allow_nil?: false)
  end

  identities do
    identity(:attempt_ordinal, [:article_embedding_id, :ordinal])
    identity(:qualified_attempt, [:article_embedding_id, :id])
  end

  actions do
    action :close_unknown_embedding, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:reason, :atom, allow_nil?: false, constraints: [one_of: [:conservative_closure]])
      run(Embedding)
    end

    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :recovery_candidates do
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      filter(expr(state == :running and deadline_at <= ^arg(:now)))
      prepare(build(sort: [:deadline_at, :id], limit: 50))
    end

    create :insert_row do
      transaction?(false)

      accept([
        :article_embedding_id,
        :provider,
        :model_id,
        :profile_id,
        :ordinal,
        :deadline_at,
        :dispatch_fence,
        :correlation_id
      ])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :started_at,
        :dispatched_at,
        :finished_at,
        :provider_request_id,
        :input_tokens,
        :reason_code
      ])
    end
  end

  policies do
    policy action(:close_unknown_embedding) do
      authorize_if(Embedding)
    end

    policy action([:storage_row, :insert_row, :change_row, :recovery_candidates]) do
      authorize_if(Storage)
    end
  end
end
