defmodule VoelgoedAi.Governance.SpendWindow do
  @moduledoc "Settled nano-USD in a UTC day or month. Outstanding holds are counted separately."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.Storage

  postgres do
    table("spend_windows")
    repo(VoelgoedAi.Repo)

    migration_types(settled_nano_usd: :bigint)

    check_constraints do
      check_constraint(:kind, "spend_windows_shape",
        check: """
        scope = 'global' AND settled_nano_usd >= 0
        AND (kind = 'day' OR (kind = 'month' AND extract(day FROM window_start) = 1))
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:kind, :atom, allow_nil?: false, constraints: [one_of: [:day, :month]])
    attribute(:scope, :string, allow_nil?: false, default: "global")
    attribute(:window_start, :date, allow_nil?: false)
    attribute(:settled_nano_usd, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:window, [:kind, :scope, :window_start])
  end

  actions do
    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_window do
      argument(:kind, :atom, allow_nil?: false, constraints: [one_of: [:day, :month]])
      argument(:start, :date, allow_nil?: false)
      filter(expr(kind == ^arg(:kind) and scope == "global" and window_start == ^arg(:start)))
    end

    create :insert_row do
      transaction?(false)
      accept([:kind, :window_start])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)
      accept([:settled_nano_usd])
    end
  end

  policies do
    policy action([:storage_row, :insert_row, :change_row, :by_window]) do
      authorize_if(Storage)
    end
  end
end
