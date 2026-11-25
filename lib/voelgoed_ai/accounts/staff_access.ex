defmodule VoelgoedAi.Accounts.StaffAccess do
  @moduledoc "Rechecks a session against the current local staff row and registration."

  alias VoelgoedAi.Accounts.{EntraConfig, StaffUser}
  alias VoelgoedAi.Repo

  defmodule Session do
    @moduledoc false
    @enforce_keys [:id, :generation, :expiry, :binding]
    defstruct @enforce_keys
  end

  defmodule Scope do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    @enforce_keys [:action, :target]
    defstruct @enforce_keys

    @impl true
    def describe(_opts), do: "a trusted application scope matches the action and target"

    @impl true
    # Ash reselects write results through the primary read when applying field
    # policies. The action policy already authorizes the scoped write itself.
    def match?(%__MODULE__{action: action} = scope, context, opts)
        when action in [:provision, :authenticate, :set_roles, :disable, :reactivate, :retire] do
      if opts[:field_access?], do: true, else: scoped_match?(scope, context)
    end

    def match?(scope, context, _opts), do: scoped_match?(scope, context)

    defp scoped_match?(
           %__MODULE__{action: action, target: target},
           %{subject: %{action: %{name: action}} = subject}
         ) do
      matches_target?(action, target, subject) and
        (not is_struct(subject, Ash.Changeset) or Repo.in_transaction?())
    end

    defp scoped_match?(_, _), do: false

    defp matches_target?(:sign_in_with_entra, binding, %Ash.Query{context: context}) do
      with true <- get_in(context, [:private, :ash_authentication?]),
           {:ok, registration} <- EntraConfig.enabled() do
        binding == VoelgoedAi.Accounts.StaffAccess.registration_binding(registration)
      else
        _ -> false
      end
    end

    defp matches_target?(:bootstrap_check, :first_staff, %Ash.Query{}), do: true

    defp matches_target?(action, id, %Ash.Query{} = query)
         when action in [:resolve_staff, :read_self, :read_staff],
         do: id == Ash.Query.get_argument(query, :id)

    defp matches_target?(:staff_security_history, id, %Ash.Query{} = query),
      do: id == Ash.Query.get_argument(query, :target_id)

    defp matches_target?(:append, {id, event}, %Ash.Changeset{} = changeset),
      do:
        id == Ash.Changeset.get_attribute(changeset, :target_id) and
          event == Ash.Changeset.get_attribute(changeset, :event)

    defp matches_target?(:provision, {issuer, subject}, %Ash.Changeset{} = changeset),
      do:
        issuer == Ash.Changeset.get_attribute(changeset, :identity_issuer) and
          subject == Ash.Changeset.get_attribute(changeset, :identity_subject)

    defp matches_target?(_action, id, %Ash.Changeset{data: %{id: id}}) when is_binary(id),
      do: true

    defp matches_target?(_, _, _), do: false
  end

  @roles [:admin, :knowledge_editor, :knowledge_reviewer, :support_operator]

  def roles, do: @roles

  def canonical_roles(roles) when is_list(roles) and length(roles) <= length(@roles) do
    if Enum.all?(roles, &(&1 in @roles)),
      do: {:ok, Enum.filter(@roles, &(&1 in roles))},
      else: {:error, :invalid_roles}
  end

  def canonical_roles(_), do: {:error, :invalid_roles}

  def registration_binding(%{issuer: issuer, client_id: client}),
    do: :crypto.hash(:sha256, issuer <> ":" <> client) |> Base.url_encode64(padding: false)

  def issue(staff) do
    %Session{
      id: staff.id,
      generation: staff.session_generation,
      expiry: System.system_time(:second) + 600,
      binding:
        registration_binding(%{
          issuer: staff.identity_issuer,
          client_id: staff.identity_client_id
        })
    }
  end

  def allowed?(
        staff,
        %Session{id: id, generation: generation, expiry: expiry, binding: binding},
        role
      ) do
    with {:ok, registration} <- EntraConfig.enabled() do
      staff.id == id and staff.status == :active and staff.session_generation == generation and
        is_integer(expiry) and expiry > System.system_time(:second) and
        binding == registration_binding(registration) and bound_to?(staff, registration) and
        (is_nil(role) or role in staff.roles)
    else
      _ -> false
    end
  end

  def allowed?(_, _, _), do: false

  def bound_to?(staff, %{issuer: issuer, tenant_id: tenant, client_id: client}),
    do:
      staff.identity_issuer == issuer and staff.tenant_id == tenant and
        staff.identity_client_id == client

  def locked_staff(id) do
    StaffUser
    |> Ash.Query.for_read(:resolve_staff, %{id: id},
      actor: %Scope{action: :resolve_staff, target: id}
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %StaffUser{} = staff} -> {:ok, staff}
      _ -> {:error, :denied}
    end
  end

  def with_current(%Session{id: id}, _role, _fun) when not is_binary(id), do: {:error, :denied}

  def with_current(%Session{id: id} = session, role, fun) do
    Repo.transact(fn ->
      with {:ok, staff} <- locked_staff(id),
           true <- allowed?(staff, session, role) do
        fun.(staff)
      else
        _ -> {:error, :denied}
      end
    end)
  end

  def with_current(_, _, _), do: {:error, :denied}

  def read_self(session),
    do: with_current(session, nil, &projected_read(:read_self, &1.id))

  def read_staff(session, id) do
    if EntraConfig.uuid_text?(id) do
      with_current(session, :admin, fn _admin -> projected_read(:read_staff, id) end)
    else
      {:error, :denied}
    end
  end

  defp projected_read(action, id) do
    StaffUser
    |> Ash.Query.for_read(action, %{id: id}, actor: %Scope{action: action, target: id})
    |> Ash.read_one()
    |> case do
      {:ok, %StaffUser{} = staff} -> {:ok, projection(staff)}
      _ -> {:error, :denied}
    end
  end

  def require_role(session, role) when role in @roles,
    do: with_current(session, role, fn _ -> {:ok, :authorized} end)

  def require_role(_, _), do: {:error, :denied}

  def projection(staff), do: Map.take(staff, [:id, :status, :roles, :last_authenticated_at])
end
