defmodule VoelgoedAiWeb.StaffOperationsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.StaffKnowledgeFixture

  @endpoint VoelgoedAiWeb.Endpoint

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, StaffEntraFixture, StaffFixtures}
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Governance.EmbeddingAccounting

  setup do
    StaffFixtures.setup()
  end

  test "operators and admins get different views and editorial-only staff are denied", ctx do
    admin = StaffFixtures.bootstrap_admin(ctx.admin)
    assert {:ok, operator} = Accounts.provision(admin, ctx.invited, [:support_operator])
    assert {:ok, editor} = Accounts.provision(admin, ctx.other, [:knowledge_editor])
    assert {:ok, operator_session} = StaffFixtures.authenticate(operator.id)
    assert {:ok, editor_session} = StaffFixtures.authenticate(editor.id)

    assert StaffEntraFixture.request(:get, "/staff/operations").status == 302
    assert read_page(editor_session, "/staff/operations").status == 302
    assert read_page(operator_session, "/staff/knowledge").status == 302

    for path <- ["/staff/assets/operations.css", "/staff/assets/%6fperations.css"] do
      assert StaffEntraFixture.request(:get, path).status == 403
      assert read_page(editor_session, path).status == 403
      expected = if String.contains?(path, "%"), do: 404, else: 200
      asset = read_page(operator_session, path)
      assert asset.status == expected
      assert get_resp_header(asset, "cache-control") == ["private, no-store"]
    end

    page = read_page(operator_session, "/staff/operations")
    assert page.status == 200
    assert get_resp_header(page, "cache-control") == ["private, no-store"]
    assert page.resp_body =~ "Support queue"
    refute page.resp_body =~ "Disable automation"

    page = read_page(admin, "/staff/operations")
    assert page.status == 200
    assert page.resp_body =~ "Disable automation"
    refute page.resp_body =~ "Support queue"
  end

  test "a connected operator loses operations access when their grant changes", ctx do
    admin = StaffFixtures.bootstrap_admin(ctx.admin)
    assert {:ok, row} = Accounts.provision(admin, ctx.invited, [:support_operator])
    assert {:ok, operator} = StaffFixtures.authenticate(row.id)

    page = read_page(operator, "/staff/operations")
    session = %{"staff" => {operator.id, operator.generation, operator.expiry, operator.binding}}
    page = put_private(page, :live_view_connect_info, %{session: session})
    assert {:ok, view, html} = live(page)
    assert html =~ "Support queue"
    assert render_click(view, "disable", %{}) =~ "This operation is unavailable"

    assert {:ok, _} = Accounts.set_roles(admin, row.id, [:knowledge_editor])

    assert {:error, {:redirect, %{to: "/staff/knowledge/denied"}}} =
             render_click(view, "refresh", %{})
  end

  test "an admin can disable automation while exposure is unavailable" do
    %{admin: admin} = SupportDBCase.setup()

    assert %{rows: [["enabled", false, nil]]} =
             SQL.query!(
               Repo,
               "SELECT status, embedding_inhibited, embedding_inhibit_occurrence FROM automation_controls WHERE singleton"
             )

    SQL.query!(Repo, "UPDATE automation_controls SET embedding_inhibited = true WHERE singleton")

    try do
      page = read_page(admin, "/staff/operations")
      session = %{"staff" => {admin.id, admin.generation, admin.expiry, admin.binding}}
      page = put_private(page, :live_view_connect_info, %{session: session})
      assert {:ok, view, html} = live(page)
      unavailable? = String.contains?(html, "Accounting totals are unavailable")
      assert unavailable?
      assert has_element?(view, "button[phx-click=disable]")

      render_click(view, "disable", %{})

      assert %{rows: [["disabled", true]]} =
               SQL.query!(
                 Repo,
                 "SELECT status, embedding_inhibited FROM automation_controls WHERE singleton"
               )
    after
      SQL.query!(
        Repo,
        "UPDATE automation_controls SET embedding_inhibited = false WHERE singleton"
      )
    end
  end

  test "refresh reports a locked queue projection before the transaction deadline" do
    %{operator: operator} = SupportDBCase.setup()

    assert {:ok, :timeout_preserved} =
             Repo.transact(fn ->
               SQL.query!(Repo, "SET LOCAL statement_timeout = '3s'")

               assert {:ok, %{operator: %{available: true}}} =
                        VoelgoedAi.Support.Operations.snapshot(operator, nil)

               assert %{rows: [["3s"]]} = SQL.query!(Repo, "SHOW statement_timeout")
               {:ok, :timeout_preserved}
             end)

    page = read_page(operator, "/staff/operations")
    session = %{"staff" => {operator.id, operator.generation, operator.expiry, operator.binding}}
    page = put_private(page, :live_view_connect_info, %{session: session})
    assert {:ok, view, _} = live(page)
    assert has_element?(view, "h2", "Support queue")

    with_locked_table("support_alert_episodes", fn ->
      started_at = System.monotonic_time(:millisecond)
      render_click(view, "refresh", %{})
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert has_element?(
               view,
               "[role=status]",
               "The operations page could not load. Try Refresh."
             )

      assert elapsed < 3_000
    end)

    render_click(view, "refresh", %{})
    assert has_element?(view, "h2", "Support queue")
    refute has_element?(view, "[role=status]", "The operations page could not load. Try Refresh.")
  end

  test "a blocked accounting read times out without blocking the same admin from disabling" do
    support = SupportDBCase.setup()
    admin = support.admin

    with_locked_table("usage_reservations", fn ->
      projection = Task.async(fn -> EmbeddingAccounting.staff_exposure(admin) end)

      try do
        assert accounting_waiting?()

        assert {:ok, _} =
                 SQL.query(
                   Repo,
                   "SELECT id FROM automation_controls WHERE singleton FOR UPDATE NOWAIT"
                 )

        SupportDBCase.disable_automation(support)
        assert {:error, :unavailable} = Task.await(projection, 3_000)

        assert %{rows: [["disabled"]]} =
                 SQL.query!(Repo, "SELECT status FROM automation_controls")
      after
        Task.shutdown(projection, :brutal_kill)
      end
    end)
  end

  test "a queue timeout leaves Disable automation available for dual-role staff" do
    %{admin: admin, operator: operator} = SupportDBCase.setup()
    assert {:ok, _} = Accounts.set_roles(admin, operator.id, [:admin, :support_operator])
    assert {:ok, staff} = StaffFixtures.authenticate(operator.id)

    on_exit(fn ->
      SQL.query!(
        Repo,
        """
        DELETE FROM audit_events
        WHERE control_target_id IS NOT NULL AND actor_staff_id = $1 AND event = 'disable_automation'
        """,
        [Ecto.UUID.dump!(staff.id)]
      )
    end)

    page = read_page(staff, "/staff/operations")
    session = %{"staff" => {staff.id, staff.generation, staff.expiry, staff.binding}}
    page = put_private(page, :live_view_connect_info, %{session: session})
    assert {:ok, view, _} = live(page)
    assert has_element?(view, "h2", "Support queue")
    assert has_element?(view, "button[phx-click=disable]")

    with_locked_table("support_alert_episodes", fn ->
      render_click(view, "refresh", %{})
      assert has_element?(view, "button[phx-click=disable]")
      refute has_element?(view, "h2", "Support queue")
      render_click(view, "disable", %{})
      assert %{rows: [["disabled"]]} = SQL.query!(Repo, "SELECT status FROM automation_controls")
    end)

    render_click(view, "refresh", %{})
    assert has_element?(view, "h2", "Support queue")
  end

  defp accounting_waiting? do
    Enum.any?(1..75, fn _ ->
      %{rows: [[waiting]]} =
        SQL.query!(Repo, """
        SELECT EXISTS (
          SELECT 1 FROM pg_locks
          WHERE relation = 'usage_reservations'::regclass AND NOT granted
        )
        """)

      if not waiting, do: Process.sleep(10)
      waiting
    end)
  end

  defp with_locked_table(table, callback) do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transact(
          fn ->
            SQL.query!(Repo, "LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
            send(parent, :projection_locked)

            receive do
              :release_projection -> {:ok, :released}
            after
              22_000 -> {:error, :lock_test_timed_out}
            end
          end,
          timeout: 25_000
        )
      end)

    try do
      assert_receive :projection_locked, 3_000
      callback.()
    after
      send(holder.pid, :release_projection)
      assert {:ok, :released} = Task.await(holder)
    end
  end
end
