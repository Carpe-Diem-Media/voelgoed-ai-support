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

  def decide(ctx, event_id) do
    event = Store.event(ctx.prefix, event_id)
    Store.decide(ctx, event_id, event, ownership(ctx, event, event.purpose == "input"))
  end

  def deliver(ctx, delivery_id) do
    case Store.delivery(ctx.prefix, delivery_id) do
      %{state: "pending"} = delivery ->
        ownership = ownership(ctx, delivery, delivery.kind == "reply")

        case Store.claim(ctx, delivery, ownership) do
          {:ok, {:send, generation}} ->
            result = write(ctx, delivery)
            Store.settle(ctx, delivery, generation, result)

          {:ok, _no_write} ->
            :ok
        end

      %{state: "sending"} = delivery ->
        Store.recover(ctx, delivery)

      _ ->
        :ok
    end
  end

  def reconcile(ctx, delivery_id) do
    delivery = Store.delivery(ctx.prefix, delivery_id)
    Store.reconcile(ctx, delivery, ownership(ctx, delivery, false))
  end

  defp ownership(ctx, scope, check_message?) do
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
        classify(ctx, scope, body, check_message?)

      _ ->
        :unknown
    end
  end

  defp classify(_ctx, _scope, %{"status" => "resolved"}, _check_message?), do: :closed
  defp classify(_ctx, _scope, %{"status" => "open"}, _check_message?), do: :human

  defp classify(
         _ctx,
         _scope,
         %{"status" => "pending", "meta" => %{"assignee" => %{"type" => "user", "id" => id}}},
         _check_message?
       )
       when is_integer(id) and id > 0, do: :human

  defp classify(
         ctx,
         scope,
         %{
           "status" => "pending",
           "can_reply" => true,
           "meta" => %{"assignee" => %{"type" => "agent_bot", "id" => bot}}
         } = body,
         check_message?
       )
       when bot === ctx.bot_id do
    case body["last_non_activity_message"] do
      %{"id" => id} when id === scope.message_id -> :bot
      _ when not check_message? -> :bot
      _ -> :stale
    end
  end

  defp classify(_ctx, _scope, _body, _check_message?), do: :unknown

  defp write(ctx, %{kind: "reply"} = delivery) do
    result =
      request(ctx, delivery, :post, "/messages",
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

  defp write(ctx, %{kind: "handoff"} = delivery) do
    result = request(ctx, delivery, :post, "/toggle_status", json: %{status: "open"})

    case result do
      {:ok, %{status: status, body: %{"payload" => %{"current_status" => "open"}}}}
      when status in 200..299 ->
        if ownership(ctx, delivery, false) == :human do
          {"sent", "handoff_confirmed", nil}
        else
          {"unknown", "handoff_unconfirmed", nil}
        end

      _ ->
        unresolved(result)
    end
  end

  defp unresolved({:ok, %{status: 403}}), do: {"failed", "permission_rejected", nil}
  defp unresolved(_result), do: {"unknown", "write_unconfirmed", nil}

  defp request(%{adapter: adapter} = ctx, scope, method, suffix, options)
       when is_function(adapter, 1) do
    true =
      scope.installation == ctx.installation and scope.account_id == ctx.account_id and
        scope.inbox_id == ctx.inbox_id

    Req.new(
      [
        url:
          "https://chatwoot.invalid/api/v1/accounts/#{scope.account_id}/conversations/#{scope.conversation_id}#{suffix}",
        method: method,
        headers: [{"api_access_token", ctx.api_token}],
        adapter: ChatwootFakeAdapter,
        receive_timeout: 500,
        retry: false,
        redirect: false
      ] ++ options
    )
    |> Req.Request.put_private(:f06_adapter, adapter)
    |> Req.request()
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
  def perform(%Oban.Job{args: %{"delivery_id" => id}, conf: conf}) do
    ctx = Process.get({ChatwootDelivery, conf.prefix})
    ChatwootDelivery.deliver(ctx, id)
    :ok
  end
end
