defmodule VoelgoedAi.Governance.UsageLedger do
  @moduledoc "Immutable embedding settlement or correction in integer nano-USD."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.Storage

  postgres do
    table("usage_ledger_entries")
    repo(VoelgoedAi.Repo)

    migration_types(
      rate_nano_usd: :bigint,
      token_unit: :bigint,
      max_input_tokens: :bigint,
      input_tokens: :bigint,
      amount_nano_usd: :bigint
    )

    references do
      reference(:reservation, on_delete: :restrict, on_update: :restrict)
      reference(:inference_run, on_delete: :restrict, on_update: :restrict)
      reference(:corrects, on_delete: :restrict, on_update: :restrict)
      reference(:closure_approved_by, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:entry_kind, "usage_ledger_entries_shape",
        check: """
        rate_nano_usd > 0 AND token_unit > 0 AND max_input_tokens > 0
        AND (input_tokens IS NULL OR input_tokens > 0)
        AND ((entry_kind = 'settlement' AND entry_key = 'settlement' AND amount_nano_usd >= 0
               AND corrects_id IS NULL)
          OR (entry_kind = 'correction' AND entry_key <> 'settlement' AND corrects_id IS NOT NULL
               AND input_tokens IS NOT NULL))
        AND (reason_code = 'conservative_closure') = (closure_approved_by_id IS NOT NULL)
        AND (input_tokens IS NULL) = (closure_approved_by_id IS NOT NULL)
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:price_version, :string, allow_nil?: false)
    attribute(:rate_nano_usd, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:token_unit, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:max_input_tokens, :integer, allow_nil?: false, constraints: [min: 1])

    attribute(:entry_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:settlement, :correction]]
    )

    attribute(:entry_key, :string, allow_nil?: false, constraints: [max_length: 128])
    attribute(:provider, :string, allow_nil?: false)
    attribute(:model_id, :string, allow_nil?: false)
    attribute(:input_tokens, :integer, constraints: [min: 1])
    attribute(:amount_nano_usd, :integer, allow_nil?: false)

    attribute(:reason_code, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :trusted_usage,
          :invalid_vector,
          :over_reserve,
          :conservative_closure,
          :late_usage
        ]
      ]
    )

    attribute(:correlation_id, :uuid, allow_nil?: false)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:reservation, VoelgoedAi.Governance.UsageReservation, allow_nil?: false)
    belongs_to(:inference_run, VoelgoedAi.Intelligence.InferenceRun, allow_nil?: false)
    belongs_to(:corrects, __MODULE__, allow_nil?: true)
    belongs_to(:closure_approved_by, VoelgoedAi.Accounts.StaffUser)
  end

  identities do
    identity(:entry_key, [:reservation_id, :entry_key])
    identity(:qualified_entry, [:reservation_id, :id])
  end

  actions do
    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :for_reservation do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(reservation_id == ^arg(:id)))
      prepare(build(sort: [:id]))
    end

    create :insert_row do
      transaction?(false)

      accept([
        :reservation_id,
        :inference_run_id,
        :entry_kind,
        :entry_key,
        :corrects_id,
        :closure_approved_by_id,
        :provider,
        :model_id,
        :input_tokens,
        :amount_nano_usd,
        :price_version,
        :rate_nano_usd,
        :token_unit,
        :max_input_tokens,
        :reason_code,
        :correlation_id
      ])
    end
  end

  policies do
    policy action([:storage_row, :insert_row, :for_reservation]) do
      authorize_if(Storage)
    end
  end
end
