defmodule VoelgoedAi.Accounts.StaffLifecycle do
  @moduledoc """
  Serializes staff lifecycle transitions and appends audit in the same transaction.

  Allowlist evidence comes from an operator who verified the exact pairwise
  subject for the configured registration. There is no HTTP provisioning path.
  """

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Accounts.{EntraConfig, StaffAccess, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.{Scope, Session}
  alias VoelgoedAi.Governance.AuditEvent
  alias VoelgoedAi.Repo

  # Fixed namespace for the first staff grant. No other application takes it.
  @bootstrap_lock 8_608_011

  @doc "Invite the first administrator through the controlled deployment command."
  def bootstrap(identity, [:admin]) do
    with {:ok, attrs} <- verified_identity(identity) do
      write_transaction(fn ->
        with {:ok, _} <-
               SQL.query(Repo, "SELECT pg_advisory_xact_lock($1)", [@bootstrap_lock], log: false),
             {:ok, []} <- first_staff_check() do
          insert(attrs, [:admin], :bootstrap)
        else
          {:ok, [_]} -> {:error, :bootstrap_closed}
          _ -> {:error, :staff_write_failed}
        end
      end)
    end
  end

  def bootstrap(_, _), do: {:error, :invalid_roles}

  @doc "Invite an allowlisted identity with an explicit local role set."
  def provision(session, identity, roles) do
    with {:ok, attrs} <- verified_identity(identity),
         {:ok, roles} <- StaffAccess.canonical_roles(roles) do
      StaffAccess.with_current(session, :admin, &insert(attrs, roles, &1.id))
      |> write_result()
    end
  end

  @doc "Commit a verified callback's local login and derive a session from the committed generation."
  def authenticate(
        %StaffUser{} = candidate,
        %Scope{action: :sign_in_with_entra, target: binding}
      ) do
    write_transaction(fn ->
      with {:ok, registration} <- EntraConfig.enabled(),
           true <- binding == StaffAccess.registration_binding(registration),
           {:ok, staff} <- StaffAccess.locked_staff(candidate.id),
           true <- staff.status in [:invited, :active],
           true <- StaffAccess.bound_to?(staff, registration),
           true <- staff.identity_subject == candidate.identity_subject,
           true <- StaffAccess.bound_to?(candidate, registration) do
        event = if staff.status == :invited, do: :activated, else: :signed_in

        case transition(staff, :authenticate, %{}, staff.id, event, :verified_oidc) do
          {:ok, active} -> {:ok, StaffAccess.issue(active)}
          {:error, _} = error -> error
        end
      else
        _ -> {:error, :denied}
      end
    end)
  end

  def authenticate(_, _), do: {:error, :denied}

  def set_roles(session, id, roles) do
    with {:ok, roles} <- StaffAccess.canonical_roles(roles) do
      manage(session, id, fn
        staff, _admin when staff.status in [:invited, :active] and staff.roles == roles ->
          {:ok, staff}

        staff, admin when staff.status in [:invited, :active] ->
          transition(staff, :set_roles, %{roles: roles}, admin, :roles_changed, :local_admin)

        _, _ ->
          {:error, :invalid_transition}
      end)
    end
  end

  def disable(session, id) do
    manage(session, id, fn
      %{status: :disabled} = staff, _ ->
        {:ok, staff}

      staff, admin when staff.status in [:invited, :active] ->
        transition(staff, :disable, %{}, admin, :disabled, :local_admin)

      _, _ ->
        {:error, :invalid_transition}
    end)
  end

  def reactivate(session, id, identity, roles) do
    with {:ok, attrs} <- verified_identity(identity),
         {:ok, roles} <- StaffAccess.canonical_roles(roles) do
      manage(session, id, fn staff, admin ->
        if staff.status == :disabled and Map.take(staff, Map.keys(attrs)) == attrs do
          transition(
            staff,
            :reactivate,
            %{roles: roles},
            admin,
            :reactivated,
            :approved_reprovision
          )
        else
          {:error, :invalid_transition}
        end
      end)
    end
  end

  def retire(session, id) do
    manage(session, id, fn
      %{status: :disabled} = staff, admin ->
        transition(staff, :retire, %{}, admin, :retired, :local_admin)

      _, _ ->
        {:error, :invalid_transition}
    end)
  end

  defp manage(%Session{id: admin_id} = session, id, apply) do
    if EntraConfig.uuid_text?(id) and EntraConfig.uuid_text?(admin_id) do
      write_transaction(fn ->
        # Sorting both IDs prevents a deadlock when two administrators act on one another.
        with {:ok, rows} <- lock_staff(Enum.sort(Enum.uniq([admin_id, id]))),
             true <- StaffAccess.allowed?(rows[admin_id], session, :admin),
             {:ok, staff} <- apply.(rows[id], admin_id) do
          {:ok, StaffAccess.projection(staff)}
        else
          false -> {:error, :denied}
          {:error, _} = error -> error
        end
      end)
    else
      {:error, :denied}
    end
  end

  defp manage(_, _, _), do: {:error, :denied}

  defp lock_staff(ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, rows} ->
      case StaffAccess.locked_staff(id) do
        {:ok, staff} -> {:cont, {:ok, Map.put(rows, id, staff)}}
        error -> {:halt, error}
      end
    end)
  end

  defp first_staff_check do
    StaffUser
    |> Ash.Query.for_read(:bootstrap_check, %{},
      actor: %Scope{action: :bootstrap_check, target: :first_staff}
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read()
  end

  defp verified_identity(%{
         issuer: issuer,
         subject: subject,
         tenant_id: tenant,
         client_id: client
       }) do
    with {:ok, %{issuer: ^issuer, tenant_id: ^tenant, client_id: ^client}} <-
           EntraConfig.registration(),
         true <- EntraConfig.valid_subject?(subject) do
      {:ok,
       %{
         identity_issuer: issuer,
         identity_subject: subject,
         tenant_id: tenant,
         identity_client_id: client
       }}
    else
      _ -> {:error, :invalid_allowlist_identity}
    end
  end

  defp verified_identity(_), do: {:error, :invalid_allowlist_identity}

  defp insert(attrs, roles, actor) do
    scope = %Scope{action: :provision, target: {attrs.identity_issuer, attrs.identity_subject}}

    with {:ok, staff} <-
           Ash.create(StaffUser, Map.put(attrs, :roles, roles), action: :provision, actor: scope),
         {:ok, _} <- append(nil, staff, actor, :provisioned, :allowlisted) do
      {:ok, StaffAccess.projection(staff)}
    else
      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if Enum.any?(errors, &identity_conflict?/1),
          do: {:error, :identity_conflict},
          else: {:error, :staff_write_failed}

      _ ->
        {:error, :staff_write_failed}
    end
  end

  # AshPostgres can roll back the owning transaction directly on a data-layer
  # error. Translate that rollback after it reaches the outer transaction.
  defp write_transaction(fun), do: write_result(Repo.transact(fun))

  defp write_result({:error, %Ash.Changeset{resource: StaffUser, errors: errors}}) do
    if Enum.any?(errors, &identity_conflict?/1),
      do: {:error, :identity_conflict},
      else: {:error, :staff_write_failed}
  end

  defp write_result({:error, reason}) when not is_atom(reason), do: {:error, :staff_write_failed}
  defp write_result(result), do: result

  defp identity_conflict?(%Ash.Error.Changes.InvalidAttribute{private_vars: vars}) do
    vars[:constraint_type] == :unique and vars[:constraint] == "staff_users_issuer_subject_index"
  end

  defp identity_conflict?(_), do: false

  defp transition(staff, action, attrs, actor, event, reason) do
    scope = %Scope{action: action, target: staff.id}

    with {:ok, updated} <- Ash.update(staff, attrs, action: action, actor: scope),
         {:ok, _} <- append(staff, updated, actor, event, reason) do
      {:ok, updated}
    else
      _ -> {:error, :staff_write_failed}
    end
  end

  defp append(previous, staff, actor, event, reason) do
    actor_fields =
      case actor do
        :bootstrap -> %{actor_kind: :bootstrap, operator_ref: "staff-bootstrap"}
        id -> %{actor_kind: :staff, actor_staff_id: id}
      end

    attrs =
      Map.merge(actor_fields, %{
        target_id: staff.id,
        event: event,
        reason_code: reason,
        before_state: audit_state(previous),
        after_state: audit_state(staff),
        correlation_id: Ash.UUIDv7.generate()
      })

    Ash.create(AuditEvent, attrs,
      action: :append,
      actor: %Scope{action: :append, target: {staff.id, event}}
    )
  end

  defp audit_state(nil), do: nil
  defp audit_state(staff), do: Map.take(staff, [:status, :roles, :session_generation])
end
