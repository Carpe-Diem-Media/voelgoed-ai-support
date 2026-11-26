defmodule VoelgoedAi.Feasibility.EntraStore do
  @moduledoc false

  alias VoelgoedAi.Feasibility.{EntraAudit, EntraProvider, EntraStaff}
  alias VoelgoedAi.Repo

  def create_schema! do
    config = Repo.config()
    port = Keyword.fetch!(config, :port)

    true =
      port == 55433 or
        (port == 55434 and config[:hostname] == "127.0.0.1" and
           System.get_env("VGAS_VERIFY_PGVECTOR") == "true")

    %{rows: [["vgas_test", "vgas_test"]]} =
      Repo.query!("SELECT current_database(), current_user")

    schema = "vgas_f08_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, _} =
      Repo.transact(fn ->
        Repo.query!("CREATE SCHEMA #{schema}")

        Repo.query!("""
        CREATE TABLE #{schema}.staff (
          id uuid PRIMARY KEY,
          issuer text NOT NULL,
          subject text NOT NULL,
          tenant_id text NOT NULL,
          status text NOT NULL CHECK (status IN ('invited', 'active', 'disabled')),
          roles text[] NOT NULL CHECK (
            roles <@ ARRAY['admin', 'knowledge_editor', 'knowledge_reviewer', 'support_operator']
          ),
          generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
          last_authenticated_at timestamp(6),
          disabled_at timestamp(6),
          inserted_at timestamp(6) NOT NULL,
          updated_at timestamp(6) NOT NULL,
          UNIQUE (issuer, subject)
        )
        """)

        Repo.query!("""
        CREATE TABLE #{schema}.audit (
          id uuid PRIMARY KEY,
          target_id uuid NOT NULL REFERENCES #{schema}.staff(id),
          actor_kind text NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          reason text NOT NULL,
          metadata jsonb NOT NULL,
          correlation_id uuid NOT NULL UNIQUE,
          inserted_at timestamp(6) NOT NULL
        )
        """)

        {:ok, schema}
      end)

    schema
  end

  def drop_schema!(schema) do
    true = Regex.match?(~r/\Avgas_f08_[0-9a-f]{16}\z/, schema)

    {:ok, :ok} =
      Repo.transact(fn ->
        Repo.query!("DROP TABLE #{schema}.audit")
        Repo.query!("DROP TABLE #{schema}.staff")
        Repo.query!("DROP SCHEMA #{schema}")
        {:ok, :ok}
      end)

    :ok
  end

  def staff_snapshot(schema) do
    Repo.query!("SELECT id::text, status, generation FROM #{schema}.staff ORDER BY id").rows
  end

  def invite(schema, subject, roles) do
    actor = %{kind: :bootstrap}

    Repo.transact(fn ->
      changeset =
        Ash.Changeset.for_create(EntraStaff, :provision, %{
          issuer: EntraProvider.issuer(),
          subject: subject,
          tenant_id: EntraProvider.tenant(),
          roles: roles
        })

      with {:ok, staff} <- Ash.create(changeset, tenant: schema, actor: actor),
           {:ok, _} <- append_audit(schema, :provision, actor, nil, staff) do
        {:ok, staff}
      end
    end)
  end

  def member(schema, id, lock \\ nil) do
    EntraStaff
    |> Ash.Query.for_read(:resolve_member, %{id: id})
    |> Ash.Query.lock(lock)
    |> Ash.read_one(tenant: schema, actor: %{kind: :member_lookup})
  end

  def activate(schema, candidate, %{kind: :entra_callback, schema: schema} = actor) do
    %{id: id, issuer: issuer, subject: subject, tenant_id: tenant} = candidate

    Repo.transact(fn ->
      with {:ok, %{issuer: ^issuer, subject: ^subject, tenant_id: ^tenant} = current} <-
             member(schema, id, :for_update),
           true <- current.status in [:invited, :active],
           event = if(current.status == :invited, do: :activate, else: :login),
           {:ok, staff} <- change(schema, current, :record_login, %{}),
           {:ok, _} <- append_audit(schema, event, Map.put(actor, :id, id), current, staff) do
        {:ok, staff}
      else
        _ -> {:error, :denied}
      end
    end)
  end

  def activate(_schema, _candidate, _actor), do: {:error, :denied}

  def manage(schema, %{kind: :session, id: admin_id, schema: schema} = actor, id, action, attrs)
      when action in [:change_roles, :disable] do
    Repo.transact(fn ->
      # Lock both records in ID order. Recheck the administrator against the
      # locked row so a committed revocation wins before a subsequent mutation.
      with {:ok, records} <- lock_members(schema, Enum.sort(Enum.uniq([admin_id, id]))),
           true <- allowed?(records[admin_id], actor, :admin),
           %{status: status} = current when status in [:invited, :active] <- records[id],
           {:ok, staff} <- apply_management(schema, current, action, attrs),
           {:ok, _} <- append_audit(schema, action, actor, current, staff) do
        {:ok, staff}
      else
        _ -> {:error, :denied}
      end
    end)
  end

  def manage(_schema, _actor, _id, _action, _attrs), do: {:error, :denied}

  def allowed?(%{id: id, status: :active, generation: generation, roles: roles}, actor, role) do
    with %{id: ^id, generation: ^generation, expiry: expiry} when is_integer(expiry) <- actor do
      expiry > System.system_time(:second) and role in roles
    else
      _ -> false
    end
  end

  def allowed?(_, _, _), do: false

  defp lock_members(schema, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, records} ->
      case member(schema, id, :for_update) do
        {:ok, %EntraStaff{} = staff} -> {:cont, {:ok, Map.put(records, id, staff)}}
        _ -> {:halt, {:error, :denied}}
      end
    end)
  end

  defp apply_management(schema, current, :change_roles, %{roles: roles}) when is_list(roles) do
    roles = Enum.sort(Enum.uniq(roles))

    if roles == Enum.sort(current.roles) do
      {:error, :unchanged}
    else
      change(schema, current, :change_roles, %{roles: roles})
    end
  end

  defp apply_management(schema, current, :disable, %{}) do
    change(schema, current, :disable, %{})
  end

  defp apply_management(_schema, _current, _action, _attrs), do: {:error, :denied}

  defp change(schema, current, action, attrs) do
    Ash.update(
      Ash.Changeset.for_update(current, action, attrs),
      tenant: schema,
      actor: %{kind: :locked_transition, action: action, target_id: current.id, schema: schema}
    )
  end

  defp append_audit(schema, action, actor, previous, current) do
    reason =
      case actor.kind do
        :bootstrap -> :allowlisted
        :entra_callback -> :verified_oidc
        :session -> :local_admin
      end

    EntraAudit
    |> Ash.Changeset.for_create(:append, %{
      target_id: current.id,
      actor_kind: actor.kind,
      actor_id: actor[:id],
      action: action,
      reason: reason,
      metadata: %{before: audit_state(previous), after: audit_state(current)},
      correlation_id: Ash.UUIDv7.generate()
    })
    |> Ash.create(tenant: schema, actor: %{kind: :audit_append})
  end

  defp audit_state(nil), do: nil
  defp audit_state(staff), do: Map.take(staff, [:status, :roles, :generation])
end

defmodule VoelgoedAi.Feasibility.EntraDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Feasibility.EntraStaff)
    resource(VoelgoedAi.Feasibility.EntraAudit)
  end
end

defmodule VoelgoedAi.Feasibility.EntraStaff do
  @moduledoc false
  use Ash.Resource,
    domain: VoelgoedAi.Feasibility.EntraDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  postgres do
    table("staff")
    repo(VoelgoedAi.Repo)
  end

  multitenancy do
    strategy(:context)
  end

  authentication do
    subject_name(:staff)

    strategies do
      oidc :entra do
        base_url(VoelgoedAi.Feasibility.EntraProvider.issuer())
        client_id(VoelgoedAi.Feasibility.EntraProvider.client_id())
        redirect_uri(VoelgoedAi.Feasibility.EntraProvider.redirect_uri())

        client_authentication_method(
          VoelgoedAi.Feasibility.EntraProvider.client_authentication_method()
        )

        registration_enabled?(false)
        identity_resource(false)
        warn_on_missing_identity_resource?(false)
        trust_email_verified?(false)
        code_verifier(true)
        sign_in_action_name(:sign_in_with_entra)
      end
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:issuer, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: false]
    )

    attribute(:subject, :string,
      allow_nil?: false,
      constraints: [
        trim?: false,
        allow_empty?: false,
        max_length: 255,
        match: VoelgoedAi.Feasibility.EntraSubject.pattern()
      ]
    )

    # Ash's UUID cast trims and lowercases text. Keep the tenant claim's exact
    # text while still requiring the hyphenated UUID shape.
    attribute(:tenant_id, :string,
      allow_nil?: false,
      constraints: [
        trim?: false,
        allow_empty?: false,
        match: ~r/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i
      ]
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :invited,
      constraints: [one_of: [:invited, :active, :disabled]]
    )

    attribute(:roles, {:array, :atom},
      allow_nil?: false,
      constraints: [
        items: [one_of: [:admin, :knowledge_editor, :knowledge_reviewer, :support_operator]]
      ]
    )

    attribute(:generation, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:last_authenticated_at, :utc_datetime_usec)
    attribute(:disabled_at, :utc_datetime_usec)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:issuer_subject, [:issuer, :subject])
  end

  actions do
    create :provision do
      accept([:issuer, :subject, :tenant_id, :roles])
    end

    read :resolve_member do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    update :record_login do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :active))
      change(set_attribute(:last_authenticated_at, &DateTime.utc_now/0))
    end

    update :change_roles do
      accept([:roles])
      require_atomic?(false)
      change(increment(:generation))
    end

    update :disable do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :disabled))
      change(set_attribute(:disabled_at, &DateTime.utc_now/0))
      change(increment(:generation))
    end

    action :admin_probe, :boolean do
      run(fn _, _ -> {:ok, true} end)
    end

    action :reviewer_probe, :boolean do
      run(fn _, _ -> {:ok, true} end)
    end

    read :sign_in_with_entra do
      argument(:user_info, :map, allow_nil?: false, sensitive?: true)
      argument(:oauth_tokens, :map, allow_nil?: false, sensitive?: true)
      prepare(VoelgoedAi.Feasibility.EntraClaims)
      prepare(AshAuthentication.Strategy.OAuth2.SignInPreparation)
    end
  end

  policies do
    policy action(:provision) do
      authorize_if(actor_attribute_equals(:kind, :bootstrap))
    end

    policy action(:resolve_member) do
      authorize_if(actor_attribute_equals(:kind, :member_lookup))
    end

    policy action([:record_login, :change_roles, :disable]) do
      authorize_if(VoelgoedAi.Feasibility.EntraTransitionPolicy)
    end

    policy action(:admin_probe) do
      authorize_if({VoelgoedAi.Feasibility.EntraSessionRole, role: :admin})
    end

    policy action(:reviewer_probe) do
      authorize_if({VoelgoedAi.Feasibility.EntraSessionRole, role: :knowledge_reviewer})
    end

    policy action(:sign_in_with_entra) do
      forbid_unless(actor_attribute_equals(:kind, :entra_callback))
      authorize_if(context_equals([:private, :ash_authentication?], true))
    end
  end
end

defmodule VoelgoedAi.Feasibility.EntraAudit do
  @moduledoc false
  use Ash.Resource,
    domain: VoelgoedAi.Feasibility.EntraDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("audit")
    repo(VoelgoedAi.Repo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:target_id, :uuid, allow_nil?: false)

    attribute(:actor_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:bootstrap, :entra_callback, :session]]
    )

    attribute(:actor_id, :uuid)

    attribute(:action, :atom,
      allow_nil?: false,
      constraints: [one_of: [:provision, :activate, :login, :change_roles, :disable]]
    )

    attribute(:reason, :atom,
      allow_nil?: false,
      constraints: [one_of: [:allowlisted, :verified_oidc, :local_admin]]
    )

    attribute(:metadata, :map, allow_nil?: false)
    attribute(:correlation_id, :uuid, allow_nil?: false)
    create_timestamp(:inserted_at)
  end

  actions do
    create :append do
      accept([:target_id, :actor_kind, :actor_id, :action, :reason, :metadata, :correlation_id])
    end

    read(:evidence)
  end

  policies do
    policy action(:append) do
      authorize_if(actor_attribute_equals(:kind, :audit_append))
    end

    policy action(:evidence) do
      authorize_if(actor_attribute_equals(:kind, :audit_evidence))
    end
  end
end
