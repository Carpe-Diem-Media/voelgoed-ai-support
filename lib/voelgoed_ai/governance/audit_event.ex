defmodule VoelgoedAi.Governance.AuditEvent do
  @moduledoc "An immutable staff security or support configuration event with local references."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Accounts.{StaffAccess, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.Scope

  alias VoelgoedAi.Support.{ActionScope, Configuration}

  @staff_events [
    :provisioned,
    :activated,
    :signed_in,
    :roles_changed,
    :disabled,
    :reactivated,
    :retired
  ]
  @operational_events [
    :create,
    :activate,
    :disable,
    :retire,
    :switch_revision,
    :create_draft,
    :edit_draft,
    :publish,
    :supersede,
    :discard,
    :enable,
    :rebind,
    :change_mode,
    :enable_automation,
    :disable_automation
  ]
  @target_kinds [:assistant, :assistant_revision, :inbox_binding, :automation_control]
  @support_events [:request_handoff, :return_to_bot, :close_session, :abandon_delivery]
  @operational_fields [
    ownership_epoch: [type: :integer, constraints: [min: 0]],
    status: [
      type: :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :active,
          :disabled,
          :enabled,
          :retired,
          :draft,
          :published,
          :superseded,
          :discarded,
          :unverified,
          :bot_active,
          :handoff_pending,
          :human_active,
          :closed,
          :unknown,
          :abandoned
        ]
      ]
    ],
    security_epoch: [type: :integer, constraints: [min: 0]],
    slug: [type: :string, constraints: [max_length: 64]],
    display_name: [type: :string, constraints: [max_length: 120]],
    kind: [type: :atom, constraints: [one_of: [:customer_support]]],
    audience: [type: :atom, constraints: [one_of: [:public, :internal]]],
    active_revision_id: [type: :uuid],
    assistant_id: [type: :uuid],
    revision_number: [type: :integer, constraints: [min: 1]],
    workflow_version: [type: :string, constraints: [max_length: 64]],
    template_version: [type: :string, constraints: [max_length: 64]],
    locale: [type: :atom, constraints: [one_of: [:af, :en]]],
    response_policy: [type: :atom, constraints: [one_of: [:fixed_reply, :handoff]]],
    config_hash: [type: :string, constraints: [max_length: 64]],
    installation_ref: [type: :string, constraints: [max_length: 64]],
    external_account_id: [type: :integer, constraints: [min: 1]],
    external_inbox_id: [type: :integer, constraints: [min: 1]],
    handoff_team_id: [type: :integer, constraints: [min: 1]],
    operating_mode: [type: :atom, constraints: [one_of: [:shadow, :assisted, :automatic]]],
    mode: [type: :atom, constraints: [one_of: [:disabled, :fake]]]
  ]

  @state_fields [
    status: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:invited, :active, :disabled, :retired]]
    ],
    roles: [
      type: {:array, :atom},
      allow_nil?: false,
      constraints: [max_length: 4, items: [one_of: StaffAccess.roles()]]
    ],
    session_generation: [type: :integer, allow_nil?: false, constraints: [min: 0]]
  ]

  postgres do
    table("audit_events")
    repo(VoelgoedAi.Repo)

    references do
      reference(:target, on_delete: :restrict, on_update: :restrict)
      reference(:actor_staff, on_delete: :restrict, on_update: :restrict)
      reference(:assistant_target, on_delete: :restrict, on_update: :restrict)
      reference(:revision_target, on_delete: :restrict, on_update: :restrict)
      reference(:binding_target, on_delete: :restrict, on_update: :restrict)
      reference(:control_target, on_delete: :restrict, on_update: :restrict)
      reference(:session_target, on_delete: :restrict, on_update: :restrict)
      reference(:delivery_target, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:actor_kind, "audit_events_actor_reference",
        check: """
        (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
        """
      )

      check_constraint(:target_kind, "audit_events_exact_target",
        check: """
          num_nonnulls(target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id) = 1
          AND (
            (target_kind = 'staff_user' AND target_id IS NOT NULL
              AND event IN ('provisioned','activated','signed_in','roles_changed','disabled','reactivated','retired')
              AND reason_code IN ('allowlisted','verified_oidc','local_admin','approved_reprovision'))
            OR (target_kind = 'assistant' AND assistant_target_id IS NOT NULL
              AND event IN ('create','activate','disable','retire','switch_revision'))
            OR (target_kind = 'assistant_revision' AND revision_target_id IS NOT NULL
              AND event IN ('create_draft','edit_draft','publish','supersede','discard'))
            OR (target_kind = 'inbox_binding' AND binding_target_id IS NOT NULL
              AND event IN ('create_draft','enable','disable','rebind','change_mode','retire'))
            OR (target_kind = 'automation_control' AND control_target_id IS NOT NULL
              AND event IN ('enable_automation','disable_automation'))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event = 'abandon_delivery')
          )
        """
      )

      check_constraint(:target_kind, "audit_events_state_shape",
        check: """
          (target_kind = 'staff_user' AND after_state IS NOT NULL
            AND operational_before IS NULL AND operational_after IS NULL)
          OR (actor_kind = 'staff' AND before_state IS NULL AND after_state IS NULL AND operational_after IS NOT NULL
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind NOT IN ('staff_user', 'support_session', 'outbound_delivery') AND reason_code = 'local_admin')))
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:actor_kind, :atom, allow_nil?: false, constraints: [one_of: [:staff, :bootstrap]])
    attribute(:operator_ref, :string, constraints: [match: ~r/\Astaff-bootstrap\z/])

    attribute(:target_kind, :atom,
      allow_nil?: false,
      default: :staff_user,
      constraints: [one_of: [:staff_user, :support_session, :outbound_delivery | @target_kinds]]
    )

    attribute(:event, :atom,
      allow_nil?: false,
      constraints: [one_of: @staff_events ++ @operational_events ++ @support_events]
    )

    attribute(:reason_code, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :allowlisted,
          :verified_oidc,
          :local_admin,
          :approved_reprovision,
          :local_operator
        ]
      ]
    )

    attribute(:before_state, :map, constraints: [fields: @state_fields])
    attribute(:after_state, :map, constraints: [fields: @state_fields])
    attribute(:operational_before, :map, constraints: [fields: @operational_fields])
    attribute(:operational_after, :map, constraints: [fields: @operational_fields])
    attribute(:correlation_id, :uuid, allow_nil?: false)
    attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:target, StaffUser)
    belongs_to(:assistant_target, VoelgoedAi.Intelligence.Assistant)
    belongs_to(:revision_target, VoelgoedAi.Intelligence.AssistantRevision)
    belongs_to(:binding_target, VoelgoedAi.Support.InboxBinding)
    belongs_to(:control_target, VoelgoedAi.Governance.AutomationControl)
    belongs_to(:session_target, VoelgoedAi.Support.SupportSession)
    belongs_to(:delivery_target, VoelgoedAi.Support.OutboundDelivery)
    belongs_to(:actor_staff, StaffUser)
  end

  actions do
    create :append do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :operator_ref,
        :target_id,
        :event,
        :reason_code,
        :before_state,
        :after_state,
        :correlation_id
      ])

      validate(present([:target_id, :after_state]))
      validate(attribute_in(:event, @staff_events))
    end

    create :append_operational do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :assistant_target_id,
        :revision_target_id,
        :binding_target_id,
        :control_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(present([:actor_staff_id, :operational_after]))
      validate(attribute_in(:target_kind, @target_kinds))
      validate(attribute_in(:event, @operational_events))
    end

    create :append_support_operator do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :session_target_id,
        :delivery_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(present([:actor_staff_id, :operational_before, :operational_after]))
      validate(attribute_in(:event, @support_events))
      validate(attribute_equals(:reason_code, :local_operator))
    end

    action :operational_history, {:array, :map} do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @target_kinds])
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    read :operational_rows do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @target_kinds])
      argument(:id, :uuid, allow_nil?: false)

      filter(
        expr(
          target_kind == ^arg(:target_kind) and
            (assistant_target_id == ^arg(:id) or revision_target_id == ^arg(:id) or
               binding_target_id == ^arg(:id) or control_target_id == ^arg(:id))
        )
      )

      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end

    read :staff_security_history do
      argument(:target_id, :uuid, allow_nil?: false)
      filter(expr(target_kind == :staff_user and target_id == ^arg(:target_id)))
      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end
  end

  policies do
    policy action(:append_support_operator) do
      authorize_if(VoelgoedAi.Support.WorkStore)
    end

    policy action([:append_operational, :operational_rows]) do
      authorize_if(ActionScope.Storage)
    end

    policy action(:operational_history) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:append, :staff_security_history]) do
      authorize_if(Scope)
    end
  end
end
