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

  def channel_socket(page) do
    socket = %Phoenix.Socket{
      endpoint: Endpoint,
      handler: VoelgoedAiWeb.StaffLiveSocket,
      transport_pid: self(),
      pubsub_server: Endpoint.config(:pubsub_server),
      serializer: Phoenix.Socket.V2.JSONSerializer
    }

    {:ok, socket} =
      VoelgoedAiWeb.StaffLiveSocket.connect(%{}, socket, %{
        uri: URI.parse(@origin <> page.request_path),
        session: get_session(page)
      })

    socket
  end

  def start_listener(transport, plug \\ Endpoint)

  def start_listener(:https, plug) do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=" <> @host)

    ExUnit.Callbacks.start_supervised!(
      {Bandit,
       plug: plug,
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

  def start_listener(:http, plug) do
    ExUnit.Callbacks.start_supervised!(
      {Bandit, plug: plug, ip: {127, 0, 0, 1}, port: @port, startup_log: false}
    )
  end

  def https_status(path, headers) do
    request_status(:https, path, [{"Host", @host}, {"Connection", "close"} | headers])
  end

  def https_post_status(path, cookie, body) do
    headers = [
      {"Host", @host},
      {"Connection", "close"},
      {"Cookie", "_vgas_staff=" <> cookie},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Content-Length", Integer.to_string(byte_size(body))}
    ]

    {:ssl, socket} = connect(:https)

    try do
      :ok =
        :ssl.send(socket, [
          "POST ",
          path,
          " HTTP/1.1\r\n",
          for({name, value} <- headers, do: [name, ": ", value, "\r\n"]),
          "\r\n",
          body
        ])

      {:ok, status} = :ssl.recv(socket, 0, 5_000)
      [_, code | _] = String.split(status, " ", parts: 3)
      String.to_integer(code)
    after
      :ssl.close(socket)
    end
  end

  def upgrade(transport, cookie, csrf, origin, header_overrides \\ []) do
    {path, headers} = upgrade_request(cookie, csrf, origin)
    request_status(transport, path, Map.merge(headers, Map.new(header_overrides)))
  end

  def tls_join(cookie, csrf, topic, payload) do
    with_tls_socket(cookie, csrf, &tls_message(&1, "1", topic, "phx_join", payload))
  end

  def with_tls_socket(cookie, csrf, run) do
    {:ssl, socket} = connect(:https)

    try do
      {path, headers} = upgrade_request(cookie, csrf, @origin)
      :ok = :ssl.setopts(socket, packet: :http_bin)
      :ok = :ssl.send(socket, request(path, headers))
      {:ok, {:http_response, _, 101, _}} = :ssl.recv(socket, 0, 5_000)
      :ok = receive_upgrade_headers(socket)
      :ok = :ssl.setopts(socket, packet: :raw)
      run.(socket)
    after
      :ssl.close(socket)
    end
  end

  def tls_message(socket, ref, topic, event, payload) do
    message = Jason.encode!(["1", ref, topic, event, payload])
    {:ok, frame} = WebSockex.Frame.encode_frame({:text, message})
    :ok = :ssl.send(socket, frame)
    receive_reply(socket, ref, "")
  end

  defp receive_upgrade_headers(socket) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> receive_upgrade_headers(socket)
    end
  end

  defp receive_reply(socket, ref, buffer) do
    case WebSockex.Frame.parse_frame(buffer) do
      {:ok, {:text, text}, rest} ->
        case Jason.decode!(text) do
          [_, ^ref, _, "phx_reply", _] = reply -> reply
          _ -> receive_reply(socket, ref, rest)
        end

      :incomplete ->
        case :ssl.recv(socket, 0, 5_000) do
          {:ok, more} -> receive_reply(socket, ref, buffer <> more)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp upgrade_request(cookie, csrf, origin) do
    path = "/staff/live/websocket?vsn=2.0.0"
    path = if csrf, do: path <> "&_csrf_token=" <> URI.encode_www_form(csrf), else: path

    headers = %{
      "Host" => @host,
      "Connection" => "Upgrade",
      "Upgrade" => "websocket",
      "Sec-WebSocket-Version" => "13",
      "Sec-WebSocket-Key" => Base.encode64(:crypto.strong_rand_bytes(16)),
      "Cookie" => cookie && "_vgas_staff=" <> cookie,
      "Origin" => origin
    }

    {path, headers}
  end

  defp request_status(transport, path, headers) do
    {module, socket} = connect(transport)

    :ok = module.send(socket, request(path, headers))
    {:ok, status} = module.recv(socket, 0, 5_000)
    module.close(socket)
    [_, code | _] = String.split(status, " ", parts: 3)
    String.to_integer(code)
  end

  defp request(path, headers) do
    [
      "GET ",
      path,
      " HTTP/1.1\r\n",
      for({name, value} <- headers, value, do: [name, ": ", value, "\r\n"]),
      "\r\n"
    ]
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
