defmodule VoelgoedAiWeb.StaffAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import VoelgoedAi.StaffEntraFixture, only: [request: 2, request: 3, request: 4]
  alias VoelgoedAi.{Accounts, Governance, StaffEntraFixture, StaffFixtures}
  alias VoelgoedAi.Accounts.StaffUser
  alias VoelgoedAiWeb.StaffSession

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup do
    StaffFixtures.setup()
  end

  test "unconfigured staff routes fail closed while health remains available" do
    Application.put_env(:voelgoed_ai, :entra, enabled: true)
    assert request(:get, "/health").status == 200

    for path <- ["/staff/entra", "/staff/entra/callback", "/staff/session"] do
      denied = request(:get, path)
      assert denied.status == 401
      assert get_resp_header(denied, "cache-control") == ["no-store"]
    end
  end

  test "a direct staff request cannot set its actor in params", %{admin: admin} do
    session = StaffFixtures.bootstrap_admin(admin)
    unauthorized = request(:get, "/staff/session?actor[kind]=admin&staff_id=#{session.id}")
    assert unauthorized.status == 401
    assert {:ok, :authorized} = Accounts.require_role(session, :admin)

    query =
      StaffUser
      |> Ash.Query.for_read(
        :sign_in_with_entra,
        %{user_info: %{}, oauth_tokens: %{}},
        actor: session,
        context: %{private: %{ash_authentication?: true}}
      )

    assert {:error, _} = Ash.read(query)

    assert Enum.map(Ash.Resource.Info.actions(StaffUser), & &1.type) |> Enum.uniq() |> Enum.sort() ==
             [:create, :read, :update]
  end

  test "confidential Entra callback commits a renewed local session with explicit roles",
       context do
    admin = StaffFixtures.bootstrap_admin(context.admin)
    assert {:ok, %{id: invited}} = Accounts.provision(admin, context.invited, [:support_operator])
    flow = StaffEntraFixture.start_sign_in(context, context.invited.subject)
    callback = StaffEntraFixture.callback(flow)
    assert callback.status == 204
    assert :atomics.get(flow.exchange_count, 1) == 1

    assert [cookie] = get_resp_header(callback, "set-cookie")
    assert cookie =~ "secure"
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    assert cookie =~ "path=/staff"
    refute cookie =~ invited
    refute cookie =~ context.invited.subject

    assert callback.resp_cookies["_vgas_staff"].value !=
             flow.redirect.resp_cookies["_vgas_staff"].value

    assert map_size(get_session(callback)) == 1

    assert {:ok, :authorized} =
             Accounts.require_role(StaffSession.actor(callback), :support_operator)

    assert {:error, :denied} = Accounts.require_role(StaffSession.actor(callback), :admin)

    assert {:error, :denied} =
             Accounts.require_role(StaffSession.actor(callback), :knowledge_reviewer)

    assert %{status: 200, resp_body: body} = request(:get, "/staff/session", callback)

    assert %{"staff" => %{"id" => ^invited, "roles" => ["support_operator"]} = staff} =
             Jason.decode!(body)

    assert Map.keys(staff) |> Enum.sort() == ~w(id last_authenticated_at roles status)

    assert {:ok, [%{event: :provisioned}, %{event: :activated, actor_staff_id: ^invited}]} =
             Governance.staff_security_history(admin, invited)
  end

  test "wrong signed claims, subject, audience, signature, nonce and PKCE all deny", context do
    admin = StaffFixtures.bootstrap_admin(context.admin)
    assert {:ok, %{id: id}} = Accounts.provision(admin, context.invited, [])
    other_key = JOSE.JWK.generate_key({:rsa, 2048})
    now = System.system_time(:second)

    for opts <- [
          [claims: %{"tid" => StaffFixtures.client()}],
          [claims: %{"iss" => "https://alternate.example.test"}],
          [claims: %{"sub" => String.upcase(context.invited.subject)}],
          [claims: %{"aud" => StaffFixtures.tenant()}],
          [claims: %{"nonce" => "different-nonce"}],
          [claims: %{"nbf" => now + 600}],
          [claims: %{"iat" => now + 600}],
          [claims: %{"exp" => now - 600}],
          [signing_key: other_key],
          [unavailable: :pkce]
        ] do
      assert_denied(StaffEntraFixture.sign_in(context, context.invited.subject, opts))
    end

    assert_denied(StaffEntraFixture.sign_in(context, context.other.subject))
    assert {:ok, [%{event: :provisioned}]} = Governance.staff_security_history(admin, id)
  end

  test "state, missing flow and replay get a generic denial", context do
    assert {:ok, _} = Accounts.bootstrap(context.admin, [:admin])
    flow = StaffEntraFixture.start_sign_in(context, context.admin.subject)

    assert_denied(
      StaffEntraFixture.callback(flow, %{flow.params | "state" => "invalid"}, flow.redirect)
    )

    assert_denied(StaffEntraFixture.callback(flow, flow.params, nil))
    assert :atomics.get(flow.exchange_count, 1) == 0
    assert StaffEntraFixture.callback(flow).status == 204
    assert_denied(StaffEntraFixture.callback(flow))
    assert :atomics.get(flow.exchange_count, 1) == 2
  end

  test "both discovery phases reject invalid metadata before redirect or exchange", context do
    for metadata <- [
          Map.put(StaffEntraFixture.metadata(), "issuer", "https://other.example.test"),
          Map.put(
            StaffEntraFixture.metadata(),
            "authorization_endpoint",
            "https://other.example.test/authorize"
          ),
          Map.put(
            StaffEntraFixture.metadata(),
            "token_endpoint",
            "https://other.example.test/token"
          ),
          Map.update!(
            StaffEntraFixture.metadata(),
            "token_endpoint",
            &(&1 <> "?unexpected=true")
          ),
          Map.put(StaffEntraFixture.metadata(), "jwks_uri", "https://other.example.test/keys"),
          Map.put(StaffEntraFixture.metadata(), "token_endpoint_auth_methods_supported", ["none"]),
          Map.delete(StaffEntraFixture.metadata(), "token_endpoint_auth_methods_supported")
        ] do
      StaffEntraFixture.stub_discovery(metadata)
      request = request(:get, "/staff/entra")
      assert_denied(request)
      assert get_resp_header(request, "location") == []

      flow =
        StaffEntraFixture.start_sign_in(context, context.admin.subject,
          callback_metadata: metadata
        )

      assert_denied(StaffEntraFixture.callback(flow))
      assert :atomics.get(flow.exchange_count, 1) == 0
    end

    StaffEntraFixture.stub_discovery(StaffEntraFixture.metadata(), :callback_discovery)
    assert_denied(request(:get, "/staff/entra"))
  end

  test "bad provider responses fail closed and never log the request parameters", context do
    assert {:ok, %{id: id}} = Accounts.bootstrap(context.admin, [:admin])

    for opts <- [
          [unavailable: :callback_discovery],
          [unavailable: :token],
          [unavailable: :keys],
          [tokens: &Map.put(&1, "id_token", String.duplicate("a", 32_769))],
          [token_body: String.duplicate("x", 131_073)],
          [token_body: ~s({"id_token":"x","id_token":"y","access_token":"z"})],
          [jwks: &Map.put(&1, "keys", [])],
          [jwks: &Map.update!(&1, "keys", fn keys -> keys ++ keys end)],
          [jwks: &Map.update!(&1, "keys", fn keys -> List.duplicate(hd(keys), 33) end)],
          [
            jwks:
              &Map.update!(&1, "keys", fn keys ->
                Enum.map(keys, fn key -> Map.put(key, "p", "AQAB") end)
              end)
          ],
          [header: &Map.put(&1, "crit", ["b64"])],
          [payload: &Map.put(&1, "exp", "not-an-integer")]
        ] do
      log =
        capture_log(fn ->
          flow = StaffEntraFixture.start_sign_in(context, context.admin.subject, opts)

          assert_denied(
            StaffEntraFixture.callback(
              flow,
              Map.put(flow.params, "untrusted", "must-not-log"),
              flow.redirect
            )
          )
        end)

      refute log =~ "must-not-log"
      refute log =~ StaffFixtures.fixture_credential()
      refute log =~ context.admin.subject
    end

    assert %{status: :invited, last_authenticated_at: nil} = StaffFixtures.resolve(id)
  end

  test "expired, tampered, disabled and retired credentials fail direct or callback access",
       context do
    admin = StaffFixtures.bootstrap_admin(context.admin)
    assert {:ok, %{id: id}} = Accounts.provision(admin, context.invited, [])
    valid = StaffEntraFixture.sign_in(context, context.invited.subject)
    assert valid.status == 204
    assert {:ok, %{roles: []}} = Accounts.read_self(StaffSession.actor(valid))
    assert {:error, :denied} = Accounts.require_role(StaffSession.actor(valid), :admin)
    expired = %{StaffSession.actor(valid) | expiry: System.system_time(:second) - 1}
    assert {:error, :denied} = Accounts.read_self(expired)
    assert_denied(request(:get, "/staff/session", nil, [{"cookie", "_vgas_staff=tampered"}]))
    assert {:ok, _} = Accounts.disable(admin, id)
    assert_denied(request(:get, "/staff/session", valid))
    assert_denied(StaffEntraFixture.sign_in(context, context.invited.subject))
    assert {:ok, _} = Accounts.retire(admin, id)
    assert_denied(StaffEntraFixture.sign_in(context, context.invited.subject))
  end

  test "sign-out requires CSRF proof and clears the local cookie", context do
    assert {:ok, _} = Accounts.bootstrap(context.admin, [:admin])
    signed_in = StaffEntraFixture.sign_in(context, context.admin.subject)
    assert signed_in.status == 204
    session = request(:get, "/staff/session", signed_in)
    assert session.status == 200
    csrf = Jason.decode!(session.resp_body)["csrf_token"]

    denied = request(:post, "/staff/sign-out", session)
    assert denied.status == 403
    assert get_resp_header(denied, "set-cookie") == []

    signed_out = request(:post, "/staff/sign-out", session, [{"x-csrf-token", csrf}])
    assert signed_out.status == 204
    assert signed_out.resp_cookies["_vgas_staff"].max_age == 0
    assert_denied(request(:get, "/staff/session", signed_out))
  end

  test "a changed registration rejects the old flow and session before exchange", context do
    assert {:ok, _} = Accounts.bootstrap(context.admin, [:admin])
    signed_in = StaffEntraFixture.sign_in(context, context.admin.subject)
    assert signed_in.status == 204
    pending = StaffEntraFixture.start_sign_in(context, context.admin.subject)
    prior = Application.fetch_env!(:voelgoed_ai, :entra)

    Application.put_env(
      :voelgoed_ai,
      :entra,
      Keyword.put(prior, :client_id, StaffFixtures.tenant())
    )

    assert_denied(StaffEntraFixture.callback(pending))
    assert :atomics.get(pending.exchange_count, 1) == 0
    assert_denied(request(:get, "/staff/session", signed_in))
  end

  test "an assertion in a provider fixture fails through the endpoint", context do
    flow =
      StaffEntraFixture.start_sign_in(context, context.admin.subject,
        fail_fixture_assertion: true
      )

    assert_raise ExUnit.AssertionError, ~r/synthetic fixture assertion/, fn ->
      StaffEntraFixture.callback(flow)
    end
  end

  defp assert_denied(conn) do
    assert conn.status == 401
    assert conn.resp_body == "Staff access denied"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_cookies["_vgas_staff"].max_age == 0
  end
end
