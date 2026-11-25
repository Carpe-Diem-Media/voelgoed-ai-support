defmodule VoelgoedAi.Feasibility.EntraDiscoveryAdapter do
  @moduledoc false
  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.{HTTPResponse, Req}
  alias VoelgoedAi.Feasibility.EntraProvider

  @required_endpoints ~w(authorization_endpoint token_endpoint jwks_uri)

  @impl true
  def request(method, url, body, headers, opts) do
    response = Req.request(method, url, body, headers, opts)
    issuer = EntraProvider.issuer()

    if method == :get and url == issuer <> "/.well-known/openid-configuration" do
      validate_discovery(response, issuer)
    else
      response
    end
  end

  # Assent 0.3.2 uses discovery endpoints before it checks the signed token.
  # Validate the metadata on both the redirect and the callback (OIDC Discovery §4.3).
  defp validate_discovery({:ok, %HTTPResponse{status: 200, body: metadata}} = response, issuer) do
    with %{"issuer" => discovered_issuer} <- metadata,
         true <- discovered_issuer === issuer,
         true <- Enum.all?(@required_endpoints, &endpoint_present?(metadata[&1])) do
      response
    else
      _ -> {:error, :invalid_discovery_metadata}
    end
  end

  defp validate_discovery(response, _issuer), do: response

  defp endpoint_present?(value), do: is_binary(value) and String.trim(value) != ""
end

defmodule VoelgoedAi.Feasibility.EntraClaims do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  alias VoelgoedAi.Feasibility.EntraProvider

  @impl true
  def prepare(query, _, %{actor: %{kind: :entra_callback, schema: schema}, tenant: schema}) do
    info = Ash.Query.get_argument(query, :user_info)
    tokens = Ash.Query.get_argument(query, :oauth_tokens)

    # The fixture router installs this actor only on the native callback.
    # Assent has verified the ID token before invoking this preparation.
    # Peek for the signed issuer and tenant binding and check time claim types
    # because Assent omits the protocol claims and compares expiry as an Elixir term.
    with true <- get_in(query.context, [:private, :ash_authentication?]),
         %{"sub" => sub, "tid" => tenant} <- info,
         true <- is_binary(sub) and byte_size(sub) in 1..255,
         true <- tenant == EntraProvider.tenant(),
         %{fields: %{"iss" => issuer, "tid" => ^tenant, "sub" => ^sub} = claims} <-
           JOSE.JWT.peek_payload(tokens["id_token"]),
         true <- issuer == EntraProvider.issuer(),
         true <- valid_times?(claims) do
      Ash.Query.filter(
        query,
        issuer == ^issuer and subject == ^sub and tenant_id == ^tenant and
          status in [:invited, :active]
      )
    else
      _ -> deny(query)
    end
  end

  def prepare(query, _, _), do: deny(query)

  defp deny(query), do: Ash.Query.add_error(query, :user_info, "Invalid identity")

  defp valid_times?(%{"exp" => exp, "iat" => iat} = claims) do
    now = System.system_time(:second)
    nbf = Map.get(claims, "nbf", now)
    is_integer(exp) and exp > now and is_integer(iat) and is_integer(nbf) and nbf <= now
  end
end

defmodule VoelgoedAi.Feasibility.EntraTransitionPolicy do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the locked transition names this action, schema and target"

  @impl true
  def match?(
        %{kind: :locked_transition, action: action, schema: schema, target_id: id},
        %{subject: %Ash.Changeset{action: %{name: action}, tenant: schema, data: %{id: id}}},
        _opts
      ),
      do: true

  def match?(_, _, _), do: false
end

defmodule VoelgoedAi.Feasibility.EntraSessionRole do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Feasibility.EntraStore

  @impl true
  def describe(opts), do: "the current local staff record grants #{opts[:role]}"

  @impl true
  def match?(
        %{kind: :session, id: id, schema: schema} = actor,
        %{subject: %{tenant: schema}},
        opts
      ) do
    case EntraStore.member(schema, id) do
      {:ok, staff} -> EntraStore.allowed?(staff, actor, opts[:role])
      {:error, _} -> false
    end
  end

  def match?(_, _, _), do: false
end

defmodule VoelgoedAi.Feasibility.EntraSession do
  @moduledoc false
  import Plug.Conn

  alias VoelgoedAi.Feasibility.EntraStaff

  def put(conn, staff) do
    conn
    |> Plug.Conn.clear_session()
    |> configure_session(renew: true)
    |> put_session(:staff, {staff.id, staff.generation, System.system_time(:second) + 600})
  end

  def actor(conn) do
    case get_session(conn, :staff) do
      {id, generation, expiry}
      when is_binary(id) and is_integer(generation) and is_integer(expiry) ->
        %{
          kind: :session,
          id: id,
          generation: generation,
          expiry: expiry,
          schema: conn.private.f08_schema
        }

      _ ->
        nil
    end
  end

  def probe(schema, actor, action) do
    EntraStaff
    |> Ash.ActionInput.for_action(action, %{}, tenant: schema, actor: actor)
    |> Ash.run_action()
  end
end

defmodule VoelgoedAi.Feasibility.EntraController do
  @moduledoc false
  use Phoenix.Controller, formats: []
  use AshAuthentication.Phoenix.Controller

  alias VoelgoedAi.Feasibility.{EntraSession, EntraStore}

  @impl true
  def success(conn, {:entra, :callback} = activity, candidate, _token) do
    actor = Ash.PlugHelpers.get_actor(conn)

    case EntraStore.activate(conn.private.f08_schema, candidate, actor) do
      {:ok, staff} -> conn |> EntraSession.put(staff) |> send_resp(204, "")
      {:error, reason} -> failure(conn, activity, reason)
    end
  end

  @impl true
  def sign_out(conn, _params), do: conn |> Plug.Conn.clear_session() |> send_resp(204, "")

  @impl true
  def failure(conn, _activity, _reason) do
    conn |> Plug.Conn.clear_session() |> send_resp(401, "Sign-in denied")
  end
end

defmodule VoelgoedAi.Feasibility.EntraRouter do
  @moduledoc false
  use Plug.Router

  alias AshAuthentication.Plug.Dispatcher
  alias VoelgoedAi.Feasibility.{EntraController, EntraSession, EntraStaff}

  plug(Plug.Session, store: :cookie, key: "_vgas_f08", signing_salt: "vgas-f08", secure: true)
  plug(:fetch_session)
  plug(:fetch_query_params)
  plug(:match)
  plug(:dispatch)

  get "/staff/entra" do
    dispatch_oidc(conn, :request)
  end

  get "/staff/entra/callback" do
    schema = conn.private.f08_schema

    conn
    |> Ash.PlugHelpers.set_tenant(schema)
    |> Ash.PlugHelpers.set_actor(%{kind: :entra_callback, schema: schema})
    |> dispatch_oidc(:callback)
  end

  get "/admin" do
    probe(conn, :admin_probe)
  end

  get "/review" do
    probe(conn, :reviewer_probe)
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp probe(conn, action) do
    case EntraSession.probe(conn.private.f08_schema, EntraSession.actor(conn), action) do
      {:ok, true} -> send_resp(conn, 204, "")
      {:error, _} -> send_resp(conn, 403, "Access denied")
    end
  end

  defp dispatch_oidc(conn, phase) do
    strategy = AshAuthentication.Info.strategy!(EntraStaff, :entra)
    Dispatcher.call(conn, {phase, strategy, EntraController})
  rescue
    error in FunctionClauseError ->
      # Assent 0.3.2 expects strings for state and nonce. A malformed value
      # can raise before the strategy returns its normal denial result.
      case error do
        %FunctionClauseError{module: Assent, function: :constant_time_compare, arity: 2}
        when phase == :callback ->
          EntraController.failure(conn, {:entra, :callback}, :invalid_challenge)

        _ ->
          reraise error, __STACKTRACE__
      end

    error in Protocol.UndefinedError ->
      if phase == :callback and error.protocol == Enumerable and
           Enum.any?(
             __STACKTRACE__,
             &match?({Assent.Strategy.OIDC, :validate_audience, 3, _}, &1)
           ) do
        EntraController.failure(conn, {:entra, :callback}, :invalid_audience)
      else
        reraise error, __STACKTRACE__
      end
  end
end
