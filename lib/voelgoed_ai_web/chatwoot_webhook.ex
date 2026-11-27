defmodule VoelgoedAiWeb.ChatwootWebhook do
  @moduledoc """
  Authenticates the pinned Agent Bot candidate before parsing request content.
  The endpoint only accepts the configured installation and the TEST adapter.
  """

  import Plug.Conn

  alias Jason.OrderedObject

  @max_bytes 65_536
  @max_id 9_223_372_036_854_775_807
  @body_timeout 2_000

  def init(opts), do: opts

  if Mix.env() == :test do
    alias VoelgoedAi.Support.{ChatwootAdapter, Ingress}

    def call(%{method: "POST", path_info: ["webhooks", "chatwoot", installation]} = conn, _opts) do
      status =
        with %{installation_ref: ^installation, signing_key: key, adapter: {_, _}} = fixture <-
               ChatwootAdapter.fixture(),
             {:ok, event, conn} <- authenticate(conn, fixture, key, ChatwootAdapter.now()),
             {:ok, _id} <- Ingress.accept(event) do
          {conn, 204}
        else
          {:reject, status} -> {conn, status}
          {:error, :scope_denied} -> {conn, 403}
          {:error, _} -> {conn, 500}
          _ -> {conn, 404}
        end

      {conn, code} = status
      conn |> send_resp(code, "") |> halt()
    end
  else
    def call(%{method: "POST", path_info: ["webhooks", "chatwoot", _]} = conn, _opts),
      do: conn |> send_resp(404, "") |> halt()
  end

  def call(conn, _opts), do: conn

  @doc false
  def authenticate(conn, scope, signing_key, now) do
    with {:ok, timestamp, signature} <- signed_headers(conn, now),
         :ok <- content_headers(conn),
         {:ok, bytes, conn} <- read_bytes(conn),
         :ok <- verify(bytes, timestamp, signature, signing_key),
         {:ok, payload} <- decode(bytes),
         {:ok, receipt} <- qualify(payload, scope) do
      {:ok, receipt |> replay_key(timestamp, bytes) |> Map.put(:received_at, now), conn}
    end
  end

  # Non-message webhooks lack a provider event ID. Suppress exact signed
  # replays only; separately signed observations still reconcile current state.
  defp replay_key(%{message_id: _} = receipt, _timestamp, _bytes), do: receipt

  defp replay_key(receipt, timestamp, bytes) do
    digest = :crypto.hash(:sha256, ["signed:", timestamp, ".", :crypto.hash(:sha256, bytes)])
    Map.put(receipt, :stable_event_key, Base.encode16(digest, case: :lower))
  end

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

  defp content_headers(conn) do
    with [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(type),
         [] <- get_req_header(conn, "content-encoding") do
      declared_length(get_req_header(conn, "content-length"))
    else
      _ -> {:reject, 415}
    end
  end

  defp declared_length([]), do: :ok

  defp declared_length([length]) do
    case Integer.parse(length) do
      {number, ""} when number in 0..@max_bytes -> :ok
      {number, ""} when number > @max_bytes -> {:reject, 413}
      _ -> {:reject, 400}
    end
  end

  defp declared_length(_), do: {:reject, 400}

  defp read_bytes(conn) do
    deadline = System.monotonic_time(:millisecond) + @body_timeout
    read_bytes(conn, "", deadline)
  end

  defp read_bytes(conn, bytes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      limit = min(8_192, @max_bytes + 1 - byte_size(bytes))

      case read_body(conn, length: limit, read_length: limit, read_timeout: min(remaining, 500)) do
        {status, chunk, conn} when status in [:ok, :more] ->
          bytes = bytes <> chunk

          cond do
            byte_size(bytes) > @max_bytes -> {:reject, 413}
            System.monotonic_time(:millisecond) >= deadline -> {:reject, 400}
            status == :ok -> {:ok, bytes, conn}
            chunk == "" -> {:reject, 400}
            true -> read_bytes(conn, bytes, deadline)
          end

        {:error, _} ->
          {:reject, 400}
      end
    else
      {:reject, 400}
    end
  end

  defp verify(bytes, timestamp, signature, key) do
    expected = :crypto.mac(:hmac, :sha256, key, [timestamp, ".", bytes])
    if Plug.Crypto.secure_compare(expected, signature), do: :ok, else: {:reject, 401}
  end

  defp decode(bytes) do
    with {:ok, %OrderedObject{} = object} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, payload} <- unique_members(object, 0) do
      {:ok, payload}
    else
      _ -> {:reject, 400}
    end
  end

  defp unique_members(_, 32), do: :error

  defp unique_members(%OrderedObject{values: pairs}, depth) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with false <- Map.has_key?(acc, key),
           {:ok, value} <- unique_members(value, depth + 1) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp unique_members(values, depth) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case unique_members(value, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp unique_members(value, _depth), do: {:ok, value}

  defp qualify(
         %{
           "account" => %{"id" => account},
           "inbox" => %{"id" => inbox},
           "conversation" => %{
             "id" => conversation,
             "account" => %{"id" => account},
             "inbox_id" => inbox,
             "meta" => %{"sender" => %{"id" => contact}}
           },
           "event" => type
         } = payload,
         %{external_account_id: account, external_inbox_id: inbox, installation_ref: installation}
       )
       when conversation in 1..@max_id and contact in 1..@max_id and is_binary(type) do
    with true <- consistent?(payload, "account_id", account),
         true <- consistent?(payload, "inbox_id", inbox),
         true <- consistent?(payload, "conversation_id", conversation) do
      event(
        type,
        payload,
        %{
          installation_ref: installation,
          external_account_id: account,
          external_inbox_id: inbox,
          conversation_id: conversation,
          contact_id: contact
        }
      )
    else
      _ -> {:reject, 403}
    end
  end

  defp qualify(_, _), do: {:reject, 403}

  defp consistent?(object, key, expected), do: Map.get(object, key, expected) === expected

  defp event(type, %{"id" => id} = payload, identity)
       when type in ["message_created", "message_updated"] and id in 1..@max_id do
    kind = if type == "message_created", do: message_kind(payload, identity), else: :observation
    event_type = if type == "message_created", do: :message_created, else: :message_updated
    {:ok, Map.merge(identity, %{event_type: event_type, message_id: id, kind: kind})}
  end

  defp event(type, _payload, _identity) when type in ["message_created", "message_updated"],
    do: {:reject, 400}

  defp event(type, _payload, identity)
       when type in ["conversation_status_changed", "conversation_updated"] do
    {:ok, Map.merge(identity, %{event_type: :conversation_observed, kind: :observation})}
  end

  defp event(_, _, identity),
    do: {:ok, Map.merge(identity, %{event_type: :unsupported, kind: :ignored})}

  defp message_kind(
         %{
           "message_type" => "incoming",
           "private" => false,
           "content_type" => "text",
           "content" => content,
           "sender" => %{"id" => contact, "account" => %{"id" => account}} = sender
         } = payload,
         %{contact_id: contact, external_account_id: account}
       )
       when is_binary(content) do
    cond do
      Map.has_key?(sender, "type") or Map.get(payload, "attachments", []) != [] -> :ignored
      String.trim(content) == "" -> :ignored
      String.length(content) > 3_000 -> :oversize
      true -> :input
    end
  end

  defp message_kind(
         %{
           "message_type" => "outgoing",
           "private" => false,
           "sender" => %{"type" => "user", "id" => id}
         },
         _identity
       )
       when id in 1..@max_id,
       do: :human_outbound

  defp message_kind(%{"message_type" => "outgoing", "private" => false}, _identity),
    do: :observation

  defp message_kind(_, _), do: :ignored
end
