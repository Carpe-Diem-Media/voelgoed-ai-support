defmodule VoelgoedAi.Accounts.StaffLifecycleTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.StaffFixtures
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, Governance, Repo}
  alias VoelgoedAi.Accounts.StaffUser
  alias VoelgoedAi.Governance.AuditEvent

  setup do
    VoelgoedAi.StaffFixtures.setup()
  end

  test "bootstrap invites only the first administrator and denies direct writes", %{
    admin: identity,
    invited: other
  } do
    assert {:error, :invalid_roles} = Accounts.bootstrap(identity, [:knowledge_reviewer])

    assert {:error, :invalid_allowlist_identity} =
             Accounts.bootstrap(%{identity | tenant_id: client()}, [:admin])

    assert {:ok, %{id: id, status: :invited, roles: [:admin]}} =
             Accounts.bootstrap(identity, [:admin])

    assert {:error, :bootstrap_closed} = Accounts.bootstrap(other, [:admin])
    assert {:error, :denied} = Accounts.read_self(nil)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(
               StaffUser,
               %{
                 identity_issuer: other.issuer,
                 identity_subject: other.subject,
                 tenant_id: other.tenant_id,
                 identity_client_id: other.client_id,
                 roles: [:admin]
               },
               action: :provision
             )

    assert {:error, :denied} = VoelgoedAi.Accounts.StaffLifecycle.authenticate(resolve(id), nil)
    assert {:ok, session} = authenticate(id)

    assert {:ok, [%{event: :provisioned}, %{event: :activated}]} =
             Governance.staff_security_history(session, id)

    assert {:error, %Ash.Error.Forbidden{}} =
             AuditEvent
             |> Ash.Query.for_read(:staff_security_history, %{target_id: id}, actor: session)
             |> Ash.read()

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(
               AuditEvent,
               %{
                 actor_kind: :staff,
                 actor_staff_id: id,
                 target_id: id,
                 event: :disabled,
                 reason_code: :local_admin,
                 after_state: %{status: :disabled, roles: [:admin], session_generation: 1},
                 correlation_id: Ash.UUIDv7.generate()
               },
               action: :append,
               actor: session
             )

    assert Ash.Resource.Info.actions(AuditEvent) |> Enum.map(& &1.name) |> Enum.sort() ==
             [
               :append,
               :append_knowledge,
               :append_operational,
               :append_publication_failure,
               :append_support_operator,
               :append_system,
               :knowledge_history,
               :knowledge_rows,
               :operational_history,
               :operational_rows,
               :staff_security_history,
               :system_history,
               :system_rows
             ]
  end

  test "roles are additive and a restored role does not revive a cookie", %{
    admin: admin,
    invited: invited
  } do
    session = bootstrap_admin(admin)
    assert {:error, :denied} = Accounts.require_role(session, :knowledge_reviewer)
    assert {:error, :invalid_roles} = Accounts.provision(session, invited, [:owner])
    assert {:ok, %{id: id}} = Accounts.provision(session, invited, [:support_operator])
    assert {:ok, operator} = authenticate(id)
    assert {:ok, :authorized} = Accounts.require_role(operator, :support_operator)

    assert {:ok, %{id: ^id, roles: [:support_operator]} = projection} =
             Accounts.read_staff(session, id)

    assert Map.keys(projection) |> Enum.sort() == [:id, :last_authenticated_at, :roles, :status]
    assert {:error, :denied} = Accounts.read_staff(operator, session.id)
    assert {:error, :denied} = Accounts.disable(operator, session.id)

    assert {:ok, %{roles: [:support_operator]}} =
             Accounts.set_roles(session, id, [:support_operator])

    assert {:ok, _} = Accounts.set_roles(session, id, [])
    assert {:ok, _} = Accounts.set_roles(session, id, [:support_operator])
    assert {:error, :denied} = Accounts.read_self(operator)
    assert {:ok, restored} = authenticate(id)
    assert {:ok, %{id: ^id, status: :active}} = Accounts.read_self(restored)
    assert {:ok, history} = Governance.staff_security_history(session, id)

    assert Enum.map(history, & &1.event) == [
             :provisioned,
             :activated,
             :roles_changed,
             :roles_changed,
             :signed_in
           ]

    assert List.last(history).after_state.session_generation == 2
  end

  test "disable revokes access, reactivation needs the same allowlist and retirement keeps history",
       %{admin: admin, invited: invited, other: other} do
    session = bootstrap_admin(admin)
    assert {:ok, %{id: id}} = Accounts.provision(session, invited, [])
    assert {:error, :invalid_transition} = Accounts.retire(session, id)
    assert {:ok, old_session} = authenticate(id)
    assert {:ok, %{status: :disabled}} = Accounts.disable(session, id)
    assert {:ok, %{status: :disabled}} = Accounts.disable(session, id)
    assert {:error, :denied} = authenticate(id)
    assert {:error, :denied} = Accounts.read_self(old_session)
    assert {:error, :invalid_transition} = Accounts.reactivate(session, id, other, [])
    assert {:ok, %{status: :active}} = Accounts.reactivate(session, id, invited, [])
    assert {:error, :denied} = Accounts.read_self(old_session)
    assert {:ok, fresh_session} = authenticate(id)
    assert {:ok, %{status: :active, roles: []}} = Accounts.read_self(fresh_session)
    assert {:ok, _} = Accounts.disable(session, id)
    assert {:ok, %{status: :retired}} = Accounts.retire(session, id)
    assert {:error, :identity_conflict} = Accounts.provision(session, invited, [:admin])
    assert {:error, :denied} = authenticate(id)
    assert {:error, :invalid_transition} = Accounts.reactivate(session, id, invited, [])
    assert {:ok, history} = Governance.staff_security_history(session, id)

    assert Enum.map(history, & &1.event) ==
             [:provisioned, :activated, :disabled, :reactivated, :signed_in, :disabled, :retired]
  end

  test "concurrent invitations and callbacks serialize on PostgreSQL", %{
    admin: admin,
    invited: invited
  } do
    session = bootstrap_admin(admin)
    results = overlap(fn -> Accounts.provision(session, invited, [:support_operator]) end)
    assert [{:error, :identity_conflict}, {:ok, %{id: id}}] = Enum.sort(results)
    assert Enum.all?(overlap(fn -> authenticate(id) end), &match?({:ok, _}, &1))
    assert {:ok, events} = Governance.staff_security_history(session, id)
    assert Enum.map(events, & &1.event) == [:provisioned, :activated, :signed_in]
  end

  test "concurrent first-admin bootstraps commit one invitation", %{admin: admin, other: other} do
    assert [{:ok, %{id: id}}, {:error, :bootstrap_closed}] =
             overlap(fn -> Accounts.bootstrap(admin, [:admin]) end, fn ->
               Accounts.bootstrap(other, [:admin])
             end)

    assert %{roles: [:admin], status: :invited} = resolve(id)
    assert {:ok, session} = authenticate(id)

    assert {:ok, [%{event: :provisioned}, %{event: :activated}]} =
             Governance.staff_security_history(session, id)
  end

  test "an audit validation failure leaves provisioning uncommitted", %{
    admin: admin,
    invited: invited
  } do
    session = bootstrap_admin(admin)

    result = reject_audit(:provisioned, fn -> Accounts.provision(session, invited, []) end)

    assert Repo.checkout(fn ->
             SQL.query!(
               Repo,
               """
               SELECT s.status, a.event
               FROM staff_users s
               LEFT JOIN audit_events a ON a.target_id = s.id
               WHERE s.identity_issuer = $1 AND s.identity_subject = $2
               """,
               [invited.issuer, invited.subject],
               log: false
             ).rows
           end) == []

    assert {:error, :staff_write_failed} = result
    assert {:ok, _} = Accounts.provision(session, invited, [])
  end

  for {action, event, starting_status} <- [
        {:set_roles, :roles_changed, :active},
        {:disable, :disabled, :active},
        {:reactivate, :reactivated, :disabled},
        {:retire, :retired, :disabled},
        {:authenticate, :activated, :invited},
        {:authenticate, :signed_in, :active}
      ] do
    test "audit validation failure rolls back #{action} (#{event})", %{
      admin: admin,
      invited: invited
    } do
      session = bootstrap_admin(admin)
      assert {:ok, %{id: id}} = Accounts.provision(session, invited, [:support_operator])

      case unquote(starting_status) do
        :invited -> :ok
        :active -> assert {:ok, _} = authenticate(id)
        :disabled -> assert {:ok, _} = Accounts.disable(session, id)
      end

      operation =
        case unquote(action) do
          :set_roles -> fn -> Accounts.set_roles(session, id, [:knowledge_editor]) end
          :disable -> fn -> Accounts.disable(session, id) end
          :reactivate -> fn -> Accounts.reactivate(session, id, invited, [:knowledge_editor]) end
          :retire -> fn -> Accounts.retire(session, id) end
          :authenticate -> fn -> authenticate(id) end
        end

      before = resolve(id)
      assert {:ok, history} = Governance.staff_security_history(session, id)
      result = reject_audit(unquote(event), operation)

      Repo.checkout(fn ->
        after_failure = resolve(id)
        fields = [:status, :roles, :session_generation, :last_authenticated_at]
        assert Map.take(after_failure, fields) == Map.take(before, fields)
        assert {:ok, ^history} = Governance.staff_security_history(session, id)
      end)

      assert {:error, :staff_write_failed} = result
      assert {:ok, _} = operation.()
    end
  end

  test "a failing audit insert rolls back provisioning, activation and management", %{
    admin: admin,
    invited: invited,
    other: other
  } do
    session = bootstrap_admin(admin)
    assert {:ok, %{id: id}} = Accounts.provision(session, invited, [])

    assert {:error, :staff_write_failed} =
             fail_audit(:provisioned, fn -> Accounts.provision(session, other, []) end)

    assert {:ok, _} = Accounts.provision(session, other, [])

    assert {:error, :staff_write_failed} =
             fail_audit(:activated, fn -> authenticate(id) end)

    assert %{status: :invited, session_generation: 0} = resolve(id)
    assert {:ok, staff_session} = authenticate(id)

    assert {:error, :staff_write_failed} =
             fail_audit(:disabled, fn -> Accounts.disable(session, id) end)

    assert {:ok, %{status: :active}} = Accounts.read_self(staff_session)

    assert {:ok, [%{event: :provisioned}, %{event: :activated}]} =
             Governance.staff_security_history(session, id)
  end

  test "disable waiting behind login invalidates the committed session", %{
    admin: admin,
    invited: invited
  } do
    session = bootstrap_admin(admin)
    assert {:ok, %{id: id}} = Accounts.provision(session, invited, [])

    assert {:ok, {staff_session, waiter}} =
             Repo.transact(fn ->
               assert {:ok, staff_session} = authenticate(id)
               waiter = blocked_task(fn -> Accounts.disable(session, id) end)
               {:ok, {staff_session, waiter}}
             end)

    assert {:ok, %{status: :disabled}} = Task.await(waiter, 5_000)
    assert {:error, :denied} = Accounts.read_self(staff_session)
  end

  test "committed administrator revocation defeats a waiting mutation", %{
    admin: admin,
    invited: invited
  } do
    session = bootstrap_admin(admin)
    assert {:ok, %{id: id}} = Accounts.provision(session, invited, [])

    assert {:ok, waiter} =
             Repo.transact(fn ->
               assert {:ok, %{roles: []}} = Accounts.set_roles(session, session.id, [])
               {:ok, blocked_task(fn -> Accounts.disable(session, id) end)}
             end)

    assert {:error, :denied} = Task.await(waiter, 5_000)
    assert %{status: :invited, session_generation: 0} = resolve(id)
  end

  defp blocked_task(operation) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})
          operation.()
        end)
      end)

    pid = task.pid
    assert_receive {:backend, ^pid, backend}, 5_000
    assert_waiting(backend, System.monotonic_time(:millisecond) + 4_000)
    task
  end

  defp assert_waiting(backend, deadline) do
    case SQL.query!(Repo, "SELECT pg_backend_pid() = ANY(pg_blocking_pids($1))", [backend]) do
      %{rows: [[true]]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "PostgreSQL lock wait was not observed"

        Process.sleep(10)
        assert_waiting(backend, deadline)
    end
  end

  test "the operator invitation input requires an explicit grant and contains only allowlist fields",
       %{admin: identity} do
    input = Map.put(identity, :roles, ["ADMIN"])

    assert {:error, :invalid_bootstrap_input} =
             VoelgoedAi.Accounts.StaffBootstrap.from_json(
               Jason.encode!(Map.put(input, :unexpected, true))
             )

    assert :ok = VoelgoedAi.Accounts.StaffBootstrap.from_json(Jason.encode!(input))

    assert {:error, :bootstrap_closed} =
             VoelgoedAi.Accounts.StaffBootstrap.from_json(Jason.encode!(input))
  end

  defp overlap(operation), do: overlap(operation, operation)

  defp overlap(first, second) do
    # Hold the first transaction open after its write and observe the second
    # connection waiting on it before allowing the first to commit.
    assert {:ok, {first_result, waiter}} =
             Repo.transact(fn ->
               first_result = first.()
               assert match?({:ok, _}, first_result)
               {:ok, {first_result, blocked_task(second)}}
             end)

    [first_result, Task.await(waiter, 5_000)]
  end

  defp fail_audit(event, operation) when event in [:provisioned, :activated, :disabled] do
    # The test transaction owns the temporary constraint and always rolls it
    # back. No committed fixture or schema change survives the trial.
    Repo.transact(fn ->
      SQL.query!(Repo, """
      ALTER TABLE audit_events ADD CONSTRAINT test_reject_event CHECK (event != '#{event}') NOT VALID
      """)

      case operation.() do
        {:error, _} = error -> error
        {:ok, _} -> {:error, :unexpected_write}
      end
    end)
  end
end
