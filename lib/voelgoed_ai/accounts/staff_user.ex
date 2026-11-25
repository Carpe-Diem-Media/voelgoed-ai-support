defmodule VoelgoedAi.Accounts.StaffUser do
  @moduledoc "An allowlisted Entra identity with its current local permissions."

  use Ash.Resource,
    domain: VoelgoedAi.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Accounts.{EntraConfig, StaffAccess}
  alias VoelgoedAi.Accounts.StaffAccess.Scope

  postgres do
    table("staff_users")
    repo(VoelgoedAi.Repo)

    check_constraints do
      check_constraint(:status, "staff_users_status_timestamps",
        check: """
        (status IN ('invited','active') AND disabled_at IS NULL AND retired_at IS NULL) OR
        (status = 'disabled' AND disabled_at IS NOT NULL AND retired_at IS NULL) OR
        (status = 'retired' AND disabled_at IS NOT NULL AND retired_at >= disabled_at AND retired_at IS NOT NULL)
        """
      )

      check_constraint(:roles, "staff_users_roles",
        check: """
        roles <@ ARRAY['admin','knowledge_editor','knowledge_reviewer','support_operator']::text[]
        AND array_position(roles, NULL::text) IS NULL
        """
      )

      check_constraint(:session_generation, "staff_users_generation_nonnegative",
        check: "session_generation >= 0"
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:identity_issuer, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, allow_empty?: false, max_length: 255]
    )

    attribute(:identity_subject, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [
        trim?: false,
        allow_empty?: false,
        max_length: 255,
        match: EntraConfig.subject_pattern()
      ]
    )

    attribute(:tenant_id, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, allow_empty?: false, max_length: 36]
    )

    attribute(:identity_client_id, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, allow_empty?: false, max_length: 36]
    )

    attribute(:email, :string, sensitive?: true, constraints: [max_length: 254])
    attribute(:display_name, :string, sensitive?: true, constraints: [max_length: 255])

    attribute(:roles, {:array, :atom},
      allow_nil?: false,
      constraints: [max_length: 4, items: [one_of: StaffAccess.roles()]]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :invited,
      constraints: [one_of: [:invited, :active, :disabled, :retired]]
    )

    attribute(:session_generation, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:last_authenticated_at, :utc_datetime_usec)
    attribute(:disabled_at, :utc_datetime_usec)
    attribute(:retired_at, :utc_datetime_usec)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:issuer_subject, [:identity_issuer, :identity_subject])
  end

  actions do
    read :bootstrap_check do
      primary?(true)
    end

    read :resolve_staff do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    create :provision do
      transaction?(false)
      accept([:identity_issuer, :identity_subject, :tenant_id, :identity_client_id, :roles])
    end

    update :authenticate do
      transaction?(false)
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :active))
      change(set_attribute(:last_authenticated_at, &DateTime.utc_now/0))
    end

    update :set_roles do
      transaction?(false)
      accept([:roles])
      require_atomic?(false)
      change(increment(:session_generation))
    end

    update :disable do
      transaction?(false)
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :disabled))
      change(set_attribute(:disabled_at, &DateTime.utc_now/0))
      change(increment(:session_generation))
    end

    update :reactivate do
      transaction?(false)
      accept([:roles])
      require_atomic?(false)
      change(set_attribute(:status, :active))
      change(set_attribute(:disabled_at, nil))
      change(increment(:session_generation))
    end

    update :retire do
      transaction?(false)
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :retired))
      change(set_attribute(:retired_at, &DateTime.utc_now/0))
      change(increment(:session_generation))
    end
  end

  policies do
    policy action([
             :bootstrap_check,
             :resolve_staff,
             :provision,
             :authenticate,
             :set_roles,
             :disable,
             :reactivate,
             :retire
           ]) do
      authorize_if(Scope)
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [
      :identity_issuer,
      :identity_subject,
      :tenant_id,
      :identity_client_id,
      :session_generation,
      :email,
      :display_name
    ] do
      authorize_if({Scope, field_access?: true})
    end

    field_policy :* do
      authorize_if(always())
    end
  end
end
