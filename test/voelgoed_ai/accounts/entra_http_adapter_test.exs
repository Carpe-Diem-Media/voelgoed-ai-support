defmodule VoelgoedAi.Accounts.EntraHTTPAdapterTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.Accounts.{EntraConfig, EntraHTTPAdapter}
  alias VoelgoedAi.StaffFixtures

  defmodule Provider do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{owner: owner, scenario: scenario, body: body}) do
      send(owner, {:provider_request, conn.request_path})
      conn = put_resp_header(conn, "content-type", "application/json")

      case {scenario, conn.request_path} do
        {:redirect, "/redirected"} ->
          send_resp(conn, 200, body)

        {:redirect, _} ->
          conn |> put_resp_header("location", "/redirected") |> send_resp(302, "")

        {:slow, _} ->
          conn = send_chunked(conn, 200)
          # Longer than the adapter's 3 s receive timeout and shorter than
          # Finch's 5 s request timeout.
          Process.sleep(3_500)
          _ = chunk(conn, body)
          conn

        {:oversized, _} ->
          conn = send_chunked(conn, 200)
          piece = String.duplicate(" ", 8_192)

          Enum.reduce_while(List.duplicate(piece, 16) ++ [body], conn, fn data, conn ->
            case chunk(conn, data) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
          end)

        {:html, _} ->
          conn |> put_resp_header("content-type", "text/html") |> send_resp(200, body)

        {:valid, _} ->
          send_resp(conn, 200, body)
      end
    end
  end

  setup do
    tenant = StaffFixtures.tenant()
    issuer = EntraConfig.issuer(tenant)
    origin = EntraConfig.origin()
    path = "/#{tenant}/v2.0/.well-known/openid-configuration"
    oauth = "#{origin}/#{tenant}/oauth2/v2.0"

    metadata = %{
      "issuer" => issuer,
      "authorization_endpoint" => oauth <> "/authorize",
      "token_endpoint" => oauth <> "/token",
      "jwks_uri" => origin <> "/common/discovery/v2.0/keys",
      "token_endpoint_auth_methods_supported" => ["client_secret_post"]
    }

    %{
      path: path,
      url: origin <> path,
      registration: %{issuer: issuer, tenant_id: tenant},
      metadata: metadata
    }
  end

  test "real HTTP returns allowlisted JSON", context do
    assert {:ok, %{body: metadata}} = fetch(context, :valid)
    assert metadata == context.metadata
    assert_received {:provider_request, path} when path == context.path
  end

  for scenario <- [:redirect, :slow, :oversized, :html] do
    test "real HTTP rejects #{scenario} provider responses", context do
      assert fetch(context, unquote(scenario)) == {:error, :provider_response_denied}
      assert_received {:provider_request, path} when path == context.path
      refute_received {:provider_request, _}
    end
  end

  defp fetch(context, scenario) do
    server =
      start_supervised!(
        {Bandit,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         plug:
           {Provider, %{owner: self(), scenario: scenario, body: Jason.encode!(context.metadata)}}}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    Process.put({EntraHTTPAdapter, :loopback_port}, port)
    EntraHTTPAdapter.request(:get, context.url, nil, [], context.registration)
  after
    Process.delete({EntraHTTPAdapter, :loopback_port})
  end
end
