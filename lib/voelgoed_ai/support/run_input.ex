defmodule VoelgoedAi.Support.RunInput do
  @moduledoc "One durable receipt membership in a run, ordered by verified history."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("run_inputs")
    repo(VoelgoedAi.Repo)

    migration_types(position: :bigint)

    references do
      reference(:run, on_delete: :restrict, on_update: :restrict)
      reference(:event, on_delete: :restrict, on_update: :restrict)
    end

    custom_indexes do
      index([:event_id], name: "run_inputs_one_current", unique: true, where: "current")
    end

    check_constraints do
      check_constraint(:position, "run_inputs_lifecycle",
        check: """
        position >= 0
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id, public?: true)
    attribute(:position, :integer, public?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:current, :boolean, public?: true, allow_nil?: false, default: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:run, VoelgoedAi.Support.SupportRun, allow_nil?: false, public?: true)
    belongs_to(:event, VoelgoedAi.Support.InboundEvent, allow_nil?: false, public?: true)
  end

  identities do
    identity(:run_event, [:run_id, :event_id])
  end

  actions do
    read :for_run do
    end

    read :for_event do
    end

    create :cover do
      transaction?(false)
      accept([:run_id, :event_id, :position])
    end

    update :release do
      transaction?(false)
      require_atomic?(false)
      accept([:current])
    end

    update :set_position do
      transaction?(false)
      require_atomic?(false)
      accept([:position])
    end
  end

  policies do
    policy action([:for_run, :for_event, :cover, :release, :set_position]) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end
  end
end
