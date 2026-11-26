defmodule VoelgoedAi.Support.InboundEvent do
  @moduledoc "Minimal signed receipt, with independent worker disposition."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("inbound_events")
    repo(VoelgoedAi.Repo)

    migration_types(
      external_account_id: :bigint,
      external_inbox_id: :bigint,
      conversation_id: :bigint,
      message_id: :bigint,
      contact_id: :bigint
    )

    references do
      reference(:session,
        on_delete: :restrict,
        on_update: :restrict,
        match_with: [
          installation_ref: :installation_ref,
          external_account_id: :external_account_id,
          external_inbox_id: :external_inbox_id,
          conversation_id: :conversation_id
        ]
      )
    end

    custom_indexes do
      index([:installation_ref, :external_account_id, :event_type, :message_id],
        name: "inbound_events_message_key",
        unique: true,
        where: "message_id IS NOT NULL"
      )

      index([:installation_ref, :external_account_id, :event_type, :stable_event_key],
        name: "inbound_events_stable_event_key",
        unique: true,
        where: "stable_event_key IS NOT NULL"
      )
    end

    check_constraints do
      check_constraint(:installation_ref, "inbound_events_lifecycle",
        check: """
        external_account_id > 0 AND external_inbox_id > 0 AND conversation_id > 0 AND contact_id > 0 AND
        (message_id IS NULL OR message_id > 0) AND (message_id IS NULL OR stable_event_key IS NULL) AND
        state IN ('accepted', 'dispatched', 'ignored', 'quarantined') AND
        kind IN ('input', 'oversize', 'ignored', 'observation', 'human_outbound') AND
        event_type IN ('message_created', 'message_updated', 'conversation_observed', 'unsupported') AND
        disposition IN ('covered', 'triage', 'ignored', 'observed', 'pending') AND
        (disposition = 'pending') = (processed_at IS NULL)
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
    attribute(:message_id, :integer, public?: true, allow_nil?: true, constraints: [min: 1])
    attribute(:contact_id, :integer, public?: true, allow_nil?: false, constraints: [min: 1])

    attribute(:stable_event_key, :string,
      public?: true,
      allow_nil?: true,
      constraints: [max_length: 64]
    )

    attribute(:event_type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [
        one_of: [:message_created, :message_updated, :conversation_observed, :unsupported]
      ]
    )

    attribute(:kind, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:input, :oversize, :ignored, :observation, :human_outbound]]
    )

    attribute(:received_at, :utc_datetime_usec, public?: true, allow_nil?: false)

    attribute(:state, :atom,
      public?: true,
      allow_nil?: false,
      default: :accepted,
      constraints: [one_of: [:accepted, :dispatched, :ignored, :quarantined]]
    )

    attribute(:disposition, :atom,
      public?: true,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:covered, :triage, :ignored, :observed, :pending]]
    )

    attribute(:reason_code, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [
        one_of: VoelgoedAi.Support.ReasonCode.values()
      ]
    )

    attribute(:processed_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:correlation_id, :uuid, public?: true, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:session, VoelgoedAi.Support.SupportSession, allow_nil?: true, public?: true)
  end

  actions do
    action :process_receipt, :atom do
      argument(:id, :uuid, allow_nil?: false)
      run(VoelgoedAi.Support.JobAction)
    end

    read :by_identity do
    end

    read :by_id do
    end

    read :pending do
    end

    create :register do
      transaction?(false)

      accept([
        :installation_ref,
        :external_account_id,
        :external_inbox_id,
        :conversation_id,
        :contact_id,
        :event_type,
        :kind,
        :message_id,
        :stable_event_key,
        :received_at,
        :correlation_id
      ])
    end

    update :dispatch do
      transaction?(false)
      require_atomic?(false)
      accept([:session_id])

      validate({VoelgoedAi.Support.FromState, states: [:accepted]})
      change(set_attribute(:state, :dispatched))
    end

    update :ignore do
      transaction?(false)
      require_atomic?(false)
      accept([:processed_at])

      validate({VoelgoedAi.Support.FromState, states: [:accepted]})
      change(set_attribute(:state, :ignored))
      change(set_attribute(:disposition, :ignored))
      change(set_attribute(:reason_code, :ignored))
    end

    update :quarantine do
      transaction?(false)
      require_atomic?(false)
      accept([:session_id, :reason_code, :processed_at])

      validate({VoelgoedAi.Support.FromState, states: [:accepted]})
      change(set_attribute(:state, :quarantined))
      change(set_attribute(:disposition, :triage))
    end

    update :record_disposition do
      transaction?(false)
      require_atomic?(false)
      accept([:session_id, :reason_code, :disposition, :processed_at])

      validate({VoelgoedAi.Support.FromState, states: [:dispatched]})
      validate({VoelgoedAi.Support.FromState, attribute: :disposition, states: [:pending]})
    end
  end

  policies do
    policy action([:process_receipt]) do
      authorize_if(VoelgoedAi.Support.ActionScope)
    end

    policy action([
             :by_identity,
             :by_id,
             :pending,
             :register,
             :dispatch,
             :ignore,
             :quarantine,
             :record_disposition
           ]) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end
  end
end
