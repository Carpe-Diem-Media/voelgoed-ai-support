defmodule VoelgoedAi.Intelligence.Assistant do
  @moduledoc "Stable assistant identity and current configuration pointer."

  use Ash.Resource,
    domain: VoelgoedAi.Intelligence,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Support.{ActionScope, Configuration}

  postgres do
    table("assistants")
    repo(VoelgoedAi.Repo)

    migration_types(security_epoch: :bigint)

    references do
      reference(:active_revision, ignore?: true)
    end

    check_constraints do
      check_constraint(:status, "assistants_lifecycle",
        check: """
        kind = 'customer_support' AND audience IN ('public', 'internal') AND security_epoch >= 0 AND
        ((status = 'active' AND active_revision_id IS NOT NULL AND disabled_at IS NULL) OR
         (status IN ('disabled', 'retired') AND disabled_at IS NOT NULL))
        """
      )

      check_constraint(:slug, "assistants_bounded_names",
        check:
          "char_length(slug) BETWEEN 1 AND 64 AND char_length(display_name) BETWEEN 1 AND 120"
      )
    end

    # Install the cyclic, same-assistant pointer after the revision identity exists.
    custom_statements do
      statement :assistants_active_revision_owner do
        after_tables(["assistants", "assistant_revisions"])

        up(
          "ALTER TABLE assistants ADD CONSTRAINT assistants_active_revision_owner FOREIGN KEY (active_revision_id, id) REFERENCES assistant_revisions (id, assistant_id) ON DELETE RESTRICT ON UPDATE RESTRICT"
        )

        down("ALTER TABLE assistants DROP CONSTRAINT assistants_active_revision_owner")
      end
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:slug, :string, allow_nil?: false, constraints: [max_length: 64])
    attribute(:display_name, :string, allow_nil?: false, constraints: [max_length: 120])

    attribute(:kind, :atom,
      allow_nil?: false,
      default: :customer_support,
      constraints: [one_of: [:customer_support]]
    )

    attribute(:audience, :atom, allow_nil?: false, constraints: [one_of: [:public, :internal]])

    attribute(:status, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:active, :disabled, :retired]]
    )

    attribute(:security_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:disabled_at, :utc_datetime_usec)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:active_revision, VoelgoedAi.Intelligence.AssistantRevision)
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  actions do
    action :create, :map do
      argument(:slug, :string,
        allow_nil?: false,
        constraints: [max_length: 64, match: ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/]
      )

      argument(:display_name, :string, allow_nil?: false, constraints: [max_length: 120])
      argument(:audience, :atom, allow_nil?: false, constraints: [one_of: [:public, :internal]])
      run(Configuration)
    end

    action :activate, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :disable, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :retire, :map do
      argument(:id, :uuid, allow_nil?: false)
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

    create :create_row do
      transaction?(false)
      accept([:slug, :display_name, :audience, :disabled_at])
    end

    update :update_row do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :active_revision_id, :security_epoch, :disabled_at])
    end
  end

  policies do
    policy action([:create, :activate, :disable, :retire]) do
      authorize_if(ActionScope.Admin)
    end

    policy action(:read_configuration) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:configuration_row, :update_row, :create_row]) do
      authorize_if(ActionScope.Storage)
    end
  end
end
