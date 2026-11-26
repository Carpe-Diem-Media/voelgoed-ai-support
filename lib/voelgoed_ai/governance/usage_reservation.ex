defmodule VoelgoedAi.Governance.UsageReservation do
  @moduledoc "One immutable price and held exposure tied to an inference attempt."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.Storage

  postgres do
    table("usage_reservations")
    repo(VoelgoedAi.Repo)

    migration_types(
      rate_nano_usd: :bigint,
      token_unit: :bigint,
      max_input_tokens: :bigint,
      reserved_nano_usd: :bigint,
      actual_nano_usd: :bigint
    )

    references do
      reference(:inference_run, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:state, "usage_reservations_shape",
        check: """
        rate_nano_usd > 0 AND token_unit > 0 AND max_input_tokens > 0 AND reserved_nano_usd > 0
        AND month_window = date_trunc('month', day_window::timestamp)::date
        AND state IN ('reserved', 'unknown', 'released', 'settled', 'conservatively_settled')
        AND (state IN ('settled', 'conservatively_settled')) = (actual_nano_usd IS NOT NULL)
        AND (actual_nano_usd IS NULL OR actual_nano_usd >= 0)
        AND (state IN ('reserved', 'unknown')) = (settled_at IS NULL)
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

    attribute(:reserved_nano_usd, :integer, allow_nil?: false, constraints: [min: 1])
    attribute(:actual_nano_usd, :integer, constraints: [min: 0])
    attribute(:day_window, :date, allow_nil?: false)
    attribute(:month_window, :date, allow_nil?: false)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :reserved,
      constraints: [one_of: [:reserved, :unknown, :released, :settled, :conservatively_settled]]
    )

    attribute(:settled_at, :utc_datetime_usec)

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

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:inference_run, VoelgoedAi.Intelligence.InferenceRun, allow_nil?: false)
  end

  identities do
    identity(:inference, [:inference_run_id])
    identity(:qualified_reservation, [:id, :inference_run_id])
  end

  actions do
    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :for_attempt do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(inference_run_id == ^arg(:id)))
    end

    create :insert_row do
      transaction?(false)

      accept([
        :inference_run_id,
        :price_version,
        :rate_nano_usd,
        :token_unit,
        :max_input_tokens,
        :reserved_nano_usd,
        :day_window,
        :month_window
      ])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)
      accept([:state, :actual_nano_usd, :settled_at, :reason_code])
    end
  end

  policies do
    policy action([:storage_row, :insert_row, :change_row, :for_attempt]) do
      authorize_if(Storage)
    end
  end
end
