defmodule VoelgoedAi.Governance.AutomationControl do
  @moduledoc "Singleton emergency inhibit and permission epoch."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.Storage
  alias VoelgoedAi.Support.{ActionScope, Configuration}

  postgres do
    table("automation_controls")
    repo(VoelgoedAi.Repo)

    migration_types(security_epoch: :bigint)

    check_constraints do
      check_constraint(:singleton, "automation_controls_singleton", check: "singleton IS TRUE")

      check_constraint(:status, "automation_controls_status",
        check: """
        security_epoch >= 0 AND ((status = 'disabled' AND mode = 'disabled') OR
                                 (status = 'enabled' AND mode IN ('fake', 'shadow_test')))
        """
      )
    end

    custom_statements do
      statement :seed_disabled_automation do
        after_tables(["automation_controls"])

        up(
          "INSERT INTO automation_controls (singleton, status, mode, security_epoch) VALUES (TRUE, 'disabled', 'disabled', 0)"
        )

        down("DELETE FROM automation_controls")
      end
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:singleton, :boolean, allow_nil?: false, default: true)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:disabled, :enabled]]
    )

    attribute(:mode, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:disabled, :fake, :shadow_test]]
    )

    attribute(:security_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0])

    attribute(:generation_inhibited, :boolean, allow_nil?: false, default: false)
    attribute(:embedding_inhibited, :boolean, allow_nil?: false, default: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:singleton, [:singleton])
  end

  actions do
    action :enable_automation, :map do
      argument(:binding_id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    action :disable_automation, :map do
      run(Configuration)
    end

    action :read_configuration, :map do
      run(Configuration)
    end

    read :configuration_row do
      filter(expr(singleton == true))
    end

    update :inhibit_generation do
      transaction?(false)
      require_atomic?(false)
      change(set_attribute(:generation_inhibited, true))
    end

    update :inhibit_embedding do
      transaction?(false)
      require_atomic?(false)
      change(set_attribute(:embedding_inhibited, true))
    end

    update :update_row do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :mode, :security_epoch])
    end
  end

  policies do
    policy action([:inhibit_embedding, :inhibit_generation]) do
      authorize_if(Storage)
    end

    policy action([:enable_automation, :disable_automation]) do
      authorize_if(ActionScope.Admin)
    end

    policy action(:read_configuration) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:configuration_row, :update_row]) do
      authorize_if(ActionScope.Storage)
    end
  end
end
