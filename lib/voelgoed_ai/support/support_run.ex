defmodule VoelgoedAi.Support.SupportRun do
  @moduledoc "One fenced work claim with an immutable parent turn deadline and pinned revision."

  use Ash.Resource,
    domain: VoelgoedAi.Support,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("support_runs")
    repo(VoelgoedAi.Repo)

    migration_types(
      ownership_epoch: :bigint,
      assistant_epoch: :bigint,
      binding_epoch: :bigint,
      control_epoch: :bigint,
      claim_generation: :bigint,
      attempt_count: :bigint,
      watermark: :bigint,
      regroup_count: :bigint
    )

    references do
      reference(:session, on_delete: :restrict, on_update: :restrict)
      reference(:assistant_revision, on_delete: :restrict, on_update: :restrict)

      reference(:parent_run,
        on_delete: :restrict,
        on_update: :restrict,
        match_with: [session_id: :session_id]
      )
    end

    custom_indexes do
      index([:session_id],
        name: "support_runs_one_active",
        unique: true,
        where: "state IN ('queued', 'running', 'retry_wait')"
      )
    end

    check_constraints do
      check_constraint(:turn_ref, "support_runs_lifecycle",
        check: """
        ownership_epoch >= 0 AND assistant_epoch >= 0 AND binding_epoch >= 0 AND control_epoch >= 0 AND
        claim_generation >= 0 AND attempt_count >= 0 AND watermark >= 0 AND regroup_count BETWEEN 0 AND 1 AND
        state IN ('queued', 'running', 'retry_wait', 'completed', 'cancelled', 'superseded', 'failed') AND
        (state = 'running') = (lease_expires_at IS NOT NULL) AND
        (state = 'retry_wait') = (retry_at IS NOT NULL) AND
        (state = 'completed') = (decision IS NOT NULL) AND
        (state IN ('completed', 'cancelled', 'superseded', 'failed')) = (finished_at IS NOT NULL)
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id, public?: true)
    attribute(:turn_ref, :uuid, public?: true, allow_nil?: false)
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

    attribute(:watermark, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:regroup_count, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:deadline_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:batch_cutoff_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:lease_expires_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:retry_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true, allow_nil?: true)
    attribute(:finished_at, :utc_datetime_usec, public?: true, allow_nil?: true)

    attribute(:decision, :atom,
      public?: true,
      allow_nil?: true,
      constraints: [one_of: [:fixed_reply, :handoff, :no_send]]
    )

    attribute(:state, :atom,
      public?: true,
      allow_nil?: false,
      default: :queued,
      constraints: [
        one_of: [:queued, :running, :retry_wait, :completed, :cancelled, :superseded, :failed]
      ]
    )

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
    belongs_to(:session, VoelgoedAi.Support.SupportSession, allow_nil?: false, public?: true)

    belongs_to(:assistant_revision, VoelgoedAi.Intelligence.AssistantRevision,
      allow_nil?: false,
      public?: true
    )

    belongs_to(:parent_run, __MODULE__, allow_nil?: true, public?: true)
  end

  identities do
    identity(:same_session_run, [:id, :session_id])
    identity(:same_assistant_revision, [:id, :assistant_revision_id])
  end

  actions do
    action :process_run, :atom do
      argument(:id, :uuid, allow_nil?: false)
      run(VoelgoedAi.Support.JobAction)
    end

    action :recover_run, :atom do
      argument(:id, :uuid, allow_nil?: false)
      run(VoelgoedAi.Support.JobAction)
    end

    read :by_id do
    end

    read :active do
    end

    read :recoverable do
    end

    create :queue do
      transaction?(false)

      accept([
        :session_id,
        :assistant_revision_id,
        :parent_run_id,
        :turn_ref,
        :ownership_epoch,
        :assistant_epoch,
        :binding_epoch,
        :control_epoch,
        :deadline_at,
        :batch_cutoff_at,
        :watermark,
        :regroup_count,
        :correlation_id
      ])
    end

    update :extend_batch do
      transaction?(false)
      require_atomic?(false)
      accept([:batch_cutoff_at, :watermark])

      validate({VoelgoedAi.Support.FromState, states: [:queued]})
    end

    update :claim do
      transaction?(false)
      require_atomic?(false)
      accept([:claim_generation, :attempt_count, :lease_expires_at, :started_at])

      validate({VoelgoedAi.Support.FromState, states: [:queued]})
      change(set_attribute(:state, :running))
    end

    update :complete do
      transaction?(false)
      require_atomic?(false)
      accept([:decision, :finished_at])

      validate({VoelgoedAi.Support.FromState, states: [:running]})
      change(set_attribute(:state, :completed))
      change(set_attribute(:lease_expires_at, nil))
    end

    update :cancel do
      transaction?(false)
      require_atomic?(false)
      accept([:finished_at, :reason_code])

      validate({VoelgoedAi.Support.FromState, states: [:queued, :running, :retry_wait]})
      change(set_attribute(:state, :cancelled))
      change(set_attribute(:lease_expires_at, nil))
      change(set_attribute(:retry_at, nil))
    end

    update :supersede do
      transaction?(false)
      require_atomic?(false)
      accept([:finished_at, :reason_code])

      validate({VoelgoedAi.Support.FromState, states: [:queued, :running, :retry_wait]})
      change(set_attribute(:state, :superseded))
      change(set_attribute(:lease_expires_at, nil))
      change(set_attribute(:retry_at, nil))
    end

    update :fail do
      transaction?(false)
      require_atomic?(false)
      accept([:finished_at, :reason_code])

      validate({VoelgoedAi.Support.FromState, states: [:queued, :running, :retry_wait]})
      change(set_attribute(:state, :failed))
      change(set_attribute(:lease_expires_at, nil))
      change(set_attribute(:retry_at, nil))
    end

    update :schedule_retry do
      transaction?(false)
      require_atomic?(false)
      accept([:retry_at, :reason_code])

      validate({VoelgoedAi.Support.FromState, states: [:running]})
      change(set_attribute(:state, :retry_wait))
      change(set_attribute(:lease_expires_at, nil))
    end

    update :requeue do
      transaction?(false)
      require_atomic?(false)
      accept([])

      validate({VoelgoedAi.Support.FromState, states: [:retry_wait]})
      change(set_attribute(:state, :queued))
      change(set_attribute(:retry_at, nil))
    end

    update :recover_expired_claim do
      transaction?(false)
      require_atomic?(false)
      accept([:claim_generation, :retry_at])

      validate({VoelgoedAi.Support.FromState, states: [:running]})
      change(set_attribute(:state, :retry_wait))
      change(set_attribute(:lease_expires_at, nil))
    end
  end

  policies do
    policy action([:process_run, :recover_run]) do
      authorize_if(VoelgoedAi.Support.ActionScope)
    end

    policy action([
             :by_id,
             :active,
             :recoverable,
             :queue,
             :extend_batch,
             :claim,
             :complete,
             :cancel,
             :supersede,
             :fail,
             :schedule_retry,
             :requeue,
             :recover_expired_claim
           ]) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end
  end
end
