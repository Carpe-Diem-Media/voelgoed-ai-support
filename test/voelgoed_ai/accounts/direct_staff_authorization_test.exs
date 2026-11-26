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
  @audit_actions [
    append: :create,
    append_knowledge: :create,
    append_publication_failure: :create,
    knowledge_rows: :read,
    append_support_operator: :create,
    append_system: :create,
    staff_security_history: :read,
    system_rows: :read
  ]
  @operational_actions [
    append_operational: :create,
    operational_history: :action,
    knowledge_history: :action,
    operational_rows: :read,
    system_history: :action
  ]

  setup do
    context = StaffFixtures.setup()
    admin = StaffFixtures.bootstrap_admin(context.admin)
    assert {:ok, %{id: id}} = Accounts.provision(admin, context.invited, [:support_operator])
    Map.merge(context, %{session: admin, target: StaffFixtures.resolve(id)})
  end

  test "the direct-call matrix covers every staff and audit action" do
    for {resource, covered} <- [
          {StaffUser, @staff_actions},
          {AuditEvent, @audit_actions ++ @operational_actions}
        ] do
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
            %VoelgoedAi.Knowledge.Storage{ref: make_ref()},
            %VoelgoedAi.Support.WorkStore{ref: make_ref()},
            %Scope{action: wrong_action, target: context.target.id},
            %Scope{action: action, target: Ash.UUIDv7.generate()}
          ] do
        assert {:ok, :denied} =
                 Repo.transact(fn ->
                   result =
                     direct_call(
                       unquote(resource),
                       unquote(type),
                       action,
                       args,
                       actor,
                       context.target
                     )

                   assert_denied(action, actor, result)
                   {:ok, :denied}
                 end)
      end
    end
  end

  # The Entra preparation rechecks the registration binding before the policy
  # runs, so a wrong binding fails there as an invalid identity.
  defp assert_denied(
         :sign_in_with_entra,
         %Scope{action: :sign_in_with_entra},
         {:error, %Ash.Error.Invalid{errors: errors}}
       ) do
    assert [%Ash.Error.Query.InvalidArgument{field: :user_info}] = errors
  end

  defp assert_denied(_action, _actor, result) do
    assert {:error, %Ash.Error.Forbidden{errors: errors}} = result
    assert Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1))
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

  defp arguments(:append_support_operator, %{session: session}) do
    %{
      actor_kind: :staff,
      actor_staff_id: session.id,
      target_kind: :support_session,
      session_target_id: Ash.UUIDv7.generate(),
      event: :request_handoff,
      reason_code: :local_operator,
      operational_before: %{status: :bot_active, ownership_epoch: 1},
      operational_after: %{status: :handoff_pending, ownership_epoch: 2},
      correlation_id: Ash.UUIDv7.generate()
    }
  end

  defp arguments(:append_knowledge, %{session: session}) do
    %{
      actor_kind: :staff,
      actor_staff_id: session.id,
      target_kind: :knowledge_revision,
      article_revision_target_id: Ash.UUIDv7.generate(),
      event: :approve,
      reason_code: :source_verified,
      operational_before: %{status: :in_review},
      operational_after: %{status: :approved},
      correlation_id: Ash.UUIDv7.generate()
    }
  end

  defp arguments(:append_publication_failure, _) do
    %{
      actor_kind: :embedding_worker,
      target_kind: :knowledge_revision,
      article_revision_target_id: Ash.UUIDv7.generate(),
      event: :fail_publication,
      reason_code: :transport_unknown,
      operational_before: %{status: :publishing},
      operational_after: %{status: :publish_failed},
      correlation_id: Ash.UUIDv7.generate()
    }
  end

  defp arguments(:knowledge_rows, _),
    do: %{id: Ash.UUIDv7.generate(), target_kind: :knowledge_revision}

  defp arguments(:append_system, _) do
    %{
      actor_kind: :support_worker,
      target_kind: :outbound_delivery,
      delivery_target_id: Ash.UUIDv7.generate(),
      event: :delivery_unknown,
      reason_code: :ambiguous_write,
      correlation_id: Ash.UUIDv7.generate()
    }
  end

  defp arguments(:system_rows, _),
    do: %{id: Ash.UUIDv7.generate(), target_kind: :outbound_delivery}

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
