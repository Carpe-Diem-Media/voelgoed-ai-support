defmodule VoelgoedAi.EntraFeasibilityTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias VoelgoedAi.Feasibility.{EntraAudit, EntraProvider, EntraSession, EntraStaff, EntraStore}
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
      missing_tenant: [omit: ["tid"]],
      wrong_issuer: [claims: %{"iss" => other_issuer}],
      missing_issuer: [omit: ["iss"]],
      substituted_issuer: [metadata_issuer: other_issuer, claims: %{"iss" => other_issuer}],
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

  defp audit(schema) do
    Ash.read!(EntraAudit, action: :evidence, tenant: schema, actor: %{kind: :audit_evidence})
  end
end
