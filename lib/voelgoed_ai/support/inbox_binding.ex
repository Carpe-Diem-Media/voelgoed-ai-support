defmodule VoelgoedAi.Support.InboxBinding do
  @moduledoc "A qualified inbox with a local configuration and permission epoch."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Support.{ActionScope, Configuration}

  postgres do
    table("inbox_bindings")
    repo(VoelgoedAi.Repo)

    migration_types(
      external_account_id: :bigint,
      external_inbox_id: :bigint,
      handoff_team_id: :bigint,
      security_epoch: :bigint
    )

    references do
      reference(:assistant, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:status, "inbox_bindings_configuration",
        check: """
        char_length(installation_ref) BETWEEN 1 AND 64 AND
        char_length(credential_ref) BETWEEN 1 AND 64 AND
        external_account_id > 0 AND external_inbox_id > 0 AND handoff_team_id > 0 AND security_epoch >= 0 AND
        status IN ('draft', 'enabled', 'disabled', 'retired') AND
        operating_mode IN ('shadow', 'assisted', 'automatic')
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:installation_ref, :string, allow_nil?: false, constraints: [max_length: 64])

    attribute(:external_account_id, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]
    )

    attribute(:external_inbox_id, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :enabled, :disabled, :retired]]
    )

    attribute(:operating_mode, :atom,
      allow_nil?: false,
      default: :shadow,
      constraints: [one_of: [:shadow, :assisted, :automatic]]
    )

    attribute(:credential_ref, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [max_length: 64]
    )

    attribute(:handoff_team_id, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]
    )

    attribute(:security_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0])

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:assistant, VoelgoedAi.Intelligence.Assistant, allow_nil?: false)
  end

  identities do
    identity(:qualified_inbox, [:installation_ref, :external_account_id, :external_inbox_id])

    identity(:qualified_binding, [
      :id,
      :installation_ref,
      :external_account_id,
      :external_inbox_id
    ])
  end

  actions do
    action :create_draft, :map do
      argument(:assistant_id, :uuid, allow_nil?: false)
      argument(:installation_ref, :string, allow_nil?: false, constraints: [max_length: 64])

      argument(:external_account_id, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 9_223_372_036_854_775_807]
      )

      argument(:external_inbox_id, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 9_223_372_036_854_775_807]
      )

      run(Configuration)
    end

    action :enable, :map do
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

    action :rebind, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:assistant_id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :change_mode, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:operating_mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:shadow, :assisted, :automatic]]
      )

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

    read :qualified_inbox do
      argument(:installation_ref, :string, allow_nil?: false)
      argument(:external_account_id, :integer, allow_nil?: false)
      argument(:external_inbox_id, :integer, allow_nil?: false)

      filter(
        expr(
          installation_ref == ^arg(:installation_ref) and
            external_account_id == ^arg(:external_account_id) and
            external_inbox_id == ^arg(:external_inbox_id)
        )
      )
    end

    create :create_row do
      transaction?(false)

      accept([
        :installation_ref,
        :external_account_id,
        :external_inbox_id,
        :assistant_id,
        :credential_ref,
        :handoff_team_id
      ])
    end

    update :update_row do
      transaction?(false)
      require_atomic?(false)

      accept([
        :status,
        :assistant_id,
        :credential_ref,
        :handoff_team_id,
        :operating_mode,
        :security_epoch
      ])
    end
  end

  policies do
    policy action([:create_draft, :enable, :disable, :retire, :rebind, :change_mode]) do
      authorize_if(ActionScope.Admin)
    end

    policy action(:read_configuration) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:configuration_row, :update_row, :qualified_inbox, :create_row]) do
      authorize_if(ActionScope.Storage)
    end
  end
end
