defmodule VoelgoedAi.Support.ConfigurationTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.StaffFixtures, only: [authenticate: 1, bootstrap_admin: 1, resolve: 1]
  import VoelgoedAi.SupportFixtures, except: [setup: 0]
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Governance, Repo}
  alias VoelgoedAi.Accounts.StaffAccess.Scope
  alias VoelgoedAi.Governance.{AuditEvent, AutomationControl}
  alias VoelgoedAi.Intelligence.{Assistant, AssistantRevision}
  alias VoelgoedAi.Support.{ActionScope, InboxBinding}
  alias VoelgoedAi.Support.ActionScope.Storage

  setup do
    VoelgoedAi.SupportFixtures.setup()
  end

  test "actions reject anonymous, wrong role, forged input and stale authority", ctx do
    admin = bootstrap_admin(ctx.admin)
    assert {:ok, operator} = Accounts.provision(admin, ctx.invited, [:support_operator])
    assert {:ok, operator} = authenticate(operator.id)
    attrs = %{slug: ctx.slug, display_name: "Synthetic", audience: :public}

    for actor <- [
          nil,
          operator,
          %{admin | generation: admin.generation + 1},
          struct(ActionScope.Processing, action: :create, resource: Assistant, target: ctx.slug)
        ] do
      assert {:error, _} = invoke(Assistant, :create, attrs, actor)
    end

    assert {:error, _} = invoke(Assistant, :create, Map.put(attrs, :status, :active), admin)

    assert {:error, _} =
             Repo.transact(fn ->
               Ash.create(
                 Assistant,
                 %{
                   slug: ctx.slug,
                   display_name: "Forged",
                   audience: :public,
                   disabled_at: DateTime.utc_now()
                 },
                 action: :create_row,
                 actor: %Storage{ref: make_ref()}
               )
             end)

    assert {:ok, _} = Accounts.set_roles(admin, admin.id, [])
    assert {:error, _} = invoke(Assistant, :create, attrs, admin)
    assert resolve(admin.id).roles == []
  end

  test "assistant activation, disable and retirement fence prior epochs", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    assert assistant.status == :disabled

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "assistants_lifecycle"}
            }} =
             SQL.query(
               Repo,
               "UPDATE assistants SET status = 'active', disabled_at = NULL WHERE id = $1",
               [Ecto.UUID.dump!(assistant.id)]
             )

    assert {:error, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)
    revision = draft(admin, assistant)
    assert {:error, _} = publish(admin, revision, nil)
    allow_fixture(assistant)
    assert {:ok, _} = publish(admin, revision, nil)
    assert {:ok, active} = invoke(Assistant, :activate, %{id: assistant.id}, admin)
    assert active.status == :active
    assert {:error, _} = invoke(Assistant, :retire, %{id: assistant.id}, admin)
    assert {:ok, disabled} = invoke(Assistant, :disable, %{id: assistant.id}, admin)
    assert disabled.security_epoch > active.security_epoch
    assert {:ok, retired} = invoke(Assistant, :retire, %{id: assistant.id}, admin)
    assert retired.security_epoch > disabled.security_epoch
    assert {:error, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)

    assert {:error, _} =
             invoke(
               AssistantRevision,
               :create_draft,
               %{
                 assistant_id: assistant.id,
                 workflow_version: "test-v1",
                 template_version: "test-v1",
                 locale: :af,
                 response_policy: :fixed_reply
               },
               admin
             )
  end

  test "publication requires an explicit expected pointer, including for a first publish", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    allow_fixture(assistant)
    revision = draft(admin, assistant)

    assert {:error, error} = invoke(AssistantRevision, :publish, %{id: revision.id}, admin)
    assert Exception.message(error) =~ "missing_expected_revision_pointer"

    assert {:ok, %{status: :draft}} =
             invoke(AssistantRevision, :read_configuration, %{id: revision.id}, admin)

    assert {:ok, _} = publish(admin, revision, nil)
  end

  test "publish serializes the compare and switch on the assistant row", ctx do
    admin = bootstrap_admin(ctx.admin)
    assert {:ok, second_admin} = Accounts.provision(admin, ctx.other, [:admin])
    assert {:ok, second_admin} = authenticate(second_admin.id)
    assistant = create(admin, ctx.slug)
    allow_fixture(assistant)
    first = draft(admin, assistant)
    second = draft(admin, assistant)
    assert second.revision_number == first.revision_number + 1

    assert {:ok, waiter} =
             Repo.transact(fn ->
               assert {:ok, _} = publish(admin, first, nil)
               {:ok, blocked_task(fn -> publish(second_admin, second, nil) end)}
             end)

    assert {:error, stale} = Task.await(waiter, 5_000)
    assert Exception.message(stale) =~ "stale_revision_pointer"
    assert {:ok, after_first} = invoke(Assistant, :read_configuration, %{id: assistant.id}, admin)
    assert after_first.active_revision_id == first.id
    assert after_first.security_epoch > assistant.security_epoch

    assert {:ok, _} = publish(second_admin, second, first.id)

    assert {:ok, after_second} =
             invoke(Assistant, :read_configuration, %{id: assistant.id}, admin)

    assert after_second.active_revision_id == second.id
    assert after_second.security_epoch > after_first.security_epoch

    assert {:error, _} =
             invoke(AssistantRevision, :edit_draft, %{id: first.id, locale: :en}, admin)

    assert {:error, _} = invoke(AssistantRevision, :discard, %{id: second.id}, admin)

    assert %{rows: [["published", 1], ["superseded", 1]]} =
             SQL.query!(
               Repo,
               "SELECT status, count(*) FROM assistant_revisions WHERE assistant_id = $1 GROUP BY status ORDER BY status",
               [Ecto.UUID.dump!(assistant.id)]
             )
  end

  test "discard and the composite pointer and published slot are enforced", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    allow_fixture(assistant)
    first = draft(admin, assistant)
    assert {:ok, _} = publish(admin, first, nil)
    second = draft(admin, assistant)

    assert {:ok, %{locale: :en}} =
             invoke(AssistantRevision, :edit_draft, %{id: second.id, locale: :en}, admin)

    assert {:error, _} =
             invoke(AssistantRevision, :edit_draft, %{id: first.id, locale: :en}, admin)

    assert {:ok, %{status: :discarded}} =
             invoke(AssistantRevision, :discard, %{id: second.id}, admin)

    assert {:error, _} = publish(admin, second, first.id)

    assert {:error, _} =
             invoke(AssistantRevision, :edit_draft, %{id: second.id, locale: :en}, admin)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             SQL.query(
               Repo,
               """
               UPDATE assistant_revisions SET status = 'published', published_at = now(), published_by_id = $1,
                 config_hash = repeat('a', 64) WHERE id = $2
               """,
               Enum.map([admin.id, second.id], &Ecto.UUID.dump!/1)
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.transact(fn ->
               other = create(admin, ctx.slug <> "-other")

               SQL.query(
                 Repo,
                 "UPDATE assistants SET active_revision_id = $1 WHERE id = $2",
                 Enum.map([first.id, other.id], &Ecto.UUID.dump!/1)
               )
             end)
  end

  test "binding qualification, scoped safe reads, fencing and terminal retirement", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    fixture = allow_fixture(assistant)
    revision = draft(admin, assistant)
    assert {:ok, _} = publish(admin, revision, nil)

    attrs =
      Map.take(fixture, [
        :assistant_id,
        :installation_ref,
        :external_account_id,
        :external_inbox_id
      ])

    assert {:ok, binding} = invoke(InboxBinding, :create_draft, attrs, admin)
    args = %{id: binding.id}
    assert {:error, _} = invoke(InboxBinding, :enable, args, admin)
    assert {:ok, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)
    assert {:ok, enabled} = invoke(InboxBinding, :enable, args, admin)

    scope =
      struct(ActionScope.Ingress,
        action: :read_configuration,
        resource: InboxBinding,
        target: binding.id,
        inbox: {fixture.installation_ref, fixture.external_account_id, fixture.external_inbox_id}
      )

    assert {:ok, safe} = invoke(InboxBinding, :read_configuration, args, scope)
    refute Map.has_key?(safe, :credential_ref)

    assert {:error, _} =
             invoke(InboxBinding, :read_configuration, args, %{scope | inbox: {"other", 1, 1}})

    assert {:error, _} =
             invoke(InboxBinding, :read_configuration, %{id: Ash.UUIDv7.generate()}, scope)

    pending = draft(admin, assistant)

    revision_scope = fn id ->
      struct(ActionScope.Processing,
        action: :read_configuration,
        resource: AssistantRevision,
        target: id,
        inbox: scope.inbox
      )
    end

    assert {:ok, %{status: :published}} =
             invoke(
               AssistantRevision,
               :read_configuration,
               %{id: revision.id},
               revision_scope.(revision.id)
             )

    assert {:error, _} =
             invoke(
               AssistantRevision,
               :read_configuration,
               %{id: pending.id},
               revision_scope.(pending.id)
             )

    assert {:ok, _} = publish(admin, pending, revision.id)

    assert {:error, _} =
             invoke(
               AssistantRevision,
               :read_configuration,
               %{id: revision.id},
               revision_scope.(revision.id)
             )

    assert {:error, _} =
             invoke(InboxBinding, :rebind, Map.put(args, :assistant_id, assistant.id), admin)

    assert {:ok, disabled} = invoke(InboxBinding, :disable, args, admin)
    assert disabled.security_epoch > enabled.security_epoch
    assert {:ok, reenabled} = invoke(InboxBinding, :enable, args, admin)
    assert reenabled.security_epoch > disabled.security_epoch
    assert {:ok, disabled} = invoke(InboxBinding, :disable, args, admin)

    replacement = create(admin, ctx.slug <> "-other")

    assert {:error, _} =
             invoke(InboxBinding, :rebind, Map.put(args, :assistant_id, replacement.id), admin)

    allow_fixture(
      replacement,
      Map.take(fixture, [:installation_ref, :external_account_id, :external_inbox_id])
    )

    assert {:ok, _} = publish(admin, draft(admin, replacement), nil)
    assert {:ok, _} = invoke(Assistant, :activate, %{id: replacement.id}, admin)

    assert {:ok, rebound} =
             invoke(InboxBinding, :rebind, Map.put(args, :assistant_id, replacement.id), admin)

    assert rebound.assistant_id == replacement.id

    assert Map.take(rebound, Map.keys(attrs) -- [:assistant_id]) ==
             Map.take(binding, Map.keys(attrs) -- [:assistant_id])

    assert rebound.security_epoch > disabled.security_epoch

    assert {:ok, changed} =
             invoke(InboxBinding, :change_mode, Map.put(args, :operating_mode, :assisted), admin)

    assert changed.security_epoch > rebound.security_epoch
    assert {:ok, %{status: :retired}} = invoke(InboxBinding, :retire, args, admin)
    assert {:error, _} = invoke(InboxBinding, :enable, args, admin)

    assert {:error, _} =
             invoke(InboxBinding, :change_mode, Map.put(args, :operating_mode, :shadow), admin)
  end

  test "binding mutations lock the assistant first and retirement needs disabled bindings", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    fixture = allow_fixture(assistant)
    assert {:ok, _} = publish(admin, draft(admin, assistant), nil)
    assert {:ok, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)

    attrs =
      Map.take(fixture, [
        :assistant_id,
        :installation_ref,
        :external_account_id,
        :external_inbox_id
      ])

    assert {:ok, binding} = invoke(InboxBinding, :create_draft, attrs, admin)
    args = %{id: binding.id}

    # While the enable waits for the assistant it must not hold the binding.
    assert {:ok, waiter} =
             Repo.transact(fn ->
               lock_row("assistants", assistant.id)
               task = blocked_task(fn -> invoke(InboxBinding, :enable, args, admin) end)
               lock_row("inbox_bindings", binding.id, "NOWAIT")
               {:ok, task}
             end)

    assert {:ok, %{status: :enabled}} = Task.await(waiter, 5_000)
    assert {:ok, _} = invoke(Assistant, :disable, %{id: assistant.id}, admin)
    assert {:error, error} = invoke(Assistant, :retire, %{id: assistant.id}, admin)
    assert Exception.message(error) =~ "enabled_binding"
    assert {:ok, _} = invoke(InboxBinding, :disable, args, admin)
    assert {:ok, %{status: :retired}} = invoke(Assistant, :retire, %{id: assistant.id}, admin)
  end

  test "global enable requires fresh fixture eligibility and disable increments the epoch", ctx do
    admin = bootstrap_admin(ctx.admin)

    assert {:ok, %{status: :disabled}} =
             invoke(AutomationControl, :read_configuration, %{}, admin)

    assert {:error, _} =
             invoke(
               AutomationControl,
               :enable_automation,
               %{binding_id: Ash.UUIDv7.generate()},
               admin
             )

    assistant = create(admin, ctx.slug)
    fixture = allow_fixture(assistant)
    assert {:ok, _} = publish(admin, draft(admin, assistant), nil)
    assert {:ok, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)

    attrs =
      Map.take(fixture, [
        :assistant_id,
        :installation_ref,
        :external_account_id,
        :external_inbox_id
      ])

    assert {:ok, binding} = invoke(InboxBinding, :create_draft, attrs, admin)
    assert {:ok, _} = invoke(InboxBinding, :enable, %{id: binding.id}, admin)

    assert {:ok, _} =
             invoke(
               InboxBinding,
               :change_mode,
               %{id: binding.id, operating_mode: :automatic},
               admin
             )

    # Roll back after exercising the singleton, including its audit history.
    assert {:error, :restore_fixture} =
             Repo.transact(fn ->
               assert {:ok, enabled} =
                        invoke(
                          AutomationControl,
                          :enable_automation,
                          %{binding_id: binding.id},
                          admin
                        )

               assert enabled.status == :enabled
               assert {:ok, disabled} = invoke(AutomationControl, :disable_automation, %{}, admin)
               assert disabled.security_epoch > enabled.security_epoch
               {:error, :restore_fixture}
             end)

    Application.delete_env(:voelgoed_ai, :support_fixture)

    assert {:error, _} =
             invoke(
               InboxBinding,
               :change_mode,
               %{id: binding.id, operating_mode: :automatic},
               admin
             )
  end

  test "a binding action rejects a rebind committed while it waits for the old assistant", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    fixture = allow_fixture(assistant)
    replacement = create(admin, ctx.slug <> "-other")

    attrs =
      Map.take(fixture, [
        :assistant_id,
        :installation_ref,
        :external_account_id,
        :external_inbox_id
      ])

    assert {:ok, binding} = invoke(InboxBinding, :create_draft, attrs, admin)

    # Keep the candidate disabled so the mode change would otherwise succeed.
    # The first connection models the rebind's atomic storage changes while
    # the second connection waits on the assistant selected by its first read.
    assert {:ok, waiter} =
             Repo.transact(fn ->
               lock_row("assistants", assistant.id)
               lock_row("assistants", replacement.id)

               waiter =
                 blocked_task(fn ->
                   invoke(
                     InboxBinding,
                     :change_mode,
                     %{id: binding.id, operating_mode: :assisted},
                     admin
                   )
                 end)

               lock_row("inbox_bindings", binding.id, "NOWAIT")

               SQL.query!(
                 Repo,
                 """
                 UPDATE inbox_bindings
                 SET assistant_id = $1, status = 'disabled', security_epoch = security_epoch + 1
                 WHERE id = $2
                 """,
                 [Ecto.UUID.dump!(replacement.id), Ecto.UUID.dump!(binding.id)]
               )

               {:ok, waiter}
             end)

    assert {:error, error} = Task.await(waiter, 5_000)
    assert Exception.message(error) =~ "concurrent_configuration_change"

    assert {:ok, %{assistant_id: replacement_id, operating_mode: :shadow}} =
             invoke(InboxBinding, :read_configuration, %{id: binding.id}, admin)

    assert replacement_id == replacement.id
  end

  test "operational audit is distinct and an audit error rolls back publication", ctx do
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    allow_fixture(assistant)
    revision = draft(admin, assistant)
    Process.put({VoelgoedAi.Support.Configuration, :reject_audit}, :publish)
    assert {:error, _} = publish(admin, revision, nil)
    Process.delete({VoelgoedAi.Support.Configuration, :reject_audit})

    assert {:ok, %{active_revision_id: nil}} =
             invoke(Assistant, :read_configuration, %{id: assistant.id}, admin)

    assert {:ok, _} = publish(admin, revision, nil)

    assert {:ok, events} =
             invoke(
               AuditEvent,
               :operational_history,
               %{target_kind: :assistant_revision, id: revision.id},
               admin
             )

    assert Enum.map(events, & &1.event) == [:create_draft, :publish]
    assert {:ok, staff_history} = Governance.staff_security_history(admin, admin.id)
    assert Enum.all?(staff_history, &(&1.target_kind == :staff_user))

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "audit_events_exact_target"}
            }} =
             SQL.query(
               Repo,
               "UPDATE audit_events SET target_id = $1 WHERE revision_target_id = $2",
               Enum.map([admin.id, revision.id], &Ecto.UUID.dump!/1)
             )

    assert {:error, _} =
             Ash.create(
               AuditEvent,
               %{assistant_target_id: assistant.id, target_kind: :assistant, event: :create},
               action: :append,
               actor: %Scope{action: :append, target: {assistant.id, :create}}
             )

    assert {:error, _} =
             Ash.create(AuditEvent, %{target_id: admin.id},
               action: :append_operational,
               actor: %Scope{action: :append, target: {admin.id, :create}}
             )
  end

  defp lock_row(table, id, mode \\ "") do
    SQL.query!(Repo, "SELECT 1 FROM #{table} WHERE id = $1 FOR UPDATE #{mode}", [
      Ecto.UUID.dump!(id)
    ])
  end

  defp publish(admin, revision, expected) do
    invoke(
      AssistantRevision,
      :publish,
      %{id: revision.id, expected_active_revision_id: expected},
      admin
    )
  end
end
