defmodule VoelgoedAiWeb.ChatwootWebhookTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  alias VoelgoedAiWeb.ChatwootWebhook

  @scope %{installation_ref: "synthetic", external_account_id: 1, external_inbox_id: 2}
  @key "synthetic-fixture-key"
  @now ~U[2026-11-26 12:00:00Z]

  test "validates literal bytes and inclusive freshness before decoding" do
    body = Jason.encode!(payload())

    for offset <- [-300, 300] do
      assert {:ok, %{kind: :input, message_id: 4}, _} =
               authenticate(signed(body, offset))
    end

    assert {:reject, 401} = authenticate(signed(body, -301))
    assert {:reject, 401} = authenticate(signed(body, 301))
    assert {:reject, 401} = authenticate(signed(body <> " ", 0, body))
    assert {:reject, 401} = authenticate(signed("{", 0, body))
    assert {:reject, 400} = authenticate(signed("{"))
  end

  test "rejects missing, duplicate and malformed authentication headers" do
    request = signed(Jason.encode!(payload()))

    for header <- ["x-chatwoot-signature", "x-chatwoot-timestamp"] do
      assert {:reject, 401} = authenticate(delete_req_header(request, header))

      assert {:reject, 401} =
               authenticate(%{
                 request
                 | req_headers: [{header, "duplicate"} | request.req_headers]
               })
    end

    assert {:reject, 401} = authenticate(put_req_header(request, "x-chatwoot-timestamp", "+1"))
    assert {:reject, 401} = authenticate(put_req_header(request, "x-chatwoot-signature", "bad"))
  end

  test "rejects ambiguous JSON, unsupported content types, and excessive bodies" do
    body = Jason.encode!(payload())

    assert {:reject, 400} =
             authenticate(signed(~s({"id":99,) <> binary_part(body, 1, byte_size(body) - 1)))

    assert {:reject, 415} =
             authenticate(put_req_header(signed(body), "content-type", "text/plain"))

    too_big = String.pad_trailing(body, 65_537)
    assert {:reject, 413} = authenticate(signed(too_big))
    assert {:reject, 413} = authenticate(put_req_header(signed(body), "content-length", "65537"))
  end

  test "authenticates literal bytes across body chunks" do
    body = Jason.encode!(payload()) <> String.duplicate(" ", 17_000)
    assert {:ok, %{kind: :input}, _} = authenticate(signed(body))
    assert {:reject, 401} = authenticate(signed(body <> "\n", 0, body))
  end

  test "qualifies identity and keeps private, unsupported, and invalid senders out of reply work" do
    for other <- [
          put_in(payload()["account"]["id"], 99),
          put_in(payload()["conversation"]["inbox_id"], 99),
          payload()
          |> put_in(["account", "id"], 99)
          |> put_in(["conversation", "account", "id"], 99),
          Map.put(payload(), "conversation_id", 99)
        ] do
      assert {:reject, 403} = authenticate(signed(Jason.encode!(other)))
    end

    for other <- [
          Map.put(payload(), "private", true),
          Map.put(payload(), "content_type", "system"),
          Map.put(payload(), "attachments", [%{"id" => 2}]),
          put_in(payload()["sender"]["id"], 99)
        ] do
      assert {:ok, %{kind: :ignored}, _} = authenticate(signed(Jason.encode!(other)))
    end
  end

  test "oversized text is triage and status observations never become customer input" do
    oversized = Map.put(payload(), "content", String.duplicate("x", 3_001))
    assert {:ok, %{kind: :oversize}, _} = authenticate(signed(Jason.encode!(oversized)))

    for type <- ["conversation_status_changed", "conversation_updated"] do
      observation = payload() |> Map.delete("id") |> Map.put("event", type)

      assert {:ok, %{kind: :observation} = receipt, _} =
               authenticate(signed(Jason.encode!(observation)))

      refute Map.has_key?(receipt, :message_id)
    end
  end

  test "default endpoint does not accept Chatwoot work" do
    conn = signed(Jason.encode!(payload()))
    assert VoelgoedAiWeb.Endpoint.call(conn, VoelgoedAiWeb.Endpoint.init([])).status == 404
  end

  defp authenticate(conn), do: ChatwootWebhook.authenticate(conn, @scope, @key, @now)

  defp signed(body, offset \\ 0, signed_body \\ nil) do
    timestamp = Integer.to_string(DateTime.to_unix(@now) + offset)

    digest =
      :crypto.mac(:hmac, :sha256, @key, [timestamp, ".", signed_body || body])
      |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/webhooks/chatwoot/synthetic", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-chatwoot-timestamp", timestamp)
    |> put_req_header("x-chatwoot-signature", "sha256=" <> digest)
  end

  defp payload do
    %{
      "event" => "message_created",
      "id" => 4,
      "account" => %{"id" => 1},
      "inbox" => %{"id" => 2},
      "conversation" => %{
        "id" => 3,
        "account" => %{"id" => 1},
        "inbox_id" => 2,
        "meta" => %{"sender" => %{"id" => 5}}
      },
      "sender" => %{"id" => 5, "account" => %{"id" => 1}},
      "message_type" => "incoming",
      "private" => false,
      "content_type" => "text",
      "content" => "Synthetic test input"
    }
  end
end
