defmodule VoelgoedAi.Intelligence.AssistantRevision do
  @moduledoc "Versioned fixed workflow configuration. Only drafts can change content."

  use Ash.Resource,
    domain: VoelgoedAi.Intelligence,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Support.{ActionScope, Configuration}

  postgres do
    table("assistant_revisions")
    repo(VoelgoedAi.Repo)

    migration_types(revision_number: :bigint)

    references do
      reference(:assistant, on_delete: :restrict, on_update: :restrict)
      reference(:created_by, on_delete: :restrict, on_update: :restrict)
      reference(:published_by, on_delete: :restrict, on_update: :restrict)
    end

    custom_indexes do
      index([:assistant_id],
        name: "assistant_revisions_one_published",
        unique: true,
        where: "status = 'published'"
      )
    end

    check_constraints do
      check_constraint(:status, "assistant_revisions_lifecycle",
        check: """
        revision_number > 0 AND config_hash_version IN (1, 2) AND locale IN ('af', 'en') AND response_policy IN ('fixed_reply', 'handoff') AND
        char_length(workflow_version) BETWEEN 1 AND 64 AND char_length(template_version) BETWEEN 1 AND 64 AND
        ((status IN ('draft', 'discarded') AND published_at IS NULL AND published_by_id IS NULL AND config_hash IS NULL) OR
         (status IN ('published', 'superseded') AND published_at IS NOT NULL AND published_by_id IS NOT NULL
          AND config_hash IS NOT NULL AND config_hash ~ '^[a-f0-9]{64}$'))
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:revision_number, :integer, allow_nil?: false, constraints: [min: 1])

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :published, :superseded, :discarded]]
    )

    attribute(:workflow_version, :string, allow_nil?: false, constraints: [max_length: 64])
    attribute(:template_version, :string, allow_nil?: false, constraints: [max_length: 64])
    attribute(:locale, :atom, allow_nil?: false, constraints: [one_of: [:af, :en]])

    attribute(:response_policy, :atom,
      allow_nil?: false,
      constraints: [one_of: [:fixed_reply, :handoff]]
    )

    attribute(:config_hash, :string, constraints: [match: ~r/\A[a-f0-9]{64}\z/])

    attribute(:config_hash_version, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1, max: 2]
    )

    attribute(:published_at, :utc_datetime_usec)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:assistant, VoelgoedAi.Intelligence.Assistant, allow_nil?: false)
    belongs_to(:created_by, VoelgoedAi.Accounts.StaffUser, allow_nil?: false)
    belongs_to(:published_by, VoelgoedAi.Accounts.StaffUser)
  end

  identities do
    identity(:revision_number, [:assistant_id, :revision_number])
    identity(:qualified_revision, [:id, :assistant_id])
  end

  actions do
    action :create_draft, :map do
      argument(:assistant_id, :uuid, allow_nil?: false)
      argument(:workflow_version, :string, allow_nil?: false, constraints: [max_length: 64])
      argument(:template_version, :string, allow_nil?: false, constraints: [max_length: 64])
      argument(:locale, :atom, allow_nil?: false, constraints: [one_of: [:af, :en]])

      argument(:response_policy, :atom,
        allow_nil?: false,
        constraints: [one_of: [:fixed_reply, :handoff]]
      )

      run(Configuration)
    end

    action :edit_draft, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:workflow_version, :string, constraints: [max_length: 64])
      argument(:template_version, :string, constraints: [max_length: 64])
      argument(:locale, :atom, constraints: [one_of: [:af, :en]])
      argument(:response_policy, :atom, constraints: [one_of: [:fixed_reply, :handoff]])
      run(Configuration)
    end

    action :discard, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :publish, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:expected_active_revision_id, :uuid, allow_nil?: true)
      run(Configuration)
    end

    action :grant_collection, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:collection_id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :remove_collection, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:collection_id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :read_configuration, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    read :configuration_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :latest_revision do
      argument(:assistant_id, :uuid, allow_nil?: false)
      filter(expr(assistant_id == ^arg(:assistant_id)))
      prepare(build(sort: [revision_number: :desc], limit: 1))
    end

    create :create_row do
      transaction?(false)

      accept([
        :assistant_id,
        :created_by_id,
        :revision_number,
        :workflow_version,
        :template_version,
        :locale,
        :response_policy
      ])
    end

    update :update_row do
      transaction?(false)
      require_atomic?(false)

      accept([
        :status,
        :workflow_version,
        :template_version,
        :locale,
        :response_policy,
        :config_hash,
        :config_hash_version,
        :published_by_id,
        :published_at
      ])
    end
  end

  policies do
    policy action([
             :create_draft,
             :edit_draft,
             :discard,
             :publish,
             :grant_collection,
             :remove_collection
           ]) do
      authorize_if(ActionScope.Admin)
    end

    policy action(:read_configuration) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:configuration_row, :update_row, :latest_revision, :create_row]) do
      authorize_if(ActionScope.Storage)
    end
  end
end
