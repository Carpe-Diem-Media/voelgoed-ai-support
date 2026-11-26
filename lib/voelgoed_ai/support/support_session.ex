defmodule VoelgoedAi.Support.SupportSession do
  @moduledoc "One ownership generation for a qualified conversation. Closed generations remain historical."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("support_sessions")
    repo(VoelgoedAi.Repo)

    migration_types(
      external_account_id: :bigint,
      external_inbox_id: :bigint,
      conversation_id: :bigint,
      contact_id: :bigint,
      generation: :bigint,
      ownership_epoch: :bigint
    )

    references do
      reference(:binding,
        on_delete: :restrict,
        on_update: :restrict,
        match_with: [
          installation_ref: :installation_ref,
          external_account_id: :external_account_id,
          external_inbox_id: :external_inbox_id
        ]
      )
    end

    custom_indexes do
      index([:installation_ref, :external_account_id, :external_inbox_id, :conversation_id],
        name: "support_sessions_one_current",
        unique: true,
        where: "state <> 'closed'"
      )
    end

    check_constraints do
      check_constraint(:installation_ref, "support_sessions_lifecycle",
        check: """
        external_account_id > 0 AND external_inbox_id > 0 AND conversation_id > 0 AND
        (contact_id IS NULL OR contact_id > 0) AND generation > 0 AND ownership_epoch >= 0 AND
        state IN ('unverified', 'bot_active', 'handoff_pending', 'human_active', 'closed') AND
        (state = 'closed') = (closed_at IS NOT NULL) AND
        (state <> 'bot_active' OR NOT human_inhibit) AND
        (state NOT IN ('handoff_pending', 'human_active') OR human_inhibit)
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id, public?: true)

    attribute(:installation_ref, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 64]
    )

    attribute(:external_account_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]
    )

    attribute(:external_inbox_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]
    )

    attribute(:conversation_id, :integer, allow_nil?: false, public?: true, constraints: [min: 1])
    attribute(:contact_id, :integer, public?: true, allow_nil?: true, constraints: [min: 1])

    attribute(:generation, :integer,
      public?: true,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1]
    )

    attribute(:ownership_epoch, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:state, :atom,
      public?: true,
      allow_nil?: false,
      default: :unverified,
      constraints: [one_of: [:unverified, :bot_active, :handoff_pending, :human_active, :closed]]
    )

    attribute(:human_inhibit, :boolean, public?: true, allow_nil?: false, default: false)

    attribute(:observed_status, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [one_of: [:pending, :open, :resolved]]
    )

    attribute(:observed_assignee, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [one_of: [:bot, :human, :unassigned]]
    )

    attribute(:observed_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:closed_at, :utc_datetime_usec, public?: true, allow_nil?: true)

    attribute(:reason_code, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [
        one_of: VoelgoedAi.Support.ReasonCode.values()
      ]
    )

    attribute(:correlation_id, :uuid, public?: true, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:binding, VoelgoedAi.Support.InboxBinding, allow_nil?: false, public?: true)
  end

  identities do
    identity(:conversation_generation, [
      :installation_ref,
      :external_account_id,
      :external_inbox_id,
      :conversation_id,
      :generation
    ])

    identity(:qualified_session, [
      :id,
      :installation_ref,
      :external_account_id,
      :external_inbox_id,
      :conversation_id
    ])
  end

  actions do
    read :by_conversation do
    end

    read :by_id do
    end

    create :register do
      transaction?(false)

      accept([
        :binding_id,
        :installation_ref,
        :external_account_id,
        :external_inbox_id,
        :conversation_id,
        :contact_id,
        :generation,
        :ownership_epoch,
        :human_inhibit,
        :correlation_id
      ])
    end

    update :activate_bot do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :observe_human_takeover do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :request_handoff do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :confirm_handoff do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :return_to_bot do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :close do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end

    update :verify_owner do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :ownership_epoch,
        :human_inhibit,
        :contact_id,
        :observed_status,
        :observed_assignee,
        :observed_at,
        :closed_at,
        :reason_code
      ])
    end
  end

  policies do
    policy action([
             :by_conversation,
             :by_id,
             :register,
             :activate_bot,
             :observe_human_takeover,
             :request_handoff,
             :confirm_handoff,
             :return_to_bot,
             :close,
             :verify_owner
           ]) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end
  end
end
