defmodule VoelgoedAi.Governance.AuditEvent do
  @moduledoc "An immutable staff security event with only local references and authorization state."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Accounts.{StaffAccess, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.Scope

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
    end

    check_constraints do
      check_constraint(:actor_kind, "audit_events_actor_reference",
        check: """
        (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
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
      constraints: [one_of: [:staff_user]]
    )

    attribute(:event, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :provisioned,
          :activated,
          :signed_in,
          :roles_changed,
          :disabled,
          :reactivated,
          :retired
        ]
      ]
    )

    attribute(:reason_code, :atom,
      allow_nil?: false,
      constraints: [one_of: [:allowlisted, :verified_oidc, :local_admin, :approved_reprovision]]
    )

    attribute(:before_state, :map, constraints: [fields: @state_fields])
    attribute(:after_state, :map, allow_nil?: false, constraints: [fields: @state_fields])
    attribute(:correlation_id, :uuid, allow_nil?: false)
    attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:target, StaffUser, allow_nil?: false)
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
    end

    read :staff_security_history do
      argument(:target_id, :uuid, allow_nil?: false)
      filter(expr(target_id == ^arg(:target_id)))
      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end
  end

  policies do
    policy action([:append, :staff_security_history]) do
      authorize_if(Scope)
    end
  end
end
