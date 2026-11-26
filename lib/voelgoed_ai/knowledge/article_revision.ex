defmodule VoelgoedAi.Knowledge.ArticleRevision do
  @moduledoc "Immutable submitted snapshots and draft versions and guarded publication requests."

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.{Editorial, Publication, Storage}

  postgres do
    table("article_revisions")
    repo(VoelgoedAi.Repo)

    migration_types(
      revision_number: :bigint,
      edit_version: :bigint,
      publication_generation: :bigint,
      publication_collection_epoch: :bigint,
      active_index_generation: :bigint,
      retained_index_generation: :bigint,
      reindex_base_generation: :bigint,
      index_epoch: :bigint
    )

    references do
      reference(:article, on_delete: :restrict, on_update: :restrict)
      reference(:created_by, on_delete: :restrict, on_update: :restrict)
      reference(:approved_by, on_delete: :restrict, on_update: :restrict)
      reference(:publication_requested_by, on_delete: :restrict, on_update: :restrict)
      reference(:expected_current_revision, on_delete: :restrict, on_update: :restrict)
    end

    custom_indexes do
      index([:article_id],
        name: "article_revisions_one_published",
        unique: true,
        where: "status = 'published'"
      )

      index([:publication_deadline_at, :id],
        name: "article_revisions_pending_index",
        where: "status = 'publishing' OR reindex_base_generation IS NOT NULL"
      )

      index([:publication_expires_at, :id],
        name: "article_revisions_expiry",
        where: "status = 'published' AND publication_expires_at IS NOT NULL"
      )
    end

    check_constraints do
      check_constraint(:index_epoch, "article_revisions_active_index",
        check: """
        index_epoch >= 0
        AND ((status = 'published' AND published_at IS NOT NULL AND index_epoch > 0
              AND active_index_generation IS NOT NULL AND active_index_generation > 0
              AND active_index_generation <= publication_generation AND active_index_profile_id IS NOT NULL)
          OR (status <> 'published' AND active_index_generation IS NULL AND active_index_profile_id IS NULL
              AND retained_index_generation IS NULL AND reindex_base_generation IS NULL
              AND publication_expires_at IS NULL AND index_evaluation IS NULL))
        AND (retained_index_generation IS NULL OR (retained_index_generation > 0
          AND retained_index_generation <= publication_generation AND retained_index_generation <> active_index_generation))
        AND (reindex_base_generation IS NULL OR (reindex_base_generation = active_index_generation
          AND publication_generation > active_index_generation AND expected_current_revision_id IS NOT NULL
          AND expected_current_revision_id = id))
        """
      )

      check_constraint(:publication_generation, "article_revisions_publication_request",
        check: """
        publication_generation >= 0
        AND ((publication_generation = 0 AND publication_requested_by_id IS NULL
              AND publication_collection_epoch IS NULL AND publication_deadline_at IS NULL AND publication_profile_id IS NULL)
          OR (publication_generation > 0 AND publication_requested_by_id IS NOT NULL
              AND publication_collection_epoch >= 0 AND publication_collection_epoch IS NOT NULL
              AND publication_deadline_at IS NOT NULL AND publication_profile_id IS NOT NULL
              AND status IN ('publishing','publish_failed','revoked','published','superseded','expired')))
        AND (status NOT IN ('publishing','publish_failed') OR publication_generation > 0)
        AND (status <> 'publish_failed' OR publication_reason IS NOT NULL)
        """
      )

      check_constraint(:contributor_ids, "article_revisions_contributors",
        check:
          "created_by_id = ANY(contributor_ids) AND array_position(contributor_ids, NULL) IS NULL"
      )

      check_constraint(:status, "article_revisions_editorial_lifecycle",
        check: """
        revision_number > 0 AND edit_version > 0 AND content_hash_version = 1
        AND content_hash ~ '^[a-f0-9]{64}$'
        AND (
          (status IN ('draft','withdrawn') AND review_hash IS NULL AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status = 'in_review' AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NULL AND approved_at IS NULL)
          OR (status IN ('approved','revoked','publishing','publish_failed','published','superseded','expired') AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NOT NULL AND approved_at IS NOT NULL)
        )
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:revision_number, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:edit_version, :integer, allow_nil?: false, default: 1, constraints: [min: 1])

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      constraints: [
        one_of: [
          :draft,
          :in_review,
          :approved,
          :withdrawn,
          :revoked,
          :publishing,
          :publish_failed,
          :published,
          :superseded,
          :expired
        ]
      ]
    )

    attribute(:content, :map, allow_nil?: false)
    attribute(:content_hash_version, :integer, allow_nil?: false, default: 1)

    attribute(:content_hash, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[a-f0-9]{64}\z/]
    )

    attribute(:contributor_ids, {:array, :uuid},
      description:
        "Staff IDs that created, edited or submitted this revision. Used to require self-approval attestation.",
      allow_nil?: false,
      default: []
    )

    attribute(:review_hash, :string, constraints: [match: ~r/\A[a-f0-9]{64}\z/])
    attribute(:approved_at, :utc_datetime_usec)
    attribute(:publication_generation, :integer, allow_nil?: false, default: 0)
    attribute(:publication_collection_epoch, :integer)
    attribute(:publication_profile_id, :string)
    attribute(:publication_deadline_at, :utc_datetime_usec)

    attribute(:published_at, :utc_datetime_usec)
    attribute(:publication_expires_at, :utc_datetime_usec)
    attribute(:active_index_generation, :integer)
    attribute(:active_index_profile_id, :string)
    attribute(:retained_index_generation, :integer)
    attribute(:reindex_base_generation, :integer)
    attribute(:index_epoch, :integer, allow_nil?: false, default: 0)

    attribute(:index_evaluation, :map,
      constraints: [
        fields: [
          generation: [type: :integer, allow_nil?: false, constraints: [min: 1]],
          content_hash: [
            type: :string,
            allow_nil?: false,
            constraints: [match: ~r/\A[a-f0-9]{64}\z/]
          ],
          profile_id: [type: :string, allow_nil?: false, constraints: [max_length: 128]],
          evaluator: [
            type: :string,
            allow_nil?: false,
            constraints: [match: ~r/\A[a-z_]{1,32}\z/]
          ],
          evaluated_at: [type: :utc_datetime_usec, allow_nil?: false]
        ]
      ]
    )

    attribute(:publication_reason, :atom,
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

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:article, VoelgoedAi.Knowledge.Article, allow_nil?: false)
    belongs_to(:created_by, VoelgoedAi.Accounts.StaffUser, allow_nil?: false)
    belongs_to(:approved_by, VoelgoedAi.Accounts.StaffUser)
    belongs_to(:publication_requested_by, VoelgoedAi.Accounts.StaffUser)
    belongs_to(:expected_current_revision, __MODULE__)
  end

  identities do
    identity(:revision_number, [:article_id, :revision_number])
    identity(:qualified_revision, [:article_id, :id])
  end

  actions do
    action :create_draft, :map do
      argument(:article_id, :uuid, allow_nil?: false)
      argument(:content, :map, allow_nil?: false)
      run(Editorial)
    end

    action :list_revisions, :map do
      description(
        "List permitted revisions in ascending ID order. Pass the returned cursor to continue."
      )

      argument(:article_id, :uuid, allow_nil?: false)
      argument(:after_id, :uuid)
      argument(:limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 50])
      run(Editorial)
    end

    action :read_revision, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    action :edit_draft, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/],
        allow_nil?: false
      )

      argument(:expected_version, :integer, constraints: [min: 1], allow_nil?: false)
      argument(:content, :map, allow_nil?: false)
      run(Editorial)
    end

    action :submit_review, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/],
        allow_nil?: false
      )

      argument(:expected_version, :integer, constraints: [min: 1], allow_nil?: false)
      run(Editorial)
    end

    action :request_changes, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/],
        allow_nil?: false
      )

      argument(:expected_version, :integer, constraints: [min: 1], allow_nil?: false)

      argument(:reason, :atom,
        constraints: [one_of: [:source_correction, :content_correction]],
        allow_nil?: false
      )

      run(Editorial)
    end

    action :approve, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/],
        allow_nil?: false
      )

      argument(:expected_version, :integer, constraints: [min: 1], allow_nil?: false)
      argument(:source_verified, :boolean, allow_nil?: false)
      argument(:self_approval, :boolean, allow_nil?: false)
      run(Editorial)
    end

    action :withdraw, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/],
        allow_nil?: false
      )

      argument(:expected_version, :integer, constraints: [min: 1], allow_nil?: false)
      argument(:reason, :atom, constraints: [one_of: [:withdrawn_by_staff]], allow_nil?: false)
      run(Editorial)
    end

    action :request_publish, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/]
      )

      argument(:expected_version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:expected_current_revision_id, :uuid)
      run(Editorial)
    end

    action :retry_publication, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/]
      )

      argument(:expected_version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:expected_current_revision_id, :uuid)
      run(Editorial)
    end

    action :request_reindex, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/]
      )

      argument(:expected_generation, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:expected_index_epoch, :integer, allow_nil?: false, constraints: [min: 1])
      run(Editorial)
    end

    action :request_index_rollback, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/]
      )

      argument(:expected_generation, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:expected_index_epoch, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:target_generation, :integer, allow_nil?: false, constraints: [min: 1])
      run(Editorial)
    end

    action :search_published, VoelgoedAi.Knowledge.Retrieval.Manifest do
      description("Return approved evidence for the current qualified support claim.")

      argument(:query, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [allow_empty?: true, trim?: false, max_length: 3000]
      )

      run(VoelgoedAi.Knowledge.Retrieval)
    end

    action :validate_evidence, VoelgoedAi.Knowledge.Retrieval.Manifest do
      description("Requalify citations and links from the manifest issued to this claim.")
      argument(:citations, {:array, :uuid}, allow_nil?: false, constraints: [max_length: 4])

      argument(:used_links, {:array, :string},
        allow_nil?: false,
        constraints: [max_length: 32, items: [max_length: 512, trim?: false]]
      )

      run(VoelgoedAi.Knowledge.Retrieval)
    end

    action :publish_ready, :atom do
      constraints(one_of: [:activated, :switched, :stale, :pending, :noop])
      argument(:id, :uuid, allow_nil?: false)
      argument(:generation, :integer, allow_nil?: false, constraints: [min: 1])
      run(Publication)
    end

    action :expire, :atom do
      constraints(one_of: [:expired, :early, :stale, :noop])
      argument(:id, :uuid, allow_nil?: false)
      run(Publication)
    end

    action :rollback_index, :atom do
      constraints(one_of: [:switched, :stale, :noop])
      argument(:request_id, :uuid, allow_nil?: false)
      run(Publication)
    end

    read :pending_finalisation do
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      argument(:status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:publishing, :published]]
      )

      filter(
        expr(
          status == ^arg(:status) and
            (status == :publishing or not is_nil(reindex_base_generation)) and
            (publication_deadline_at <= ^arg(:now) or
               (fragment(
                  "EXISTS (SELECT 1 FROM article_embeddings e WHERE e.revision_id = ? AND e.generation = ? AND e.state = 'ready')",
                  id,
                  publication_generation
                ) and
                  not fragment(
                    "EXISTS (SELECT 1 FROM article_embeddings e WHERE e.revision_id = ? AND e.generation = ? AND e.state <> 'ready')",
                    id,
                    publication_generation
                  )))
        )
      )

      prepare(build(sort: [:publication_deadline_at, :id], limit: 50))
    end

    read :due_expiries do
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      filter(expr(status == :published and publication_expires_at <= ^arg(:now)))
      prepare(build(sort: [:publication_expires_at, :id], limit: 50))
    end

    action :revoke, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:expected_hash, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[a-f0-9]{64}\z/]
      )

      argument(:expected_version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:reason, :atom, allow_nil?: false, constraints: [one_of: [:obsolete]])
      run(Editorial)
    end

    read(:editorial_page)

    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :latest_revision do
      argument(:article_id, :uuid, allow_nil?: false)
      filter(expr(article_id == ^arg(:article_id)))
      prepare(build(sort: [revision_number: :desc], limit: 1))
    end

    read :approved_revisions do
      argument(:article_id, :uuid, allow_nil?: false)

      filter(
        expr(
          article_id == ^arg(:article_id) and
            status in [:approved, :publishing, :publish_failed, :published]
        )
      )

      prepare(build(sort: [:id]))
    end

    create :insert_row do
      transaction?(false)

      accept([
        :article_id,
        :created_by_id,
        :contributor_ids,
        :revision_number,
        :content,
        :content_hash,
        :content_hash_version
      ])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)

      accept([
        :content,
        :content_hash,
        :edit_version,
        :contributor_ids,
        :review_hash,
        :status,
        :approved_by_id,
        :approved_at,
        :publication_generation,
        :publication_requested_by_id,
        :publication_collection_epoch,
        :expected_current_revision_id,
        :publication_profile_id,
        :publication_deadline_at,
        :publication_reason,
        :published_at,
        :publication_expires_at,
        :active_index_generation,
        :active_index_profile_id,
        :retained_index_generation,
        :reindex_base_generation,
        :index_epoch,
        :index_evaluation
      ])
    end
  end

  policies do
    policy action([
             :create_draft,
             :read_revision,
             :list_revisions,
             :edit_draft,
             :submit_review,
             :request_changes,
             :approve,
             :withdraw,
             :request_publish,
             :retry_publication,
             :request_reindex,
             :request_index_rollback,
             :revoke
           ]) do
      authorize_if(Editorial)
    end

    policy action([:insert_row, :change_row, :latest_revision, :approved_revisions]) do
      authorize_if(Storage)
    end

    policy action([:search_published, :validate_evidence]) do
      authorize_if(VoelgoedAi.Knowledge.Retrieval)
    end

    policy action([:publish_ready, :expire, :rollback_index]) do
      authorize_if(Publication)
    end

    policy action(:editorial_page) do
      authorize_if(Storage)
    end

    policy action([:storage_row, :pending_finalisation, :due_expiries]) do
      authorize_if(Storage)
    end
  end
end
