defmodule VoelgoedAi.StaffOperationsBrowserProof do
  use ExUnit.Case, async: false

  alias VoelgoedAi.{StaffEntraFixture, StaffFixtures, SupportDBCase}
  alias VoelgoedAi.Support.{Ingress, RunProcessing}
  alias VoelgoedAiWeb.Endpoint

  @tag timeout: 60_000
  test "TEST Entra cookies reach the separate operations socket and expose a keyboard-operable queue" do
    assert System.get_env("TEST_DATABASE_PORT") == "55436"
    assert System.get_env("TEST_DATABASE_HOST") == "127.0.0.1"
    assert System.get_env("VGAS_F04_DISPOSABLE") == "1"

    fixture = VoelgoedAi.SupportFixtures.setup()
    admin = StaffFixtures.bootstrap_admin(fixture.admin)

    assert {:ok, operator} =
             VoelgoedAi.Accounts.provision(admin, fixture.invited, [:support_operator])

    assert {:ok, operator_session} = StaffFixtures.authenticate(operator.id)
    ctx = SupportDBCase.setup(staff: {fixture, admin, operator_session})
    assert {:ok, id} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(id)

    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=staff.example.test")

    start_supervised!(
      {Bandit,
       plug: Endpoint,
       ip: {127, 0, 0, 1},
       port: 4204,
       scheme: :https,
       startup_log: false,
       thousand_island_options: [
         transport_options: [
           cert: X509.Certificate.to_der(cert),
           key: {:RSAPrivateKey, X509.PrivateKey.to_der(key)}
         ]
       ]}
    )

    entra = %{key: JOSE.JWK.generate_key({:rsa, 2048})}
    operator = StaffEntraFixture.sign_in(entra, fixture.invited.subject)
    admin = StaffEntraFixture.sign_in(entra, fixture.admin.subject)
    assert operator.status == 204
    assert admin.status == 204

    page = StaffEntraFixture.request(:get, "/staff/operations", operator)
    {cookie, csrf} = VoelgoedAi.StaffKnowledgeFixture.browser_credentials(page)
    assert socket_status(cookie, csrf, "https://staff.example.test") == 101
    assert socket_status(cookie, nil, "https://staff.example.test") == 403
    assert socket_status(cookie, csrf, "https://another.example.test") == 403

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        args: [Path.expand(".github/scripts/vgas29_browser.mjs")]
      ])

    # Pass ephemeral fixture cookies over the port only. Never persist them in
    # browser profiles, arguments, captures, or test output.
    true =
      Port.command(port, [
        Jason.encode!(%{
          operator: operator.resp_cookies["_vgas_staff"].value,
          admin: admin.resp_cookies["_vgas_staff"].value
        }),
        "\n"
      ])

    assert wait_for_browser(port) == 0
    assert [] = SupportDBCase.writes(ctx)
  end

  defp socket_status(cookie, csrf, origin) do
    {:ok, socket} =
      :ssl.connect({127, 0, 0, 1}, 4204, [verify: :verify_none, active: false], 3_000)

    path = "/staff/operations-live/websocket?vsn=2.0.0"
    path = if csrf, do: path <> "&_csrf_token=" <> URI.encode_www_form(csrf), else: path

    try do
      :ok =
        :ssl.send(socket, [
          "GET ",
          path,
          " HTTP/1.1\r\n",
          "Host: staff.example.test\r\n",
          "Connection: Upgrade\r\n",
          "Upgrade: websocket\r\n",
          "Sec-WebSocket-Version: 13\r\n",
          "Sec-WebSocket-Key: ",
          Base.encode64(:crypto.strong_rand_bytes(16)),
          "\r\n",
          "Cookie: _vgas_staff=",
          cookie,
          "\r\n",
          "Origin: ",
          origin,
          "\r\n\r\n"
        ])

      {:ok, response} = :ssl.recv(socket, 0, 3_000)
      [_, status | _] = response |> IO.iodata_to_binary() |> String.split(" ", parts: 3)
      String.to_integer(status)
    after
      :ssl.close(socket)
    end
  end

  defp wait_for_browser(port) do
    receive do
      {^port, {:data, text}} ->
        IO.write(text)
        wait_for_browser(port)

      {^port, {:exit_status, status}} ->
        status
    after
      50_000 ->
        Port.close(port)
        :timed_out
    end
  end
end
