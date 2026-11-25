defmodule VoelgoedAi.Support.OutboundDelivery do
  @moduledoc "Durable send intent. A dispatch marker survives loss of the worker or response."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("outbound_deliveries")
    repo(VoelgoedAi.Repo)

    migration_types(
      ownership_epoch: :bigint,
      assistant_epoch: :bigint,
      binding_epoch: :bigint,
      control_epoch: :bigint,
      claim_generation: :bigint,
      attempt_count: :bigint,
      read_sequence: :bigint,
      read_count: :bigint,
      external_message_id: :bigint
    )

    references do
      reference(:session, on_delete: :restrict, on_update: :restrict)

      reference(:run,
        on_delete: :restrict,
        on_update: :restrict,
        match_with: [session_id: :session_id]
      )
    end

    custom_indexes do
      index([:run_id],
        name: "outbound_deliveries_one_reply",
        unique: true,
        where: "purpose = 'public_reply'"
      )

      index([:session_id, :ownership_epoch],
        name: "outbound_deliveries_one_handoff",
        unique: true,
        where: "purpose = 'handoff_status'"
      )
    end

    check_constraints do
      check_constraint(:purpose, "outbound_deliveries_lifecycle",
        check: """
        ownership_epoch >= 0 AND assistant_epoch >= 0 AND binding_epoch >= 0 AND control_epoch >= 0 AND
        claim_generation >= 0 AND attempt_count BETWEEN 0 AND 1 AND read_sequence >= 0 AND read_count >= 0 AND
        state IN ('pending', 'sending', 'sent', 'unknown', 'failed', 'cancelled', 'abandoned') AND
        (state = 'sending') = (lease_expires_at IS NOT NULL) AND
        (dispatch_authorized_at IS NULL OR attempt_count = 1) AND
        (state <> 'unknown' OR uncertainty_reason IS NOT NULL) AND
        (state = 'sent') = (confirmed_at IS NOT NULL) AND
        ((purpose = 'public_reply' AND visibility = 'public' AND run_id IS NOT NULL AND
          template_version IS NOT NULL AND template_hash ~ '^[a-f0-9]{64}$' AND
          (state <> 'sent' OR (external_message_id IS NOT NULL AND external_message_id > 0))) OR
         (purpose = 'handoff_status' AND visibility = 'operational' AND template_version IS NULL AND
          template_hash IS NULL AND external_message_id IS NULL))
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id, public?: true)

    attribute(:purpose, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:public_reply, :handoff_status]]
    )

    attribute(:visibility, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:public, :operational]]
    )

    attribute(:operation_ref, :uuid, public?: true, allow_nil?: false)
    attribute(:correlation_id, :uuid, public?: true, allow_nil?: false)

    attribute(:template_version, :string,
      public?: true,
      allow_nil?: true,
      constraints: [max_length: 64]
    )

    attribute(:template_hash, :string,
      public?: true,
      allow_nil?: true,
      constraints: [max_length: 64]
    )

    attribute(:ownership_epoch, :integer, public?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:assistant_epoch, :integer, public?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:binding_epoch, :integer, public?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:control_epoch, :integer, public?: true, allow_nil?: false, constraints: [min: 0])

    attribute(:claim_generation, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:attempt_count, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:read_sequence, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:read_count, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:external_message_id, :integer,
      public?: true,
      allow_nil?: true,
      constraints: [min: 1]
    )

    attribute(:deadline_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:lease_expires_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:dispatch_authorized_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:confirmed_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:recovery_deadline_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:last_read_at, :utc_datetime_usec, public?: true, allow_nil?: true)

    attribute(:state, :atom,
      public?: true,
      allow_nil?: false,
      default: :pending,
      constraints: [
        one_of: [:pending, :sending, :sent, :unknown, :failed, :cancelled, :abandoned]
      ]
    )

    attribute(:reason_code, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [
        one_of: [
          :ignored,
          :oversize,
          :admission_limited,
          :deadline,
          :scope_denied,
          :disabled,
          :human_takeover,
          :resolved,
          :stale_claim,
          :stale_policy,
          :late_input,
          :history_changed,
          :unavailable,
          :ambiguous_write,
          :awaiting_operator,
          :accepted,
          :already_human,
          :explicit_handoff,
          :manual_closure,
          :no_effect,
          :read_exhausted
        ]
      ]
    )

    attribute(:uncertainty_reason, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [
        one_of: [
          :ignored,
          :oversize,
          :admission_limited,
          :deadline,
          :scope_denied,
          :disabled,
          :human_takeover,
          :resolved,
          :stale_claim,
          :stale_policy,
          :late_input,
          :history_changed,
          :unavailable,
          :ambiguous_write,
          :awaiting_operator,
          :accepted,
          :already_human,
          :explicit_handoff,
          :manual_closure,
          :no_effect,
          :read_exhausted
        ]
      ]
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:session, VoelgoedAi.Support.SupportSession, allow_nil?: false, public?: true)
    belongs_to(:run, VoelgoedAi.Support.SupportRun, allow_nil?: true, public?: true)
  end

  identities do
    identity(:operation_ref, [:operation_ref])
  end

  actions do
    read :by_id do
    end

    read :for_session do
    end

    read :recoverable do
    end

    create :prepare do
      transaction?(false)

      accept([
        :session_id,
        :run_id,
        :purpose,
        :visibility,
        :operation_ref,
        :correlation_id,
        :template_version,
        :template_hash,
        :ownership_epoch,
        :assistant_epoch,
        :binding_epoch,
        :control_epoch,
        :deadline_at
      ])
    end

    update :reserve_read do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :claim do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :authorize_dispatch do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :confirm_sent do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :mark_unknown do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :cancel do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :fail do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :safe_retry do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :reconcile do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end

    update :abandon do
      transaction?(false)
      require_atomic?(false)

      accept([
        :state,
        :claim_generation,
        :attempt_count,
        :read_sequence,
        :read_count,
        :external_message_id,
        :lease_expires_at,
        :dispatch_authorized_at,
        :confirmed_at,
        :last_read_at,
        :recovery_deadline_at,
        :reason_code,
        :uncertainty_reason
      ])
    end
  end

  policies do
    policy action([
             :by_id,
             :for_session,
             :recoverable,
             :prepare,
             :reserve_read,
             :claim,
             :authorize_dispatch,
             :confirm_sent,
             :mark_unknown,
             :cancel,
             :fail,
             :safe_retry,
             :reconcile,
             :abandon
           ]) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end
  end
end
