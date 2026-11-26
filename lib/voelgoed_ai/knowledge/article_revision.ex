defmodule VoelgoedAi.Knowledge.ArticleRevision do
  @moduledoc "Immutable submitted snapshots and draft versions and guarded publication requests."

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.{Editorial, Storage}

  postgres do
    table("article_revisions")
    repo(VoelgoedAi.Repo)

    migration_types(
      revision_number: :bigint,
      edit_version: :bigint,
      publication_generation: :bigint,
      publication_collection_epoch: :bigint
    )

    references do
      reference(:article, on_delete: :restrict, on_update: :restrict)
      reference(:created_by, on_delete: :restrict, on_update: :restrict)
      reference(:approved_by, on_delete: :restrict, on_update: :restrict)
      reference(:publication_requested_by, on_delete: :restrict, on_update: :restrict)
      reference(:expected_current_revision, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:publication_generation, "article_revisions_publication_request",
        check: """
        publication_generation >= 0
        AND ((publication_generation = 0 AND publication_requested_by_id IS NULL
              AND publication_collection_epoch IS NULL AND publication_deadline_at IS NULL AND publication_profile_id IS NULL)
          OR (publication_generation > 0 AND publication_requested_by_id IS NOT NULL
              AND publication_collection_epoch >= 0 AND publication_collection_epoch IS NOT NULL
              AND publication_deadline_at IS NOT NULL AND publication_profile_id IS NOT NULL
              AND status IN ('publishing','publish_failed','revoked')))
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
          OR (status IN ('approved','revoked','publishing','publish_failed') AND review_hash IS NOT NULL AND review_hash = content_hash AND approved_by_id IS NOT NULL AND approved_at IS NOT NULL)
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
          :publish_failed
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
          article_id == ^arg(:article_id) and status in [:approved, :publishing, :publish_failed]
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
        :publication_reason
      ])
    end
  end

  policies do
    policy action([
             :create_draft,
             :read_revision,
             :edit_draft,
             :submit_review,
             :request_changes,
             :approve,
             :withdraw,
             :request_publish,
             :retry_publication,
             :revoke
           ]) do
      authorize_if(Editorial)
    end

    policy action([:insert_row, :change_row, :latest_revision, :approved_revisions]) do
      authorize_if(Storage)
    end

    policy action(:storage_row) do
      authorize_if(Storage)
    end
  end
end
