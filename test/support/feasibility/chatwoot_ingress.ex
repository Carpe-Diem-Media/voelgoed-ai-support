defmodule VoelgoedAi.Feasibility.ChatwootIngress do
  @moduledoc """
  Test-only Agent Bot receipt. Authenticate the exact bytes before decoding JSON.
  The 64 KiB limit and inclusive five-minute window are fixture settings.
  """
  import Plug.Conn

  alias VoelgoedAi.Feasibility.ChatwootStore

  @limit 65_536
  @max_id 9_223_372_036_854_775_807

  def init(opts), do: opts

  def call(%{method: "POST", path_info: ["webhooks", installation]} = conn, _opts) do
    ctx = conn.private[:f06_context]

    with %{installation: ^installation} <- ctx,
         {:ok, timestamp, signature} <- signed_headers(conn, ctx.now.()),
         :ok <- json_content_type(conn),
         {:ok, bytes, conn} <- read_bytes(conn),
         :ok <- verify(bytes, timestamp, signature, ctx.signing_key),
         {:ok, payload} <- decode(bytes),
         {:ok, event} <- scoped_event(payload, ctx),
         {:ok, :ok} <- ChatwootStore.receipt(ctx, event, purpose(payload, event)) do
      send_resp(conn, 204, "")
    else
      {:reject, status} -> send_resp(conn, status, "")
      {:error, _reason} -> send_resp(conn, 500, "")
      _ -> send_resp(conn, 401, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp signed_headers(conn, now) do
    with [timestamp] <- get_req_header(conn, "x-chatwoot-timestamp"),
         true <- Regex.match?(~r/\A(?:0|[1-9][0-9]{0,11})\z/, timestamp),
         true <- abs(DateTime.to_unix(now) - String.to_integer(timestamp)) <= 300,
         ["sha256=" <> signature] <- get_req_header(conn, "x-chatwoot-signature"),
         64 <- byte_size(signature),
         {:ok, digest} <- Base.decode16(signature, case: :lower) do
      {:ok, timestamp, digest}
    else
      _ -> {:reject, 401}
    end
  end

  defp json_content_type(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _params} <- Plug.Conn.Utils.media_type(content_type) do
      :ok
    else
      _ -> {:reject, 415}
    end
  end

  defp read_bytes(conn, bytes \\ "") do
    case read_body(conn, length: @limit + 1 - byte_size(bytes), read_timeout: 1_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        bytes = bytes <> chunk

        cond do
          byte_size(bytes) > @limit -> {:reject, 413}
          status == :ok -> {:ok, bytes, conn}
          chunk == "" -> {:reject, 400}
          true -> read_bytes(conn, bytes)
        end

      {:error, _reason} ->
        {:reject, 400}
    end
  end

  defp verify(bytes, timestamp, signature, key) do
    expected = :crypto.mac(:hmac, :sha256, key, [timestamp, ".", bytes])
    if Plug.Crypto.secure_compare(expected, signature), do: :ok, else: {:reject, 401}
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:reject, 400}
    end
  end

  defp scoped_event(
         %{
           "account" => %{"id" => account},
           "inbox" => %{"id" => inbox},
           "conversation" => %{
             "id" => conversation,
             "account" => %{"id" => account},
             "inbox_id" => inbox,
             "meta" => %{"sender" => %{"id" => contact}}
           },
           "event" => event_type
         } = payload,
         %{account_id: account, inbox_id: inbox} = ctx
       )
       when is_integer(conversation) and conversation in 1..@max_id and
              is_integer(contact) and contact in 1..@max_id and is_binary(event_type) do
    message = payload["id"]

    cond do
      event_type == "message_created" and
          not (is_integer(message) and message in 1..@max_id) ->
        {:reject, 400}

      true ->
        {:ok,
         %{
           installation: ctx.installation,
           account_id: account,
           inbox_id: inbox,
           conversation_id: conversation,
           contact_id: contact,
           event_type: if(event_type == "message_created", do: event_type, else: "unsupported"),
           message_id: if(event_type == "message_created", do: message)
         }}
    end
  end

  defp scoped_event(_payload, _ctx), do: {:reject, 403}

  defp purpose(
         %{
           "message_type" => "incoming",
           "private" => false,
           "content_type" => "text",
           "content" => content,
           "sender" => %{"id" => contact, "account" => %{"id" => account}}
         } = payload,
         %{event_type: "message_created", contact_id: contact, account_id: account}
       )
       when is_binary(content) do
    if String.trim(content) != "" and Map.get(payload, "attachments", []) == [] and
         not Map.has_key?(payload["sender"], "type"), do: "input", else: "ignore"
  end

  defp purpose(
         %{
           "message_type" => "outgoing",
           "private" => false,
           "sender" => %{"type" => "user", "id" => id}
         },
         %{event_type: "message_created"}
       )
       when is_integer(id) and id in 1..@max_id, do: "human_reply"

  defp purpose(_payload, _event), do: "ignore"
end

defmodule VoelgoedAi.Feasibility.ChatwootEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :voelgoed_ai

  plug(VoelgoedAi.Feasibility.ChatwootIngress)
end
