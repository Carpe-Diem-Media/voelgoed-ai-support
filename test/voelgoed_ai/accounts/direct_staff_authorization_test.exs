defmodule VoelgoedAi.Accounts.DirectStaffAuthorizationTest do
  use ExUnit.Case, async: false

  alias VoelgoedAi.{Accounts, Repo, StaffFixtures}
  alias VoelgoedAi.Accounts.StaffUser
  alias VoelgoedAi.Accounts.StaffAccess.Scope
  alias VoelgoedAi.Governance.AuditEvent

  @staff_actions [
    provision: :create,
    authenticate: :update,
    set_roles: :update,
    disable: :update,
    reactivate: :update,
    retire: :update,
    resolve_staff: :read,
    read_staff: :read,
    read_self: :read,
    bootstrap_check: :read,
    sign_in_with_entra: :read,
    get_by_subject: :read
  ]
  @audit_actions [append: :create, staff_security_history: :read]

  setup do
    context = StaffFixtures.setup()
    admin = StaffFixtures.bootstrap_admin(context.admin)
    assert {:ok, %{id: id}} = Accounts.provision(admin, context.invited, [:support_operator])
    Map.merge(context, %{session: admin, target: StaffFixtures.resolve(id)})
  end

  test "the direct-call matrix covers every staff and audit action" do
    for {resource, covered} <- [{StaffUser, @staff_actions}, {AuditEvent, @audit_actions}] do
      assert Ash.Resource.Info.actions(resource) |> Map.new(&{&1.name, &1.type}) ==
               Map.new(covered)
    end
  end

  for {resource, actions} <- [{StaffUser, @staff_actions}, {AuditEvent, @audit_actions}],
      {action, type} <- actions do
    wrong_action = if action == :read_staff, do: :read_self, else: :read_staff

    test "#{inspect(resource)}.#{action} denies direct calls with untrusted actors", context do
      action = unquote(action)
      session = context.session
      wrong_action = unquote(wrong_action)

      args = arguments(action, context)

      # A real transaction satisfies the write policy's transaction guard.
      for actor <- [
            nil,
            session,
            Map.from_struct(session),
            %Scope{action: wrong_action, target: context.target.id}
          ] do
        assert {:ok, :denied} =
                 Repo.transact(fn ->
                   assert {:error, %Ash.Error.Forbidden{errors: errors}} =
                            direct_call(
                              unquote(resource),
                              unquote(type),
                              action,
                              args,
                              actor,
                              context.target
                            )

                   assert Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))
                   {:ok, :denied}
                 end)
      end
    end
  end

  defp direct_call(resource, :create, action, args, actor, _),
    do: Ash.create(resource, args, action: action, actor: actor)

  defp direct_call(_, :update, action, args, actor, target),
    do: Ash.update(target, args, action: action, actor: actor)

  defp direct_call(resource, :read, action, args, actor, _) do
    resource
    |> Ash.Query.for_read(action, args,
      actor: actor,
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.read()
  end

  defp arguments(:provision, %{other: identity}) do
    %{
      identity_issuer: identity.issuer,
      identity_subject: identity.subject,
      tenant_id: identity.tenant_id,
      identity_client_id: identity.client_id,
      roles: [:admin]
    }
  end

  defp arguments(:append, %{session: session, target: target}) do
    %{
      actor_kind: :staff,
      actor_staff_id: session.id,
      target_id: target.id,
      event: :roles_changed,
      reason_code: :local_admin,
      after_state: %{status: :invited, roles: [:admin], session_generation: 1},
      correlation_id: Ash.UUIDv7.generate()
    }
  end

  defp arguments(:staff_security_history, %{target: target}), do: %{target_id: target.id}

  defp arguments(:get_by_subject, %{target: target}),
    do: %{subject: AshAuthentication.user_to_subject(target)}

  defp arguments(:sign_in_with_entra, _), do: %{user_info: %{}, oauth_tokens: %{}}
  defp arguments(action, _) when action in [:set_roles, :reactivate], do: %{roles: [:admin]}

  defp arguments(action, %{target: target})
       when action in [:resolve_staff, :read_staff, :read_self],
       do: %{id: target.id}

  defp arguments(_, _), do: %{}
end
