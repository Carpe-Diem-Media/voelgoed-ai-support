defmodule VoelgoedAi.Feasibility.ChatwootFakeAdapter do
  @moduledoc false

  def run(request), do: Req.Request.get_private(request, :f06_adapter).(request)
end

defmodule VoelgoedAi.Feasibility.ChatwootDelivery do
  @moduledoc """
  Fixed reply and explicit handoff against a mandatory fake Req adapter.
  A delivery can claim a write once. Uncertain replies stay blocked in UNKNOWN.
  """
  alias VoelgoedAi.Feasibility.ChatwootFakeAdapter
  alias VoelgoedAi.Feasibility.ChatwootStore, as: Store

  @reply "This is the fixed F06 reply."
  @receive_timeout 500

  def decide(ctx, event_id) do
    case Store.event(ctx.prefix, event_id) do
      %{outcome: "dispatched", processed: false} = event ->
        operation =
          case {event.purpose, ctx.decision} do
            {"input", "reply"} -> :reply
            {"input", "handoff"} -> :handoff_input
            _ -> :observe
          end

        scope = Map.put(event, :deadline, Store.ingress_deadline(event))
        Store.decide(ctx, event_id, event, ownership(ctx, scope, operation))

      _ ->
        {:ok, :ok}
    end
  end

  def deliver(ctx, delivery_id) do
    case Store.delivery(ctx.prefix, delivery_id) do
      %{state: "pending"} = delivery ->
        operation = if delivery.kind == "reply", do: :reply, else: :handoff

        case Store.reserve_read(ctx, delivery, "pending") do
          {:ok, attempt} -> claim_and_write(ctx, delivery, operation, attempt)
          :unavailable -> Store.expire(ctx, delivery) |> job_result()
        end

      _ ->
        :ok
    end
  end

  defp claim_and_write(ctx, delivery, operation, read_attempt) do
    result = Store.claim(ctx, delivery, ownership(ctx, delivery, operation), read_attempt)

    case result do
      {:ok, {:send, generation}} ->
        case Store.authorize_dispatch(ctx, delivery, generation, @receive_timeout) do
          {:ok, {:allowed, expires_at}} ->
            result = write(ctx, delivery, expires_at)
            Store.settle(ctx, delivery, generation, result) |> job_result()

          result ->
            job_result(result)
        end

      {:ok, :retry_preflight} ->
        {:error, :handoff_preflight_unavailable}

      result ->
        job_result(result)
    end
  end

  @doc "Recheck an ambiguous handoff through a bounded GET, with no write claim."
  def reconcile(ctx, delivery_id) do
    with %{kind: "handoff", state: "unknown"} = delivery <-
           Store.delivery(ctx.prefix, delivery_id),
         {:ok, attempt} <- Store.reserve_read(ctx, delivery, "unknown") do
      Store.record_handoff_read(ctx, delivery, attempt, ownership(ctx, delivery, :observe))
      |> job_result()
    else
      _ -> :ok
    end
  end

  defp job_result({:ok, :retry_read}), do: {:error, :handoff_goal_unconfirmed}
  defp job_result({:ok, _}), do: :ok
  defp job_result({:error, _}), do: {:error, :delivery_rolled_back}

  defp ownership(ctx, scope, operation) do
    case request(ctx, scope, :get, "", []) do
      {:ok,
       %{
         status: 200,
         body:
           %{
             "account_id" => account,
             "inbox_id" => inbox,
             "id" => conversation,
             "meta" => %{"sender" => %{"id" => contact}}
           } = body
       }}
      when account === scope.account_id and inbox === scope.inbox_id and
             conversation === scope.conversation_id and contact === scope.contact_id ->
        classify(ctx, scope, body, operation)

      {:ok, %{status: status}} when status == 429 or status in 500..599 ->
        :transient_read_error

      {:error, %Req.TransportError{}} ->
        :transient_read_error

      _ ->
        :unknown
    end
  end

  defp classify(_ctx, _scope, %{"status" => "resolved"}, _operation), do: :closed
  defp classify(_ctx, _scope, %{"status" => "open"}, _operation), do: :human

  defp classify(
         _ctx,
         _scope,
         %{"meta" => %{"assignee_type" => "User", "assignee" => %{"id" => id}}},
         _operation
       )
       when is_integer(id) and id > 0, do: :human

  defp classify(
         ctx,
         scope,
         %{
           "status" => "pending",
           "meta" => %{"assignee_type" => "AgentBot", "assignee" => %{"id" => bot}}
         } = body,
         operation
       )
       when bot === ctx.bot_id and
              (operation != :reply or :erlang.map_get("can_reply", body) === true) do
    case body["last_non_activity_message"] do
      %{"id" => id} when id === scope.message_id -> :bot
      _ when operation in [:handoff, :observe] -> :bot
      _ -> :stale
    end
  end

  defp classify(_ctx, _scope, _body, _operation), do: :unknown

  defp write(ctx, %{kind: "reply"} = delivery, expires_at) do
    result =
      request(ctx, within_lease(delivery, expires_at), :post, "/messages",
        json: %{content: @reply, message_type: "outgoing", private: false}
      )

    case result do
      {:ok,
       %{
         status: status,
         body: %{
           "id" => id,
           "inbox_id" => inbox,
           "conversation_id" => conversation,
           "message_type" => 1,
           "private" => false,
           "sender" => %{"type" => "agent_bot", "id" => bot}
         }
       }}
      when status in 200..299 and inbox === delivery.inbox_id and
             conversation === delivery.conversation_id and bot === ctx.bot_id and
             is_integer(id) and id in 1..9_223_372_036_854_775_807 ->
        {"sent", "reply_confirmed", id}

      _ ->
        unresolved(result)
    end
  end

  defp write(ctx, %{kind: "handoff"} = delivery, expires_at) do
    scope = within_lease(delivery, expires_at)
    result = request(ctx, scope, :post, "/toggle_status", json: %{status: "open"})

    case result do
      {:ok, %{status: status, body: %{"payload" => %{"current_status" => "open"}}}}
      when status in 200..299 ->
        case Store.reserve_read(ctx, scope, "sending") do
          {:ok, attempt} -> {:handoff_read, attempt, ownership(ctx, scope, :observe)}
          :unavailable -> {"unknown", "handoff_unconfirmed", nil}
        end

      _ ->
        unresolved(result)
    end
  end

  defp within_lease(delivery, expires_at) do
    %{delivery | deadline: Enum.min([delivery.deadline, expires_at], DateTime)}
  end

  defp unresolved({:ok, %{status: 403}}), do: {"failed", "permission_rejected", nil}
  defp unresolved(_result), do: {"unknown", "write_unconfirmed", nil}

  defp request(%{adapter: adapter} = ctx, scope, method, suffix, options)
       when is_function(adapter, 1) do
    true =
      scope.installation == ctx.installation and scope.account_id == ctx.account_id and
        scope.inbox_id == ctx.inbox_id

    timeout = min(@receive_timeout, DateTime.diff(scope.deadline, ctx.now.(), :millisecond))

    if timeout > 0 do
      Req.new(
        [
          url:
            "https://chatwoot.invalid/api/v1/accounts/#{scope.account_id}/conversations/#{scope.conversation_id}#{suffix}",
          method: method,
          headers: [{"api_access_token", ctx.api_token}],
          adapter: ChatwootFakeAdapter,
          receive_timeout: timeout,
          request_timeout: timeout,
          retry: false,
          redirect: false
        ] ++ options
      )
      |> Req.Request.put_private(:f06_adapter, adapter)
      |> Req.request()
    else
      {:error, :request_deadline_exceeded}
    end
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootDeadlineJob do
  @moduledoc false
  use Oban.Worker, queue: :f06_deadline, max_attempts: 3
  alias VoelgoedAi.Feasibility.ChatwootDelivery
  alias VoelgoedAi.Feasibility.ChatwootStore, as: Store

  def crontab, do: [{"* * * * *", __MODULE__}]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, conf: conf}) do
    ctx = Process.get({ChatwootDelivery, conf.prefix})
    delivery = Store.delivery(ctx.prefix, id)
    now = ctx.now.()

    if DateTime.before?(now, delivery.deadline) do
      {:snooze, DateTime.diff(delivery.deadline, now) + 1}
    else
      case Store.expire(ctx, delivery) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :deadline_rolled_back}
      end
    end
  end

  def perform(%Oban.Job{args: args, conf: conf}) when map_size(args) == 0 do
    Store.sweep_deadlines(Process.get({ChatwootDelivery, conf.prefix}))
    :ok
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootReconcileJob do
  @moduledoc false
  use Oban.Worker, queue: :f06_reconcile, max_attempts: 3
  alias VoelgoedAi.Feasibility.ChatwootDelivery

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 2 * attempt - 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, conf: conf}) do
    ChatwootDelivery.reconcile(Process.get({ChatwootDelivery, conf.prefix}), id)
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootRecoveryJob do
  @moduledoc false
  use Oban.Worker, queue: :f06_recovery, max_attempts: 3
  alias VoelgoedAi.Feasibility.ChatwootDelivery
  alias VoelgoedAi.Feasibility.ChatwootStore, as: Store

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, conf: conf}) do
    ctx = Process.get({ChatwootDelivery, conf.prefix})
    delivery = Store.delivery(ctx.prefix, id)

    case Store.recover(ctx, delivery) do
      {:ok, {:snooze, seconds}} -> {:snooze, seconds}
      {:ok, _} -> :ok
      {:error, _} -> {:error, :recovery_rolled_back}
    end
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootIngressJob do
  @moduledoc false
  use Oban.Worker, queue: :f06_ingress, max_attempts: 1
  alias VoelgoedAi.Feasibility.ChatwootDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}, conf: conf}) do
    ctx = Process.get({ChatwootDelivery, conf.prefix})

    case ChatwootDelivery.decide(ctx, id) do
      {:ok, :ok} -> :ok
      {:error, _reason} -> {:error, :decision_rolled_back}
    end
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootDeliveryJob do
  @moduledoc false
  use Oban.Worker, queue: :f06_delivery, max_attempts: 1
  alias VoelgoedAi.Feasibility.ChatwootDelivery

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 2 * attempt - 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, conf: conf}) do
    ctx = Process.get({ChatwootDelivery, conf.prefix})
    ChatwootDelivery.deliver(ctx, id)
  end
end
