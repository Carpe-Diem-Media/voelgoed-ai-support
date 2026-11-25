defmodule VoelgoedAi.EntraFeasibilityTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias VoelgoedAi.Feasibility.{
    EntraAudit,
    EntraOIDCResponse,
    EntraProvider,
    EntraSession,
    EntraStaff,
    EntraStore
  }

  alias VoelgoedAi.Repo

  setup_all do
    {:ok, key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup do
    Req.Test.set_req_test_to_private()
    schema = EntraStore.create_schema!()
    on_exit(fn -> EntraStore.drop_schema!(schema) end)
    {:ok, schema: schema, cookie_key: :crypto.strong_rand_bytes(64)}
  end

  test "native OIDC callback identifies an invited staff member", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    assert staff.status == :invited
    callback = EntraProvider.sign_in(context, "staff-subject")
    assert callback.status == 204
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "active", 0]]
    assert %{"staff" => {id, 0, expiry}} = Plug.Conn.get_session(callback)
    assert id == staff.id and expiry > System.system_time(:second)
    assert map_size(Plug.Conn.get_session(callback)) == 1
    assert callback.private.plug_session_info == :renew

    assert {:ok, %{last_authenticated_at: %DateTime{}}} =
             EntraStore.member(context.schema, staff.id)

    assert EntraProvider.request(context, "/admin", callback).status == 204
    assert EntraProvider.request(context, "/review", callback).status == 403
  end

  test "claim substitutions do not match an invited identity", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    other_issuer = "https://other-issuer.example.test/v2.0"
    other_tenant = "4fb90494-9bf6-4777-9694-90448e0384cd"

    cases = [
      wrong_tenant: [claims: %{"tid" => other_tenant}],
      inexact_tenant: [claims: %{"tid" => String.upcase(EntraProvider.tenant())}],
      missing_tenant: [omit: ["tid"]],
      wrong_issuer: [claims: %{"iss" => other_issuer}],
      missing_issuer: [omit: ["iss"]],
      substituted_subject: [claims: %{"sub" => "another-subject"}],
      missing_subject: [omit: ["sub"]],
      empty_subject: [claims: %{"sub" => ""}],
      numeric_subject: [claims: %{"sub" => 12}],
      email_only_identity: [omit: ["tid", "sub", "oid", "roles", "groups"]]
    ]

    for {scenario, options} <- cases do
      denied = EntraProvider.sign_in(context, "staff-subject", options)
      assert denied.status == 401, Atom.to_string(scenario)
      assert denied.resp_body == "Sign-in denied"
      assert Plug.Conn.get_session(denied) == %{}
    end

    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
  end

  test "an invitation preserves the pairwise subject byte for byte", context do
    subject = String.duplicate("A", 252) <> "_-z"
    assert {:ok, staff} = EntraStore.invite(context.schema, subject, [:admin])

    assert_sign_in_denied(EntraProvider.sign_in(context, String.downcase(subject)))
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
    assert [%{action: :provision}] = audit(context.schema)
    assert {:ok, %{subject: ^subject}} = EntraStore.member(context.schema, staff.id)

    assert EntraProvider.sign_in(context, subject).status == 204
  end

  test "subjects outside the supported ASCII format are invalid at invite and callback",
       context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    for {label, subject} <- invalid_subjects() do
      assert match?(
               {:error, %Ash.Error.Invalid{}},
               EntraStore.invite(context.schema, subject, [:admin])
             ),
             label

      flow = EntraProvider.start_sign_in(context, subject)
      refute EntraOIDCResponse.valid_tokens?(flow.tokens), label
      assert_callback_denied(context, staff, EntraProvider.callback(flow))
    end
  end

  test "provisioning does not trim issuer or tenant input" do
    issuer = EntraProvider.issuer() <> " "
    tenant = String.upcase(EntraProvider.tenant())

    input = %{
      issuer: issuer,
      subject: "staff-subject",
      tenant_id: tenant,
      roles: []
    }

    changeset = Ash.Changeset.for_create(EntraStaff, :provision, input)
    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :issuer) == issuer
    assert Ash.Changeset.get_attribute(changeset, :tenant_id) == tenant

    for attrs <- [%{tenant_id: input.tenant_id <> " "}, %{issuer: ""}, %{subject: ""}] do
      refute Ash.Changeset.for_create(EntraStaff, :provision, Map.merge(input, attrs)).valid?
    end
  end

  test "an inexact discovery issuer prevents the authorization redirect", context do
    metadata = EntraProvider.metadata(metadata_issuer: EntraProvider.issuer() <> "/")
    flow = EntraProvider.start_sign_in(context, "staff-subject", callback_metadata: metadata)

    assert_sign_in_denied(EntraProvider.request(context, "/staff/entra"))
    assert :atomics.get(flow.exchange_count, 1) == 0
  end

  test "a substituted discovery issuer prevents exchange of a valid code", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    issuer = "https://other-issuer.example.test/v2.0"

    flow =
      EntraProvider.start_sign_in(context, "staff-subject",
        callback_metadata: EntraProvider.metadata(metadata_issuer: issuer),
        claims: %{"iss" => issuer}
      )

    denied = EntraProvider.callback(flow)
    assert :atomics.get(flow.exchange_count, 1) == 0
    assert_sign_in_denied(denied)
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
  end

  test "empty discovery denies both phases before using endpoints", context do
    for document <- [nil, "", %{}] do
      assert_discovery_denied(context, document)
    end
  end

  test "incomplete discovery denies both phases before using endpoints", context do
    metadata = EntraProvider.metadata()

    for document <- [
          Map.delete(metadata, "issuer"),
          Map.delete(metadata, "authorization_endpoint"),
          Map.delete(metadata, "token_endpoint"),
          Map.delete(metadata, "jwks_uri"),
          %{metadata | "token_endpoint" => ""}
        ] do
      assert_discovery_denied(context, document)
    end
  end

  test "discovery denies malformed or insecure endpoints in either phase", context do
    metadata = EntraProvider.metadata()

    for field <- ~w(authorization_endpoint token_endpoint jwks_uri),
        endpoint <- [
          42,
          "/relative",
          "//entra.example.test/endpoint",
          "http://entra.example.test/endpoint",
          "https:/endpoint",
          "https://:443/endpoint",
          "https://@entra.example.test/endpoint",
          "https://entra.example.test/endpoint#",
          "https://entra.example.test:65536/endpoint",
          "https://entra.example.test:bad/endpoint",
          "https://entra.example.test/endpoint name",
          "https://entra.example.test/endpoint%GG"
        ] do
      assert_discovery_denied(context, Map.replace!(metadata, field, endpoint))
    end
  end

  test "discovery denies malformed or unsupported token authentication methods", context do
    metadata = EntraProvider.metadata()

    for methods <- [12, "none", nil, [], ["none", 12], ["client_secret_basic"]] do
      assert_discovery_denied(
        context,
        Map.replace!(metadata, "token_endpoint_auth_methods_supported", methods)
      )
    end
  end

  test "the callback accepts discovery without optional token authentication methods", context do
    assert {:ok, _staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    metadata = Map.delete(EntraProvider.metadata(), "token_endpoint_auth_methods_supported")
    flow = EntraProvider.start_sign_in(context, "staff-subject", callback_metadata: metadata)

    assert EntraProvider.callback(flow).status == 204
    assert :atomics.get(flow.exchange_count, 1) == 1
  end

  test "valid but unlisted identity is denied", context do
    assert EntraProvider.sign_in(context, "unlisted-subject").status == 401
    assert EntraStore.staff_snapshot(context.schema) == []
  end

  test "state and callback cookie failures do not exchange a code", context do
    flow = EntraProvider.start_sign_in(context, "staff-subject")

    assert EntraProvider.callback(flow, flow.params, nil).status == 401

    assert EntraProvider.callback(flow, Map.delete(flow.params, "state"), flow.redirect).status ==
             401

    assert EntraProvider.callback(flow, %{flow.params | "state" => "wrong"}, flow.redirect).status ==
             401

    assert :atomics.get(flow.exchange_count, 1) == 0
  end

  test "a spent code cannot complete a replayed callback", context do
    assert {:ok, _} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    flow = EntraProvider.start_sign_in(context, "staff-subject")
    assert EntraProvider.callback(flow).status == 204
    assert EntraProvider.callback(flow).status == 401
    assert :atomics.get(flow.exchange_count, 1) == 2
  end

  test "unverifiable tokens or unavailable endpoints deny the callback", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    cases = [
      wrong_nonce: [claims: %{"nonce" => "wrong"}],
      malformed_nonce: [claims: %{"nonce" => 123}],
      missing_nonce: [omit: ["nonce"]],
      wrong_audience: [claims: %{"aud" => "other-client"}],
      malformed_audience: [claims: %{"aud" => 123}],
      expired: [claims: %{"exp" => 0}],
      nonnumeric_expiry: [claims: %{"exp" => "unknown"}],
      invalid_issued_at: [claims: %{"iat" => "unknown"}],
      future_not_before: [claims: %{"nbf" => System.system_time(:second) + 300}],
      invalid_signature: [signing_key: JOSE.JWK.generate_key({:rsa, 2048})],
      unknown_key: [kid: "unlisted-key"],
      unsigned: [algorithm: "none"],
      unsupported_algorithm: [algorithm: "RS512"],
      unavailable_discovery: [unavailable: :callback_discovery],
      unavailable_token: [unavailable: :token],
      unavailable_jwks: [unavailable: :keys]
    ]

    for {scenario, options} <- cases do
      denied = EntraProvider.sign_in(context, "staff-subject", options)
      assert denied.status == 401, Atom.to_string(scenario)
      assert denied.resp_body == "Sign-in denied"
      assert Plug.Conn.get_session(denied) == %{}
    end

    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
  end

  test "malformed token responses and protected headers deny the callback", context do
    fields = ~w(id_token access_token token_type refresh_token expires_in scope)

    cases =
      malformed_documents(:tokens) ++
        field_mutations(:tokens, fields) ++
        missing_fields(:tokens, ~w(id_token access_token)) ++
        malformed_documents(:header) ++
        field_mutations(:header, ~w(alg kid typ cty b64 crit)) ++
        missing_fields(:header, ~w(alg kid)) ++
        [
          {"invalid compact JWS", [tokens: put_field("id_token", "abc")]},
          {"extra compact JWS segment",
           [tokens: &Map.update!(&1, "id_token", fn token -> token <> ".extra" end)]},
          {"invalid signature encoding", [tokens: alter_jws_signature("!%")]},
          {"empty signature segment", [tokens: alter_jws_signature("")]},
          {"other signing algorithm", [algorithm: "RS512"]},
          {"oversized compact JWS",
           [payload: put_field("unused", String.duplicate("a", 32_769))]},
          {"unencoded JWS payload", [header: put_field("b64", false)]}
        ]

    assert_malformed_responses(context, :tokens, cases)
  end

  test "malformed signed claims deny the callback", context do
    fields = ~w(iss sub aud azp exp nbf iat nonce tid)

    cases =
      malformed_documents(:payload) ++
        field_mutations(:payload, fields) ++
        missing_fields(:payload, fields -- ~w(azp nbf)) ++
        [
          {"empty audience list", [payload: put_field("aud", [])]},
          {"mixed audience list", [payload: put_field("aud", [EntraProvider.client_id(), 42])]},
          {"empty audience member", [payload: put_field("aud", [""])]},
          {"oversized audience member", [payload: put_field("aud", [oversized_text()])]}
        ]

    assert_malformed_responses(context, :tokens, cases)
  end

  test "malformed public key sets deny the callback even with a valid matching key", context do
    key_members =
      for field <- ~w(kty kid use alg n e d),
          {shape, value} <- malformed_values() do
        {"JWK #{field}/#{shape}", [jwks: alter_key(field, value)]}
      end

    missing_key_members =
      for field <- ~w(kty kid n e) do
        {"missing JWK #{field}",
         [jwks: fn %{"keys" => [key]} -> %{"keys" => [Map.delete(key, field)]} end]}
      end

    additional_cases = [
      {"empty keys", [jwks: put_field("keys", [])]},
      {"missing keys", [jwks: fn _ -> %{} end]},
      {"EC key", [jwks: alter_key("kty", "EC")]},
      {"invalid RSA modulus encoding", [jwks: alter_key("n", "!%")]},
      {"invalid RSA exponent encoding", [jwks: alter_key("e", "!%")]},
      {"malformed trailing key", [jwks: fn %{"keys" => keys} -> %{"keys" => keys ++ [nil]} end]}
    ]

    cases = malformed_documents(:jwks) ++ field_mutations(:jwks, ["keys"])

    assert_malformed_responses(
      context,
      :jwks,
      cases ++ key_members ++ missing_key_members ++ additional_cases
    )
  end

  test "the callback accepts supported optional provider fields", context do
    assert {:ok, _staff} = EntraStore.invite(context.schema, "staff-subject", [])

    flow =
      EntraProvider.start_sign_in(context, "staff-subject",
        tokens:
          &Map.merge(&1, %{
            "token_type" => "Bearer",
            "expires_in" => 300,
            "scope" => "openid",
            "refresh_token" => "synthetic-refresh"
          }),
        jwks: alter_key("use", "sig"),
        header: &Map.put(&1, "typ", "JWT"),
        claims: %{
          "aud" => [EntraProvider.client_id()],
          "azp" => EntraProvider.client_id(),
          "nbf" => System.system_time(:second)
        }
      )

    assert EntraProvider.callback(flow).status == 204
  end

  test "an exception inside Assent's HTTP adapter returns a generic denial", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = EntraProvider.sign_in(context, "staff-subject", raise_token_response: true)
        assert_callback_denied(context, staff, conn)
      end)

    assert log =~ "entra_oidc_callback_exception"
    refute log =~ "synthetic adapter detail"
  end

  test "the sign-in action rejects caller-supplied claim maps", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    query =
      Ash.Query.for_read(
        EntraStaff,
        :sign_in_with_entra,
        %{
          user_info: %{"sub" => "staff-subject", "tid" => EntraProvider.tenant()},
          oauth_tokens: %{"id_token" => "unverified"}
        },
        tenant: context.schema,
        actor: %{kind: :bootstrap}
      )

    assert {:error, _denied} = Ash.read(query)
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
  end

  test "concurrent verified callbacks activate once and ignore changed provider email", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    tasks =
      for email <- ["first@example.test", "second@example.test"] do
        Task.async(fn ->
          Req.Test.set_req_test_to_private()
          EntraProvider.sign_in(context, "staff-subject", claims: %{"email" => email})
        end)
      end

    for task <- tasks do
      callback = Task.await(task)
      assert callback.status == 204
      assert {id, 0, _expiry} = Plug.Conn.get_session(callback, :staff)
      assert id == staff.id
    end

    events = audit(context.schema)
    assert Enum.sort(Enum.map(events, & &1.action)) == [:activate, :login, :provision]
    activation = Enum.find(events, &(&1.action == :activate))
    assert activation.actor_kind == :entra_callback
    assert activation.actor_id == staff.id
    assert activation.target_id == staff.id
    assert activation.reason == :verified_oidc
    assert activation.metadata["before"]["status"] == "invited"
    assert activation.metadata["after"]["status"] == "active"
    assert is_binary(activation.correlation_id)
    assert %DateTime{} = activation.inserted_at

    evidence = Jason.encode!(Enum.map(events, & &1.metadata))
    refute evidence =~ "example.test"
    refute evidence =~ "synthetic-access"
    refute evidence =~ "staff-subject"
  end

  test "disable denies an old cookie, direct stale probes and a verified callback", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    callback = EntraProvider.sign_in(context, "staff-subject")
    session = EntraSession.actor(callback)
    assert {:ok, candidate} = EntraStore.member(context.schema, staff.id)

    assert {:ok, %{status: :disabled, disabled_at: %DateTime{}, generation: 1}} =
             EntraStore.manage(context.schema, session, staff.id, :disable, %{})

    assert EntraProvider.request(context, "/admin", callback).status == 403

    assert {:error, %Ash.Error.Forbidden{}} =
             EntraSession.probe(context.schema, session, :admin_probe)

    denied = EntraProvider.sign_in(context, "staff-subject")
    assert denied.status == 401
    assert Plug.Conn.get_session(denied) == %{}

    # Reuse the previously verified candidate after disable has committed.
    assert {:error, :denied} =
             EntraStore.activate(context.schema, candidate, %{
               kind: :entra_callback,
               schema: context.schema
             })

    assert {:error, :denied} = EntraStore.manage(context.schema, session, staff.id, :disable, %{})

    assert Enum.sort(Enum.map(audit(context.schema), & &1.action)) == [
             :activate,
             :disable,
             :provision
           ]
  end

  test "local role changes invalidate old cookies even after role restoration", context do
    assert {:ok, _} = EntraStore.invite(context.schema, "administrator", [:admin])
    admin = context |> EntraProvider.sign_in("administrator") |> EntraSession.actor()

    assert {:ok, staff} =
             EntraStore.invite(context.schema, "staff-subject", [:knowledge_reviewer])

    old_cookie = EntraProvider.sign_in(context, "staff-subject")

    assert EntraProvider.request(context, "/review", old_cookie).status == 204
    assert EntraProvider.request(context, "/admin", old_cookie).status == 403

    assert {:ok, %{generation: 1}} =
             EntraStore.manage(context.schema, admin, staff.id, :change_roles, %{
               roles: [:support_operator]
             })

    assert EntraProvider.request(context, "/review", old_cookie).status == 403

    assert {:error, %Ash.Error.Forbidden{}} =
             EntraSession.probe(context.schema, EntraSession.actor(old_cookie), :reviewer_probe)

    limited_cookie = EntraProvider.sign_in(context, "staff-subject")
    assert limited_cookie.status == 204
    assert EntraProvider.request(context, "/review", limited_cookie).status == 403
    assert EntraProvider.request(context, "/admin", limited_cookie).status == 403

    assert {:error, :denied} =
             EntraStore.manage(
               context.schema,
               EntraSession.actor(limited_cookie),
               staff.id,
               :change_roles,
               %{roles: [:admin]}
             )

    assert {:ok, %{generation: 2}} =
             EntraStore.manage(context.schema, admin, staff.id, :change_roles, %{
               roles: [:knowledge_reviewer]
             })

    assert EntraProvider.request(context, "/review", old_cookie).status == 403
    assert EntraProvider.request(context, "/review", limited_cookie).status == 403
    fresh_cookie = EntraProvider.sign_in(context, "staff-subject")
    assert EntraProvider.request(context, "/review", fresh_cookie).status == 204
  end

  test "ordinary sessions cannot directly update staff or append audit", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    assert {:error, _} = EntraStore.invite(context.schema, "staff-subject", [:support_operator])
    callback = EntraProvider.sign_in(context, "staff-subject")
    actor = EntraSession.actor(callback)

    assert {:error, %Ash.Error.Forbidden{}} =
             EntraSession.probe(context.schema, nil, :admin_probe)

    assert EntraProvider.request(context, "/admin").status == 403

    assert {:error, %Ash.Error.Forbidden{}} =
             EntraSession.probe(context.schema, %{actor | expiry: 0}, :admin_probe)

    assert {:error, %Ash.Error.Forbidden{}} =
             EntraSession.probe(
               context.schema,
               %{actor | id: Ash.UUIDv7.generate()},
               :admin_probe
             )

    tampered = put_in(callback.resp_cookies["_vgas_f08"].value, "tampered")
    assert EntraProvider.request(context, "/admin", tampered).status == 403

    changeset = Ash.Changeset.for_update(staff, :disable, %{})

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(changeset, actor: actor, tenant: context.schema)

    [event | _] = audit(context.schema)

    changeset =
      Ash.Changeset.for_create(
        EntraAudit,
        :append,
        event
        |> Map.take([:target_id, :actor_kind, :actor_id, :action, :reason, :metadata])
        |> Map.put(:correlation_id, Ash.UUIDv7.generate())
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(changeset, actor: actor, tenant: context.schema)

    assert Enum.sort(Enum.map(audit(context.schema), & &1.action)) == [:activate, :provision]

    assert Enum.map(Ash.Resource.Info.actions(EntraAudit), & &1.name) |> Enum.sort() ==
             [:append, :evidence]
  end

  test "an empty local role grant confers no privilege", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [])
    callback = EntraProvider.sign_in(context, "staff-subject")
    assert callback.status == 204
    assert {:ok, %{status: :active, roles: []}} = EntraStore.member(context.schema, staff.id)
    assert EntraProvider.request(context, "/admin", callback).status == 403
    assert EntraProvider.request(context, "/review", callback).status == 403
  end

  test "audit rejection rolls activation back and prevents session issuance", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    Repo.query!("""
    ALTER TABLE #{context.schema}.audit
    ADD CONSTRAINT reject_activation CHECK (action <> 'activate')
    """)

    denied = EntraProvider.sign_in(context, "staff-subject")
    assert denied.status == 401
    assert Plug.Conn.get_session(denied) == %{}
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
    assert [%{action: :provision}] = audit(context.schema)
  end

  test "Ash reads and writes staff and audit only inside the selected prefix", context do
    other_schema = EntraStore.create_schema!()
    on_exit(fn -> EntraStore.drop_schema!(other_schema) end)
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    assert {:ok, other} = EntraStore.invite(other_schema, "staff-subject", [:support_operator])

    assert EntraProvider.sign_in(context, "staff-subject").status == 204
    assert {:ok, %{status: :active}} = EntraStore.member(context.schema, staff.id)
    assert {:ok, %{status: :invited}} = EntraStore.member(other_schema, other.id)
    assert {:ok, nil} = EntraStore.member(other_schema, staff.id)
    assert {:ok, nil} = EntraStore.member(context.schema, other.id)
    assert [%{target_id: id}] = audit(other_schema)
    assert id == other.id
    assert Enum.all?(audit(context.schema), &(&1.target_id == staff.id))
  end

  test "audit rejection rolls back management and preserves existing session access", context do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])
    callback = EntraProvider.sign_in(context, "staff-subject")
    assert callback.status == 204
    actor = EntraSession.actor(callback)
    assert {:ok, before} = EntraStore.member(context.schema, staff.id)
    assert EntraProvider.request(context, "/admin", callback).status == 204
    assert EntraProvider.request(context, "/review", callback).status == 403

    Repo.query!("""
    ALTER TABLE #{context.schema}.audit
    ADD CONSTRAINT reject_management CHECK (action NOT IN ('disable', 'change_roles'))
    """)

    for {action, attrs} <- [disable: %{}, change_roles: %{roles: [:knowledge_reviewer]}] do
      result = EntraStore.manage(context.schema, actor, staff.id, action, attrs)
      assert {:ok, after_attempt} = EntraStore.member(context.schema, staff.id)

      fields = [:status, :roles, :generation, :disabled_at, :updated_at]
      assert Map.take(after_attempt, fields) == Map.take(before, fields)
      assert EntraProvider.request(context, "/admin", callback).status == 204
      assert EntraProvider.request(context, "/review", callback).status == 403
      assert {:error, %Ash.Changeset{valid?: false}} = result
    end

    assert Enum.sort(Enum.map(audit(context.schema), & &1.action)) == [:activate, :provision]
  end

  defp assert_discovery_denied(context, document) do
    flow = EntraProvider.start_sign_in(context, "staff-subject", callback_metadata: document)
    request = EntraProvider.request(context, "/staff/entra")
    callback = EntraProvider.callback(flow)

    assert :atomics.get(flow.exchange_count, 1) == 0
    assert_sign_in_denied(request)
    assert_sign_in_denied(callback)
  end

  defp assert_sign_in_denied(conn) do
    assert conn.status == 401
    assert conn.resp_body == "Sign-in denied"
    assert Plug.Conn.get_resp_header(conn, "location") == []
    assert Plug.Conn.get_session(conn) == %{}
  end

  defp assert_callback_denied(context, staff, conn) do
    assert_sign_in_denied(conn)
    assert EntraStore.staff_snapshot(context.schema) == [[staff.id, "invited", 0]]
    assert [%{action: :provision}] = audit(context.schema)
  end

  defp assert_malformed_responses(context, kind, cases) do
    assert {:ok, staff} = EntraStore.invite(context.schema, "staff-subject", [:admin])

    for {label, opts} <- cases do
      flow = EntraProvider.start_sign_in(context, "staff-subject", opts)
      assert_invalid_shape(kind, flow, label)
      conn = EntraProvider.callback(flow)
      assert conn.status == 401, label
      assert_callback_denied(context, staff, conn)
      assert :atomics.get(flow.exchange_count, 1) == 1, label
    end
  end

  defp assert_invalid_shape(:tokens, flow, label) do
    refute EntraOIDCResponse.valid_tokens?(flow.tokens), label
  end

  defp assert_invalid_shape(:jwks, flow, label) do
    refute EntraOIDCResponse.valid_jwks?(flow.jwks), label
  end

  defp malformed_documents(option) do
    for {shape, value} <- malformed_values(),
        do: {"#{option}/#{shape}", [{option, fn _ -> value end}]}
  end

  defp field_mutations(option, fields) do
    for field <- fields,
        {shape, value} <- malformed_values(),
        do: {"#{option}.#{field}/#{shape}", [{option, put_field(field, value)}]}
  end

  defp missing_fields(option, fields) do
    for field <- fields, do: {"missing #{option}.#{field}", [{option, &Map.delete(&1, field)}]}
  end

  defp malformed_values do
    [
      {"null", nil},
      {"number", 12.5},
      {"list", [42]},
      {"object", %{"bad" => true}},
      {"empty", ""},
      {"oversized", oversized_text()}
    ]
  end

  defp invalid_subjects do
    [
      {"empty", ""},
      {"oversized", String.duplicate("a", 256)},
      {"non-ASCII", "onderstéun"},
      {"embedded tab", "staff\t-subject"},
      {"trailing tab", "staff-subject\t"},
      {"embedded NUL", "staff\0-subject"},
      {"embedded DEL", "staff\x7F-subject"},
      {"leading space", " another-staff-subject"},
      {"trailing space", "another-staff-subject "}
    ]
  end

  defp put_field(field, value), do: &Map.put(&1, field, value)
  defp oversized_text, do: String.duplicate("a", 4_097)

  defp alter_key(field, value) do
    fn %{"keys" => [key]} -> %{"keys" => [Map.put(key, field, value)]} end
  end

  defp alter_jws_signature(signature) do
    fn tokens ->
      [header, claims, _signature] = String.split(tokens["id_token"], ".")
      Map.put(tokens, "id_token", Enum.join([header, claims, signature], "."))
    end
  end

  defp audit(schema) do
    Ash.read!(EntraAudit, action: :evidence, tenant: schema, actor: %{kind: :audit_evidence})
  end
end
