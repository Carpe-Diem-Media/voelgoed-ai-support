defmodule VoelgoedAiWeb.StaffOperationsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Plug.Conn
  import VoelgoedAi.StaffKnowledgeFixture

  @endpoint VoelgoedAiWeb.Endpoint

  alias VoelgoedAi.{Accounts, StaffEntraFixture, StaffFixtures}

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
end
