defmodule VoelgoedAi.StaffKnowledgeFixture do
  @moduledoc false
  import Plug.Conn
  alias VoelgoedAiWeb.{Endpoint, StaffSession}

  @host "staff.example.test"
  @port 4205
  @origin "https://" <> @host

  def origin, do: @origin

  def issue_cookie(session) do
    Plug.Test.conn(:get, @origin <> "/staff/knowledge")
    |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
    |> StaffSession.call(StaffSession.init([]))
    |> StaffSession.put(session)
    |> send_resp(200, "")
  end

  def refresh_cookie(page, update_session) do
    Plug.Test.conn(:get, @origin <> "/staff/knowledge")
    |> Plug.Test.recycle_cookies(page)
    |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
    |> StaffSession.call(StaffSession.init([]))
    |> update_session.()
    |> send_resp(200, "")
    |> then(& &1.resp_cookies["_vgas_staff"].value)
  end

  def read_page(session, path) do
    Plug.Test.conn(:get, @origin <> path)
    |> Plug.Test.recycle_cookies(issue_cookie(session))
    |> Endpoint.call(Endpoint.init([]))
  end

  def browser_credentials(conn) do
    doc = LazyHTML.from_document(conn.resp_body)
    [csrf] = doc |> LazyHTML.query("meta[name='csrf-token']") |> LazyHTML.attribute("content")
    {conn.resp_cookies["_vgas_staff"].value, csrf}
  end

  def start_listener(:https) do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=" <> @host)

    ExUnit.Callbacks.start_supervised!(
      {Bandit,
       plug: Endpoint,
       ip: {127, 0, 0, 1},
       port: @port,
       scheme: :https,
       startup_log: false,
       thousand_island_options: [
         transport_options: [
           cert: X509.Certificate.to_der(cert),
           key: {:RSAPrivateKey, X509.PrivateKey.to_der(key)}
         ]
       ]}
    )
  end

  def start_listener(:http) do
    ExUnit.Callbacks.start_supervised!(
      {Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: @port, startup_log: false}
    )
  end

  def upgrade(transport, cookie, csrf, origin, extra_headers \\ []) do
    {module, socket} = connect(transport)
    path = "/staff/live/websocket?vsn=2.0.0"
    path = if csrf, do: path <> "&_csrf_token=" <> URI.encode_www_form(csrf), else: path

    headers =
      [
        {"Host", @host},
        {"Connection", "Upgrade"},
        {"Upgrade", "websocket"},
        {"Sec-WebSocket-Version", "13"},
        {"Sec-WebSocket-Key", Base.encode64(:crypto.strong_rand_bytes(16))},
        {"Cookie", cookie && "_vgas_staff=" <> cookie},
        {"Origin", origin}
      ] ++ extra_headers

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\n",
      for({name, value} <- headers, value, do: [name, ": ", value, "\r\n"]),
      "\r\n"
    ]

    :ok = module.send(socket, request)
    {:ok, status} = module.recv(socket, 0, 5_000)
    module.close(socket)
    [_, code | _] = String.split(status, " ", parts: 3)
    String.to_integer(code)
  end

  defp connect(:https) do
    {:ok, socket} =
      :ssl.connect({127, 0, 0, 1}, @port, [:binary, active: false, verify: :verify_none], 5_000)

    {:ssl, socket}
  end

  defp connect(:http) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @port, [:binary, active: false], 5_000)
    {:gen_tcp, socket}
  end
end
