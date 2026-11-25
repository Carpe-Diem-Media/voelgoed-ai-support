defmodule VoelgoedAi.ChatwootFeasibilityTest do
  use ExUnit.Case, async: false
  import Ecto.Query, only: [where: 3]
  import Phoenix.ConnTest, only: [build_conn: 0, dispatch: 5]
  import Plug.Conn

  alias VoelgoedAi.Feasibility.{
    ChatwootDeadlineJob,
    ChatwootDelivery,
    ChatwootDeliveryJob,
    ChatwootEndpoint,
    ChatwootIngressJob,
    ChatwootStore
  }

  alias VoelgoedAi.Repo

  @now ~U[2026-11-25 10:00:00Z]
  @body """
  {
    "event": "message_created",
    "id": 101,
    "account": {"id": 1},
    "inbox": {"id": 2},
    "conversation": {
      "id": 3, "account": {"id": 1}, "inbox_id": 2,
      "meta": {"sender": {"id": 4}}, "messages": [{"id": 999}]
    },
    "sender": {"id": 4, "account": {"id": 1}},
    "message_type": "incoming",
    "content_type": "text", "private": false, "content": "Synthetic input",
    "attachments": []
  }
  """
  @path "/api/v1/accounts/1/conversations/3"

  setup_all do
    Application.put_env(:voelgoed_ai, ChatwootEndpoint, server: false)
    on_exit(fn -> Application.delete_env(:voelgoed_ai, ChatwootEndpoint) end)
    :ok
  end

  setup do
    prefix = ChatwootStore.new_prefix()
    ChatwootStore.create!(prefix)
    on_exit(fn -> ChatwootStore.drop!(prefix) end)
    ChatwootStore.migrate!(prefix)

    oban = {__MODULE__, prefix}

    start_supervised!(
      {Oban,
       name: oban,
       repo: Repo,
       prefix: prefix,
       testing: :manual,
       notifier: Oban.Notifiers.PG,
       log: false}
    )

    start_supervised!({ChatwootEndpoint, server: false})

    %{
      prefix: prefix,
      oban: oban,
      now: fn -> @now end,
      installation: "synthetic",
      signing_key: :crypto.strong_rand_bytes(32),
      api_token: Base.encode64(:crypto.strong_rand_bytes(32)),
      account_id: 1,
      inbox_id: 2,
      bot_id: 5,
      decision: "reply"
    }
  end

  test "the TEST role can migrate Oban into a fresh spike schema", ctx do
    assert counts(ctx) == [0, 0, 0, 0]
  end

  test "the independent backend sees both inserts only before the committed 204 is sent", ctx do
    parent = self()

    blocked =
      Map.put(ctx, :after_receipt_enqueue, fn -> transaction_barrier(parent, :enqueued) end)

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          submit(blocked, before_send: fn -> barrier(parent, :sending_ack) end)
        end)
      end)

    assert_receive {:enqueued, worker, writer_backend}, 5_000

    Repo.checkout(fn ->
      refute backend() == writer_backend
      assert counts(ctx) == [0, 0, 0, 0]
      assert Task.yield(task, 0) == nil
      send(worker, {:release, :enqueued, :ok})

      assert_receive {:sending_ack, ^worker, ^writer_backend}, 5_000
      assert counts(ctx) == [1, 1, 0, 0]
      assert Task.yield(task, 0) == nil
    end)

    send(worker, {:release, :sending_ack, :ok})
    assert Task.await(task).status == 204
    assert_one_ingress_job(ctx)
  end

  test "two signed deliveries contend on a message key and acknowledge one committed job", ctx do
    parent = self()

    winner = Map.put(ctx, :after_receipt_enqueue, fn -> transaction_barrier(parent, :winner) end)
    loser = Map.put(ctx, :before_receipt, fn -> transaction_barrier(parent, :loser) end)

    first = Task.async(fn -> Repo.checkout(fn -> submit(winner, delivery: "first") end) end)
    assert_receive {:winner, first_pid, first_backend}, 5_000

    second =
      Task.async(fn ->
        Repo.checkout(fn -> submit(loser, delivery: "second", offset: 1) end)
      end)

    assert_receive {:loser, second_pid, second_backend}, 5_000
    refute first_backend == second_backend
    send(second_pid, {:release, :loser, :ok})
    assert_blocked_by(second_backend, first_backend)

    assert counts(ctx) == [0, 0, 0, 0]
    assert Task.yield(second, 0) == nil
    send(first_pid, {:release, :winner, :ok})
    assert [%{status: 204}, %{status: 204}] = Task.await_many([first, second], 5_000)

    assert submit(ctx, delivery: "replay").status == 204
    assert submit(ctx, offset: -301).status == 401
    assert_one_ingress_job(ctx)
  end

  test "rolling back after enqueue returns 500 and a new signed delivery can commit", ctx do
    parent = self()

    blocked =
      Map.put(ctx, :after_receipt_enqueue, fn -> transaction_barrier(parent, :rollback) end)

    task = Task.async(fn -> submit(blocked) end)
    assert_receive {:rollback, worker, writer_backend}, 5_000

    Repo.checkout(fn ->
      refute backend() == writer_backend
      assert counts(ctx) == [0, 0, 0, 0]
    end)

    send(worker, {:release, :rollback, :rollback})
    assert Task.await(task).status == 500
    assert counts(ctx) == [0, 0, 0, 0]
    assert submit(ctx, delivery: "retry").status == 204
    assert_one_ingress_job(ctx)
  end

  test "a database rejection of the Oban insert rolls the receipt back", ctx do
    sql!(ctx, "ALTER TABLE @schema.oban_jobs ADD CHECK (queue <> 'f06_ingress')")
    assert submit(ctx).status == 500
    assert counts(ctx) == [0, 0, 0, 0]
  end

  test "signature covers literal JSON bytes and one fresh timestamp", ctx do
    unsigned = [
      [key: :crypto.strong_rand_bytes(32)],
      [installation: "unknown"],
      [headers: &List.delete_at(&1, 0)],
      [headers: &List.delete_at(&1, 1)],
      [headers: &[hd(&1) | &1]],
      [headers: &[Enum.at(&1, 1) | &1]],
      [
        headers: &List.keyreplace(&1, "x-chatwoot-timestamp", 0, {"x-chatwoot-timestamp", "123x"})
      ],
      [
        headers:
          &List.keyreplace(&1, "x-chatwoot-signature", 0, {"x-chatwoot-signature", "sha256=0"})
      ],
      [body: String.trim(@body), signed_body: @body],
      [body: "{", key: :crypto.strong_rand_bytes(32)],
      [offset: -301],
      [offset: 301]
    ]

    for opts <- unsigned, do: assert(submit(ctx, opts).status == 401)
    assert counts(ctx) == [0, 0, 0, 0]
    assert submit(ctx, offset: -300).status == 204
    assert submit(ctx, offset: 300, body: payload(%{"id" => 102})).status == 204
    assert counts(ctx) == [2, 2, 0, 0]
  end

  test "body and account/inbox scope are bounded before receipt", ctx do
    assert submit(ctx, body: "{").status == 400
    assert submit(ctx, body: "[]").status == 400
    assert submit(ctx, content_type: "text/plain").status == 415
    assert submit(ctx, body: String.duplicate(" ", 65_537)).status == 413
    assert submit(ctx, body: payload(%{"id" => 0})).status == 400

    for changes <- [
          %{"account" => %{"id" => 9}},
          %{"inbox" => %{"id" => 9}},
          %{"conversation" => conversation(%{"account" => %{"id" => 9}})},
          %{"conversation" => conversation(%{"inbox_id" => 9})}
        ] do
      assert submit(ctx, body: payload(changes)).status == 403
    end

    assert counts(ctx) == [0, 0, 0, 0]
    assert submit(ctx).status == 204
    assert_one_ingress_job(ctx)
  end

  test "ineligible events acknowledge without queueing", ctx do
    events = [
      %{"event" => "unknown"},
      %{"message_type" => "activity"},
      %{"message_type" => "outgoing", "sender" => %{"type" => "agent_bot", "id" => 5}},
      %{
        "message_type" => "outgoing",
        "private" => true,
        "sender" => %{"type" => "user", "id" => 6}
      },
      %{"private" => true},
      %{"attachments" => [%{"id" => 1}]},
      %{"sender" => %{"id" => 9, "account" => %{"id" => 1}}},
      %{"content" => "  "}
    ]

    for {changes, id} <- Enum.with_index(events, 110) do
      assert submit(ctx, body: payload(Map.put(changes, "id", id))).status == 204
    end

    assert counts(ctx) == [8, 0, 0, 0]

    assert %{rows: [["ignored", 8]]} =
             sql!(ctx, "SELECT outcome, count(*) FROM @schema.inbound_events GROUP BY outcome")
  end

  test "the committed Oban jobs decide, claim, then POST one fixed reply", ctx do
    ctx = fake(ctx, [get(pending()), get(pending()), reply(response(200, reply_body()))])

    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    assert counts(ctx) == [1, 3, 1, 1]
    id = intent_id(ctx)
    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "sent", generation: 1, attempts: 1, external_message_id: 700} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert :ok == ChatwootDelivery.deliver(ctx, id)
    assert drain(ctx, :f06_recovery, with_scheduled: DateTime.add(@now, 5)).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get, :reply])
  end

  test "handoff commits the inhibit before the explicit open and confirms with a fresh GET",
       ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
        get(pending(%{"status" => "open"})),
        get(pending())
      ])

    id = prepare(ctx)
    assert %{state: "handoff_pending", epoch: 2} = session(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "sent", reason: "handoff_confirmed"} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "human_active", epoch: 3} = session(ctx)

    assert submit(ctx, body: payload(%{"id" => 102})).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    assert counts(ctx) == [2, 5, 1, 1]
    assert %{state: "human_active", epoch: 3} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get, :get])
  end

  test "a rollback after staging handoff undoes the inhibit, intent, and enqueue", ctx do
    current = pending(%{"last_non_activity_message" => %{"id" => 102}})
    ctx = fake(ctx, [get(pending()), get(current), get(current)])
    id = prepare(ctx)
    assert %{state: "bot_active", epoch: 1} = session(ctx)

    assert %{state: "pending"} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{active_event: active} = session(ctx)
    assert submit(ctx, body: payload(%{"id" => 102})).status == 204

    ctx = Map.merge(ctx, %{decision: "handoff", after_decision_enqueue: fn -> :rollback end})
    assert drain(ctx, :f06_ingress).discard == 1
    assert %{state: "bot_active", epoch: 1, active_event: ^active} = session(ctx)
    assert %{state: "pending"} = ChatwootStore.delivery(ctx.prefix, id)
    assert counts(ctx) == [2, 4, 1, 1]

    assert %{rows: [[false, nil]]} =
             sql!(
               ctx,
               "SELECT processed, decision FROM @schema.inbound_events WHERE message_id = 102"
             )

    assert {:ok, :ok} =
             ChatwootDelivery.decide(Map.delete(ctx, :after_decision_enqueue), event_id(ctx, 102))

    assert %{state: "handoff_pending", epoch: 2} = session(ctx)
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "pending", kind: "handoff"} =
             ChatwootStore.delivery(ctx.prefix, intent_id(ctx, 102))

    assert counts(ctx) == [2, 6, 1, 2]
    assert_fake_calls(ctx, [:get, :get, :get])
  end

  for {label, body, expected_state, reason} <- [
        {"missed takeover", %{"status" => "open"}, "human_active", "ownership_changed"},
        {"resolution", %{"status" => "resolved"}, "closed", "ownership_changed"},
        {"missed reassignment while pending",
         %{
           "meta" => %{
             "sender" => %{"id" => 4},
             "assignee_type" => "User",
             "assignee" => %{"id" => 6}
           }
         }, "human_active", "ownership_changed"},
        {"wrong account", %{"account_id" => 9}, "bot_active", "guard_denied"},
        {"wrong inbox", %{"inbox_id" => 9}, "bot_active", "guard_denied"},
        {"wrong conversation", %{"id" => 9}, "bot_active", "guard_denied"},
        {"wrong contact", %{"meta" => %{"sender" => %{"id" => 9}}}, "bot_active", "guard_denied"},
        {"reply disabled", %{"can_reply" => false}, "bot_active", "guard_denied"},
        {"wrong bot",
         %{
           "meta" => %{
             "sender" => %{"id" => 4},
             "assignee_type" => "AgentBot",
             "assignee" => %{"id" => 9}
           }
         }, "bot_active", "guard_denied"},
        {"newer input", %{"last_non_activity_message" => %{"id" => 102}}, "bot_active",
         "uncovered_input_review"}
      ] do
    test "the pre-write GET prevents a reply after #{label}", ctx do
      ctx = fake(ctx, [get(pending()), get(pending(unquote(Macro.escape(body))))])
      id = prepare(ctx)
      assert drain(ctx, :f06_delivery).success == 1
      assert %{state: unquote(expected_state)} = session(ctx)

      assert %{state: "cancelled", attempts: 0, reason: unquote(reason)} =
               ChatwootStore.delivery(ctx.prefix, id)

      assert_fake_calls(ctx, [:get, :get])
    end
  end

  test "a user assignment on the first customer input prevents a reply", ctx do
    human =
      pending(%{
        "meta" => %{
          "sender" => %{"id" => 4},
          "assignee_type" => "User",
          "assignee" => %{"id" => 6}
        }
      })

    ctx = fake(ctx, [get(human)])
    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    assert %{state: "human_active"} = session(ctx)
    assert counts(ctx) == [1, 1, 1, 0]
    assert_fake_calls(ctx, [:get])
  end

  for {status, expected_state} <- [
        {"pending", "bot_active"},
        {"open", "human_active"},
        {"resolved", "closed"},
        {"snoozed", "bot_active"}
      ] do
    test "an unassigned #{status} conversation cannot receive a reply", ctx do
      ctx = fake(ctx, [get(pending()), get(unassigned(unquote(status)))])
      id = prepare(ctx)
      assert drain(ctx, :f06_delivery).success == 1
      assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
      assert %{state: unquote(expected_state)} = session(ctx)
      assert_fake_calls(ctx, [:get, :get])
    end
  end

  for {label, type} <- [{"unrecognised", "Group"}, {"missing", nil}] do
    test "a pending conversation with #{label} assignee_type cannot receive a reply", ctx do
      remote = pending()
      meta = Map.delete(remote["meta"], "assignee_type")
      meta = if unquote(type), do: Map.put(meta, "assignee_type", unquote(type)), else: meta
      ctx = fake(ctx, [get(remote), get(%{remote | "meta" => meta})])
      id = prepare(ctx)
      assert drain(ctx, :f06_delivery).success == 1

      assert %{state: "cancelled", attempts: 0, reason: "guard_denied"} =
               ChatwootStore.delivery(ctx.prefix, id)

      assert_fake_calls(ctx, [:get, :get])
    end
  end

  test "an expired or fenced pending intent cannot send despite a qualified fresh read", ctx do
    ctx =
      fake(ctx, [
        get(pending()),
        get(pending()),
        get(pending(%{"last_non_activity_message" => %{"id" => 102}}))
      ])

    id = prepare(ctx)
    sql!(ctx, "UPDATE @schema.sessions SET epoch = epoch + 1")
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)

    assert submit(ctx, body: payload(%{"id" => 102})).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    id = intent_id(ctx, 102)
    assert drain(%{ctx | now: fn -> DateTime.add(@now, 45) end}, :f06_delivery).success == 1

    assert %{state: "cancelled", attempts: 0, reason: "reply_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert_fake_calls(ctx, [:get, :get, :get])
  end

  test "a public human reply fences pending work and reconciles current ownership", ctx do
    ctx = fake(ctx, [get(pending()), get(pending(%{"status" => "open"}))])
    id = prepare(ctx)

    event = %{
      "id" => 102,
      "message_type" => "outgoing",
      "sender" => %{"type" => "user", "id" => 6}
    }

    rollback = Map.put(ctx, :after_receipt_enqueue, fn -> :rollback end)
    assert submit(rollback, body: payload(event)).status == 500
    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "bot_active"} = session(ctx)

    assert submit(ctx, body: payload(event)).status == 204
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_ingress).success == 1
    assert %{state: "human_active"} = session(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get])
  end

  test "a signed public human reply inhibits before its job runs, despite bot ownership reads",
       ctx do
    ctx =
      fake(ctx, [
        get(pending()),
        get(pending()),
        get(pending()),
        reply(response(200, reply_body()))
      ])

    outbound =
      payload(%{
        "id" => 100,
        "message_type" => "outgoing",
        "sender" => %{"type" => "user", "id" => 6}
      })

    assert submit(ctx, body: outbound).status == 204
    inhibited_at_ack = session(ctx)
    assert drain(ctx, :f06_ingress).success == 1
    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    drain(ctx, :f06_delivery)

    {_remaining, calls} = Agent.get(ctx.fake_agent, & &1)
    assert Enum.reverse(calls) == [:get, :get]
    assert %{state: "human_active", epoch: 1} = inhibited_at_ack
    assert %{state: "human_active", epoch: 1} = session(ctx)
    assert counts(ctx) == [2, 2, 1, 0]
  end

  for replay? <- [false, true] do
    test "first human observation stays sticky (replay: #{replay?})", ctx do
      replay? = unquote(replay?)
      script = [get(unassigned("open")), get(pending())]
      ctx = fake(ctx, script)

      outbound =
        payload(%{
          "id" => 100,
          "message_type" => "outgoing",
          "sender" => %{"type" => "user", "id" => 6}
        })

      assert submit(ctx, body: outbound).status == 204
      assert drain(ctx, :f06_ingress).success == 1

      if replay? do
        assert submit(ctx, body: outbound).status == 204
        assert [1, 1, _, 0] = counts(ctx)
        assert {:ok, :ok} = ChatwootDelivery.decide(ctx, event_id(ctx, 100))
      end

      assert submit(ctx).status == 204
      assert drain(ctx, :f06_ingress).success == 1
      assert counts(ctx) == [2, 2, 1, 0]
      assert drain(ctx, :f06_delivery).success == 0
      assert %{state: "human_active", epoch: 1} = session(ctx)
      assert_fake_calls(ctx, List.duplicate(:get, length(script)))
    end
  end

  test "a handoff can still send after the 45 second reply deadline", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
        get(unassigned("open"))
      ])

    id = prepare(ctx)
    assert drain(%{ctx | now: fn -> DateTime.add(@now, 46) end}, :f06_delivery).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  test "at the handoff recovery deadline an unsent intent fails and stays inhibited", ctx do
    later_input = pending(%{"last_non_activity_message" => %{"id" => 102}})
    timeout = {:get, @path, write_result(:timeout)}
    ctx = fake(%{ctx | decision: "handoff"}, [get(pending()), timeout, get(later_input)])
    id = prepare(ctx)
    expired = %{ctx | now: fn -> DateTime.add(@now, 300) end}

    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(expired, :f06_delivery, with_scheduled: true).success == 1

    assert %{
             state: "failed",
             attempts: 0,
             reason: "handoff_deadline_exceeded",
             finished_at: %DateTime{}
           } =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending", active_event: nil} = session(ctx)
    assert :ok = ChatwootDelivery.deliver(expired, id)
    assert submit(expired, body: payload(%{"id" => 102})).status == 204
    assert drain(%{expired | decision: "reply"}, :f06_ingress).success == 1
    assert counts(ctx) == [2, 4, 1, 1]
    assert_fake_calls(ctx, [:get, :get, :get])
  end

  test "handoff exhausts three safe preflight attempts without issuing a status POST", ctx do
    timeout = {:get, @path, write_result(:timeout)}
    ctx = fake(%{ctx | decision: "handoff"}, [get(pending()), timeout, timeout, timeout])
    id = prepare(ctx)

    assert drain(ctx, :f06_delivery).failure == 1
    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_delivery, with_scheduled: true).failure == 1
    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_delivery, with_scheduled: true).success == 1

    assert %{state: "failed", attempts: 0, reason: "handoff_preflight_exhausted"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending", active_event: nil} = session(ctx)
    assert :ok = ChatwootDelivery.deliver(ctx, id)
    assert_fake_calls(ctx, [:get, :get, :get, :get])
  end

  test "handoff can claim its first write after a safe preflight retry", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        {:get, @path, write_result(:timeout)},
        get(pending()),
        handoff(write_result(:timeout))
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).success == 1
    assert %{state: "unknown", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert :ok = ChatwootDelivery.deliver(ctx, id)
    assert_fake_calls(ctx, [:get, :get, :get, :handoff])
  end

  test "closing the public reply window after admission still permits an explicit handoff", ctx do
    blocked = pending(%{"can_reply" => false})

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(blocked),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
        get(unassigned("open"))
      ])

    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, intent_id(ctx))
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  for status <- [429, 503] do
    test "handoff retries a pre-write HTTP #{status} inside its own deadline", ctx do
      ctx =
        fake(%{ctx | decision: "handoff"}, [
          get(pending()),
          {:get, @path, response(unquote(status), %{})},
          get(pending()),
          handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
          get(unassigned("open"))
        ])

      id = prepare(ctx)
      advanced = %{ctx | now: fn -> DateTime.add(@now, 46) end}
      assert drain(advanced, :f06_delivery).failure == 1
      assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
      assert drain(advanced, :f06_delivery, with_scheduled: true).success == 1
      assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
      assert_fake_calls(ctx, [:get, :get, :get, :handoff, :get])
    end
  end

  test "unknown handoff assignment fails closed without issuing a status POST", ctx do
    ctx = fake(%{ctx | decision: "handoff"}, [get(pending()), get(unassigned("pending"))])
    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "failed", attempts: 0, reason: "handoff_ownership_unverified"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get])
  end

  test "already human-owned handoff confirms locally and a resolved record stays closed", ctx do
    for {status, outcome, state} <- [
          {"open", "sent", "human_active"},
          {"resolved", "cancelled", "closed"}
        ],
        id_offset = if(status == "open", do: 0, else: 1) do
      display = 3 + id_offset
      message = 101 + id_offset
      remote = %{"id" => display, "last_non_activity_message" => %{"id" => message}}
      path = "/api/v1/accounts/1/conversations/#{display}"

      ctx =
        fake(%{ctx | decision: "handoff"}, [
          get(pending(remote), path),
          get(pending(Map.put(remote, "status", status)), path)
        ])

      assert submit(ctx,
               body:
                 payload(%{"id" => message, "conversation" => conversation(%{"id" => display})})
             ).status == 204

      assert drain(ctx, :f06_ingress).success == 1
      assert drain(ctx, :f06_delivery).success == 1

      assert %{state: ^outcome, attempts: 0} =
               ChatwootStore.delivery(ctx.prefix, intent_id(ctx, message))

      assert %{state: ^state} = session(ctx, display)
      assert_fake_calls(ctx, [:get, :get])
    end
  end

  test "a simulated remote commit followed by a timeout remains UNKNOWN", ctx do
    parent = self()

    accepted = fn request ->
      send(parent, :remote_committed)
      write_result(:timeout).(request)
    end

    ctx = fake(ctx, [get(pending()), get(pending()), reply(accepted)])
    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert_receive :remote_committed

    assert %{state: "unknown", attempts: 1, external_message_id: nil} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert :ok == ChatwootDelivery.deliver(ctx, id)
    assert_fake_calls(ctx, [:get, :get, :reply])
  end

  test "a timed-out ownership GET denies the write", ctx do
    ctx = fake(ctx, [get(pending()), {:get, @path, write_result(:timeout)}])
    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get])
  end

  test "a status response alone cannot confirm handoff after a failed read-back", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
        {:get, @path, write_result(:timeout)}
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "unknown", reason: "handoff_unconfirmed", attempts: 1} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending", epoch: 2} = session(ctx)
    assert :ok == ChatwootDelivery.deliver(ctx, id)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  for {label, failure, state} <- [
        {"remote disconnect", :closed, "unknown"},
        {"ambiguous 503", 503, "unknown"},
        {"redirect", 307, "unknown"},
        {"malformed success", 200, "unknown"},
        {"explicit permission refusal", 403, "failed"}
      ] do
    test "#{label} enters the reply adapter only once", ctx do
      ctx = fake(ctx, [get(pending()), get(pending()), reply(write_result(unquote(failure)))])
      id = prepare(ctx)
      assert drain(ctx, :f06_delivery).success == 1

      assert %{state: unquote(state), attempts: 1, external_message_id: nil} =
               ChatwootStore.delivery(ctx.prefix, id)

      assert :ok == ChatwootDelivery.deliver(ctx, id)
      assert_fake_calls(ctx, [:get, :get, :reply])
    end
  end

  test "a lost executing Oban reply is rescued and its expired claim becomes UNKNOWN without resending",
       ctx do
    parent = self()

    crashed = fn _request ->
      send(parent, :synthetic_remote_commit)
      Process.exit(self(), :kill)
    end

    ctx =
      fake(ctx, [
        get(pending()),
        get(pending()),
        reply(crashed),
        get(pending(%{"last_non_activity_message" => %{"id" => 102}}))
      ])

    id = prepare(ctx)
    {pid, ref} = spawn_monitor(fn -> drain(ctx, :f06_delivery) end)
    assert_receive :synthetic_remote_commit, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert %{state: "sending"} = ChatwootStore.delivery(ctx.prefix, id)

    assert %{rows: [[job_id, "executing", 1, 1]]} =
             sql!(
               ctx,
               "SELECT id, state, attempt, max_attempts FROM @schema.oban_jobs WHERE queue = 'f06_delivery'"
             )

    assert {:ok, [%{id: ^job_id, state: "discarded"}]} =
             Oban.Engine.rescue_jobs(Oban.config(ctx.oban), Oban.Job, rescue_after: 0)

    assert drain(ctx, :f06_recovery, with_scheduled: DateTime.add(@now, 4)).success == 0
    assert %{state: "sending"} = ChatwootStore.delivery(ctx.prefix, id)

    advanced = %{ctx | now: fn -> DateTime.add(@now, 5) end}
    assert drain(advanced, :f06_delivery).success == 0
    drain(advanced, :f06_recovery, with_scheduled: advanced.now.())

    assert %{state: "unknown", attempts: 1, reason: "claim_expired"} =
             ChatwootStore.delivery(ctx.prefix, id)

    insert_reconciliation(ctx, id)
    assert drain(advanced, :f06_reconcile).success == 1
    assert :ok == ChatwootDelivery.deliver(advanced, id)
    assert {:ok, :ok} = ChatwootDelivery.decide(advanced, event_id(ctx, 101))
    assert submit(ctx, body: payload(%{"id" => 102})).status == 204
    assert drain(advanced, :f06_ingress).success == 1
    assert %{state: "unknown", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert counts(ctx) == [2, 6, 1, 1]
    assert_fake_calls(ctx, [:get, :get, :reply, :get])
  end

  test "handoff timeout stays inhibited until a read confirms the goal after the reply deadline",
       ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(write_result(:timeout)),
        get(pending(%{"status" => "open"}))
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "unknown", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "handoff_pending"} = session(ctx)
    assert :ok == ChatwootDelivery.deliver(ctx, id)
    advanced = %{ctx | now: fn -> DateTime.add(@now, 46) end}
    assert drain(advanced, :f06_reconcile, with_scheduled: true).success == 1

    assert %{state: "sent", attempts: 1, reason: "goal_observed"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "a discarded reply preflight releases the active slot at the deadline", ctx do
    ctx = fake(ctx, [get(pending()), {:get, @path, &kill_worker/1}])
    id = prepare(ctx)
    assert %{state: "discarded", attempt: 1} = kill_and_rescue(ctx, :f06_delivery)

    insert_delivery(ctx, id)
    assert drain(at(ctx, 1), :f06_delivery).success == 1
    assert %{state: "pending", read_attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)

    assert drain(at(ctx, 44), :f06_deadline, with_scheduled: at(ctx, 44).now.()).success == 0
    assert %{state: "pending"} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(at(ctx, 45), :f06_deadline, with_scheduled: true).success == 1

    assert %{state: "cancelled", reason: "reply_deadline_exceeded", attempts: 0} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "bot_active", active_event: nil} = session(ctx)
    insert_delivery(ctx, id)
    assert drain(at(ctx, 46), :f06_delivery).success == 1
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_review
  test "Oban discards the third lost handoff preflight and the deadline records failure", ctx do
    timeout = {:get, @path, write_result(:timeout)}

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        timeout,
        timeout,
        {:get, @path, &kill_worker/1}
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).failure == 1

    assert %{state: "discarded", attempt: 3} =
             kill_and_rescue(ctx, :f06_delivery, with_scheduled: true)

    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(at(ctx, 301), :f06_delivery, with_scheduled: true).success == 0
    assert drain(at(ctx, 301), :f06_deadline, with_scheduled: true).success == 1

    assert %{state: "failed", reason: "handoff_deadline_exceeded", attempts: 0} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending", active_event: nil} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :get, :get])
  end

  @tag :f06_review
  test "a replacement delivery shares all three handoff preflight reservations", ctx do
    timeout = {:get, @path, write_result(:timeout)}
    ctx = fake(%{ctx | decision: "handoff"}, [get(pending()), timeout, timeout, timeout])
    id = prepare(ctx)

    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).failure == 1
    insert_delivery(ctx, id)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "failed", read_attempts: 3, reason: "handoff_preflight_exhausted"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert drain(ctx, :f06_delivery, with_scheduled: true).success == 1
    assert_fake_calls(ctx, [:get, :get, :get, :get])
  end

  @tag :f06_review
  test "a concurrent duplicate cannot enter GET while the last preflight is in flight", ctx do
    parent = self()
    timeout = {:get, @path, write_result(:timeout)}

    third = fn request ->
      barrier(parent, :last_preflight)
      write_result(:timeout).(request)
    end

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        timeout,
        timeout,
        {:get, @path, third}
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).failure == 1
    job = Task.async(fn -> drain(ctx, :f06_delivery, with_scheduled: true) end)
    assert_receive {:last_preflight, worker, _backend}, 5_000
    assert %{state: "pending", read_attempts: 3} = ChatwootStore.delivery(ctx.prefix, id)
    insert_delivery(ctx, id)
    assert drain(ctx, :f06_delivery).success == 1
    send(worker, {:release, :last_preflight, :ok})
    assert Task.await(job).success == 1

    assert %{state: "failed", reason: "handoff_preflight_exhausted"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert_fake_calls(ctx, [:get, :get, :get, :get])
  end

  @tag :f06_review
  test "a replacement read-back shares the preflight budget and cannot confirm a wrong scope",
       ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(write_result(:timeout)),
        get(pending(%{"status" => "open", "account_id" => 2})),
        get(pending())
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert drain(ctx, :f06_reconcile, with_scheduled: true).failure == 1
    assert %{state: "unknown", read_attempts: 2} = ChatwootStore.delivery(ctx.prefix, id)

    insert_reconciliation(ctx, id)
    assert drain(ctx, :f06_reconcile).success == 1

    assert %{
             state: "unknown",
             read_attempts: 3,
             recovery_failure: "handoff_read_budget_exhausted"
           } =
             ChatwootStore.delivery(ctx.prefix, id)

    assert drain(ctx, :f06_reconcile, with_scheduled: true).success == 1
    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get, :get])
  end

  @tag :f06_review
  test "a lost reconciliation GET cannot be retried outside the original handoff window", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(write_result(:timeout)),
        {:get, @path, &kill_worker/1}
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{attempt: 1} = kill_and_rescue(ctx, :f06_reconcile, with_scheduled: true)
    assert drain(at(ctx, 300), :f06_reconcile, with_scheduled: true).success == 1
    assert drain(at(ctx, 300), :f06_deadline, with_scheduled: true).success == 1

    assert %{
             state: "unknown",
             read_attempts: 2,
             recovery_failure: "handoff_read_deadline_exceeded"
           } =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "lease recovery reads back a lost handoff POST and fences a duplicate write", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(&kill_worker/1),
        get(pending() |> put_in(["meta", "assignee_type"], "User"))
      ])

    id = prepare(ctx)
    assert %{attempt: 1} = kill_and_rescue(ctx, :f06_delivery)
    insert_delivery(ctx, id)
    assert drain(ctx, :f06_delivery).success >= 1
    assert drain(at(ctx, 5), :f06_recovery, with_scheduled: true).success == 1
    assert %{state: "unknown", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(at(ctx, 5), :f06_reconcile, with_scheduled: true).success == 1

    assert %{state: "sent", reason: "goal_observed", attempts: 1} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "Oban Cron sweeps a reply after Oban discards its delivery and deadline jobs", ctx do
    ctx = fake(ctx, [get(pending()), {:get, @path, &kill_worker/1}])
    id = prepare(ctx)
    assert %{state: "discarded"} = kill_and_rescue(ctx, :f06_delivery)
    discard_checks(ctx, :f06_deadline)
    assert %{state: "pending"} = ChatwootStore.delivery(ctx.prefix, id)

    tick_deadline_cron(ctx)
    assert drain(at(ctx, 60), :f06_deadline).success == 1

    assert %{state: "cancelled", reason: "reply_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert_fake_calls(ctx, [:get, :get])
  end

  for {label, queue, seconds} <- [{"lease", :f06_recovery, 5}, {"deadline", :f06_deadline, 45}] do
    @tag :f06_review
    test "#{label} recovery wins against a late reply POST response", ctx do
      parent = self()

      wait_for_recovery = fn request ->
        barrier(parent, :reply_post)
        response(200, reply_body()).(request)
      end

      ctx = fake(ctx, [get(pending()), get(pending()), reply(wait_for_recovery)])
      id = prepare(ctx)
      write = Task.async(fn -> drain(ctx, :f06_delivery) end)
      assert_receive {:reply_post, worker, _backend}, 5_000
      assert worker == write.pid
      insert_delivery(ctx, id)
      assert drain(ctx, :f06_delivery).success == 1

      if unquote(queue) == :f06_deadline, do: discard_checks(ctx, :f06_recovery)

      assert drain(at(ctx, unquote(seconds)), unquote(queue), with_scheduled: true).success == 1
      assert %{state: "unknown", reason: "claim_expired"} = ChatwootStore.delivery(ctx.prefix, id)
      send(worker, {:release, :reply_post, :ok})
      assert Task.await(write).success == 1

      assert %{state: "unknown", attempts: 1, external_message_id: nil} =
               ChatwootStore.delivery(ctx.prefix, id)

      assert_fake_calls(ctx, [:get, :get, :reply])
    end
  end

  @tag :f06_review
  test "a qualified read-back that returns at the deadline cannot confirm the handoff", ctx do
    clock = :atomics.new(1, [])

    late_open = fn request ->
      :atomics.put(clock, 1, 300)
      response(200, unassigned("open")).(request)
    end

    ctx =
      fake(
        %{ctx | decision: "handoff", now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end},
        [
          get(pending()),
          get(pending()),
          handoff(write_result(:timeout)),
          {:get, @path, late_open}
        ]
      )

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    :atomics.put(clock, 1, 299)
    assert drain(ctx, :f06_reconcile, with_scheduled: true).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_read_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "a handoff POST acceptance cannot spend a fourth read on immediate confirmation", ctx do
    timeout = {:get, @path, write_result(:timeout)}

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        timeout,
        timeout,
        get(pending()),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}}))
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).failure == 1
    assert drain(ctx, :f06_delivery, with_scheduled: true).success == 1
    assert drain(ctx, :f06_reconcile, with_scheduled: true).success == 0

    assert %{state: "unknown", attempts: 1, recovery_failure: "handoff_read_budget_exhausted"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :get, :get, :handoff])
  end

  @tag :f06_review
  test "a qualified handoff preflight that returns at the deadline cannot claim a POST", ctx do
    clock = :atomics.new(1, [])

    late_bot = fn request ->
      :atomics.put(clock, 1, 300)
      response(200, pending()).(request)
    end

    ctx =
      fake(
        %{ctx | decision: "handoff", now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end},
        [
          get(pending()),
          {:get, @path, late_bot}
        ]
      )

    id = prepare(ctx)
    :atomics.put(clock, 1, 299)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "failed", attempts: 0, reason: "handoff_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_review
  test "read-back stops when the qualified conversation is resolved and preserves UNKNOWN", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(write_result(:timeout)),
        get(unassigned("resolved"))
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert drain(ctx, :f06_reconcile, with_scheduled: true).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_conversation_closed"} =
             ChatwootStore.delivery(ctx.prefix, id)

    insert_reconciliation(ctx, id)
    assert drain(ctx, :f06_reconcile).success == 1
    assert %{state: "closed"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "a stale handoff write job leaves the remaining read to the recovery queue", ctx do
    parent = self()

    blocked_post = fn request ->
      barrier(parent, :handoff_post)
      response(200, %{"payload" => %{"current_status" => "open"}}).(request)
    end

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(blocked_post),
        get(unassigned("open"))
      ])

    id = prepare(ctx)
    write = Task.async(fn -> drain(ctx, :f06_delivery) end)
    assert_receive {:handoff_post, worker, _backend}, 5_000
    assert drain(at(ctx, 5), :f06_recovery, with_scheduled: true).success == 1
    send(worker, {:release, :handoff_post, :ok})
    assert Task.await(write).success == 1
    assert %{state: "unknown", read_attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)

    assert drain(at(ctx, 5), :f06_reconcile, with_scheduled: true).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_review
  test "immediate handoff confirmation cannot settle after the deadline", ctx do
    clock = :atomics.new(1, [])

    late_open = fn request ->
      :atomics.put(clock, 1, 300)
      response(200, unassigned("open")).(request)
    end

    ctx =
      fake(
        %{ctx | decision: "handoff", now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end},
        [
          get(pending()),
          get(pending()),
          handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
          {:get, @path, late_open}
        ]
      )

    id = prepare(ctx)
    :atomics.put(clock, 1, 299)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_read_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "handoff_pending"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  for {label, newer_finishes_first?} <- [
        {"a late older read cannot undo durable budget exhaustion", true},
        {"a newer reconciliation reservation fences an older result before either settles", false}
      ] do
    @tag :f06_followup
    test label, ctx do
      newer_finishes_first? = unquote(newer_finishes_first?)
      parent = self()

      older_open = fn request ->
        barrier(parent, :older_read)
        response(200, unassigned("open")).(request)
      end

      newer_unconfirmed = fn request ->
        barrier(parent, :newer_read)
        response(200, pending()).(request)
      end

      ctx =
        fake(%{ctx | decision: "handoff"}, [
          get(pending()),
          get(pending()),
          handoff(write_result(:timeout)),
          {:get, @path, older_open},
          {:get, @path, newer_unconfirmed}
        ])

      id = prepare(ctx)
      assert drain(ctx, :f06_delivery).success == 1
      older = Task.async(fn -> drain(ctx, :f06_reconcile, with_scheduled: true) end)
      assert_receive {:older_read, older_worker, _backend}, 5_000
      insert_reconciliation(ctx, id)
      newer = Task.async(fn -> drain(ctx, :f06_reconcile) end)
      assert_receive {:newer_read, newer_worker, _backend}, 5_000

      if newer_finishes_first? do
        send(newer_worker, {:release, :newer_read, :ok})
        assert Task.await(newer).success == 1
      end

      before = ChatwootStore.delivery(ctx.prefix, id)
      failure = if newer_finishes_first?, do: "handoff_read_budget_exhausted"
      assert %{state: "unknown", recovery_failure: ^failure} = before

      send(older_worker, {:release, :older_read, :ok})
      assert Task.await(older).success == 1
      assert ChatwootStore.delivery(ctx.prefix, id) == before

      unless newer_finishes_first? do
        send(newer_worker, {:release, :newer_read, :ok})
        assert Task.await(newer).success == 1
      end

      assert %{state: "unknown", recovery_failure: "handoff_read_budget_exhausted"} =
               ChatwootStore.delivery(ctx.prefix, id)

      assert %{state: "handoff_pending"} = session(ctx)
      assert_fake_calls(ctx, [:get, :get, :handoff, :get, :get])
    end
  end

  @tag :f06_followup
  test "a read waiting on PostgreSQL cannot enter HTTP after the delivery deadline", ctx do
    parent = self()
    clock = :atomics.new(1, [])

    ctx =
      fake(%{ctx | now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end}, [get(pending())])

    id = prepare(ctx)
    :atomics.put(clock, 1, 44)

    locker =
      Task.async(fn ->
        Repo.transaction(fn ->
          sql!(ctx, "SELECT id FROM @schema.deliveries WHERE id = $1::text::uuid FOR UPDATE", [id])

          transaction_barrier(parent, :delivery_locked)
        end)
      end)

    assert_receive {:delivery_locked, lock_worker, lock_backend}, 5_000

    delivery =
      Task.async(fn ->
        Repo.checkout(fn ->
          barrier(parent, :delivery_start)
          drain(ctx, :f06_delivery)
        end)
      end)

    assert_receive {:delivery_start, worker, worker_backend}, 5_000
    send(worker, {:release, :delivery_start, :ok})
    assert_blocked_by(worker_backend, lock_backend)
    :atomics.put(clock, 1, 45)
    send(lock_worker, {:release, :delivery_locked, :ok})

    assert {:ok, :ok} = Task.await(locker)
    assert Task.await(delivery).success == 1

    assert %{state: "cancelled", read_attempts: 0, reason: "reply_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert_fake_calls(ctx, [:get])
  end

  @tag :f06_followup
  test "a GET receive timeout is capped by the remaining deadline", ctx do
    close_to_deadline = fn request ->
      assert request.options.receive_timeout == 125
      assert request.options.request_timeout == 125
      write_result(:timeout).(request)
    end

    ctx = fake(ctx, [get(pending()), {:get, @path, close_to_deadline}])
    id = prepare(ctx)
    advanced = %{ctx | now: fn -> DateTime.add(@now, 44_875, :millisecond) end}
    assert drain(advanced, :f06_delivery).success == 1
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_followup
  test "immediate confirmation stops at qualified resolution and preserves UNKNOWN", ctx do
    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(response(200, %{"payload" => %{"current_status" => "open"}})),
        get(unassigned("resolved"))
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_conversation_closed"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "closed"} = session(ctx)
    insert_reconciliation(ctx, id)
    assert drain(ctx, :f06_reconcile, with_scheduled: true).success == 1
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  @tag :f06_followup
  test "a claim recovered at commit cannot enter the POST adapter", ctx do
    ctx = fake(ctx, [get(pending()), get(pending())])

    id = prepare(ctx)
    writer = pause_delivery_commit(ctx)
    assert_receive {:claim_committed, worker}, 5_000
    assert %{state: "sending"} = ChatwootStore.delivery(ctx.prefix, id)

    assert drain(at(ctx, 5), :f06_recovery, with_scheduled: true).success == 1
    assert %{state: "unknown", reason: "claim_expired"} = ChatwootStore.delivery(ctx.prefix, id)

    send(worker, :continue_f06_delivery)
    assert Task.await(writer).success == 1
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_followup
  test "an older handoff preflight cannot claim the write after a newer read begins", ctx do
    parent = self()

    paused = fn phase, result ->
      {:get, @path,
       fn request ->
         barrier(parent, phase)
         result.(request)
       end}
    end

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        paused.(:old_preflight, response(200, pending())),
        paused.(:new_preflight, response(200, unassigned("resolved")))
      ])

    id = prepare(ctx)
    older = Task.async(fn -> drain(ctx, :f06_delivery) end)
    assert_receive {:old_preflight, old_worker, _backend}, 5_000
    insert_delivery(ctx, id)
    newer = Task.async(fn -> drain(ctx, :f06_delivery) end)
    assert_receive {:new_preflight, new_worker, _backend}, 5_000

    send(old_worker, {:release, :old_preflight, :ok})
    assert Task.await(older).success == 1
    assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    send(new_worker, {:release, :new_preflight, :ok})
    assert Task.await(newer).success == 1

    assert %{state: "cancelled", read_attempts: 2} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "closed"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :get])
  end

  @tag :f06_followup
  test "a writer with less than a request timeout before lease expiry never enters POST", ctx do
    clock = :atomics.new(1, [])

    ctx =
      fake(%{ctx | now: fn -> DateTime.add(@now, :atomics.get(clock, 1), :millisecond) end}, [
        get(pending()),
        get(pending())
      ])

    id = prepare(ctx)
    writer = pause_delivery_commit(ctx)
    assert_receive {:claim_committed, worker}, 5_000
    :atomics.put(clock, 1, 4_501)
    send(worker, :continue_f06_delivery)
    assert Task.await(writer).success == 1

    assert drain(at(ctx, 5), :f06_recovery, with_scheduled: true).success == 1
    assert %{state: "unknown", reason: "claim_expired"} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_followup
  test "human takeover between claim commit and dispatch prevents a POST", ctx do
    ctx = fake(ctx, [get(pending()), get(pending()), get(unassigned("open"))])
    id = prepare(ctx)
    writer = pause_delivery_commit(ctx)
    assert_receive {:claim_committed, worker}, 5_000

    handover =
      payload(%{
        "id" => 102,
        "message_type" => "outgoing",
        "sender" => %{"type" => "user", "id" => 6}
      })

    assert submit(ctx, body: handover).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    send(worker, :continue_f06_delivery)
    assert Task.await(writer).success == 1

    assert drain(at(ctx, 5), :f06_recovery, with_scheduled: true).success == 1
    assert %{state: "unknown"} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :get])
  end

  @tag :f06_followup
  test "a reply result after its lease cannot settle before the recovery job runs", ctx do
    clock = :atomics.new(1, [])

    late_reply = fn request ->
      :atomics.put(clock, 1, 5)
      response(200, reply_body()).(request)
    end

    ctx =
      fake(%{ctx | now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end}, [
        get(pending()),
        get(pending()),
        reply(late_reply)
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "unknown", reason: "claim_expired"} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_recovery, with_scheduled: true).success == 1
    assert_fake_calls(ctx, [:get, :get, :reply])
  end

  @tag :f06_followup
  test "a deadline failure fences even the latest reconciliation result", ctx do
    parent = self()

    late_open = fn request ->
      barrier(parent, :latest_read)
      response(200, unassigned("open")).(request)
    end

    ctx =
      fake(%{ctx | decision: "handoff"}, [
        get(pending()),
        get(pending()),
        handoff(write_result(:timeout)),
        {:get, @path, late_open}
      ])

    id = prepare(ctx)
    assert drain(ctx, :f06_delivery).success == 1
    read = Task.async(fn -> drain(ctx, :f06_reconcile, with_scheduled: true) end)
    assert_receive {:latest_read, worker, _backend}, 5_000

    assert drain(at(ctx, 300), :f06_deadline, with_scheduled: true).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_read_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    send(worker, {:release, :latest_read, :ok})
    assert Task.await(read).success == 1

    assert %{state: "unknown", recovery_failure: "handoff_read_deadline_exceeded"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
  end

  defp pause_delivery_commit(ctx) do
    parent = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:voelgoed_ai, :repo, :query],
        &__MODULE__.pause_after_claim_commit/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Task.async(fn ->
      Process.put(:pause_f06_commit, true)
      drain(ctx, :f06_delivery)
    end)
  end

  @doc false
  def pause_after_claim_commit(_event, _measurements, %{query: "commit"}, parent) do
    if Process.get(:pause_f06_commit) && Process.get(:f06_claim_staged) do
      Process.delete(:pause_f06_commit)
      send(parent, {:claim_committed, self()})

      receive do
        :continue_f06_delivery -> :ok
      after
        5_000 -> raise "F06 claim commit barrier timed out"
      end
    end
  end

  def pause_after_claim_commit(_event, _measurements, %{query: query}, _parent) do
    if Process.get(:pause_f06_commit) && String.contains?(query, "generation = generation + 1"),
      do: Process.put(:f06_claim_staged, true)
  end

  @tag :f06_followup
  test "the deadline sweep records a discarded ingress receipt without sending a late reply",
       ctx do
    ctx = fake(ctx, [{:get, @path, &kill_worker/1}])
    assert submit(ctx).status == 204
    id = event_id(ctx, 101)
    assert %{state: "discarded"} = kill_and_rescue(ctx, :f06_ingress)
    assert submit(ctx, delivery: "replay").status == 204
    assert drain(at(ctx, 360), :f06_ingress).success == 0

    tick_deadline_cron(ctx)
    assert drain(at(ctx, 360), :f06_deadline).success == 1

    assert %{processed: true, decision: "ingress_deadline_exceeded"} =
             ChatwootStore.event(ctx.prefix, id)

    assert [1, 2, 0, 0] = counts(ctx)

    assert {:ok, _} = Oban.insert(ctx.oban, ChatwootIngressJob.new(%{"event_id" => id}))
    assert drain(at(ctx, 360), :f06_ingress).success == 1
    assert_fake_calls(ctx, [:get])
  end

  @tag :f06_followup
  test "an overdue first ingress job records the missed deadline without a GET", ctx do
    ctx = fake(ctx, [])
    assert submit(ctx).status == 204
    assert drain(at(ctx, 45), :f06_ingress).success == 1

    assert %{processed: true, decision: "ingress_deadline_exceeded"} =
             ChatwootStore.event(ctx.prefix, event_id(ctx, 101))

    assert [1, 1, 0, 0] = counts(ctx)
    assert_fake_calls(ctx, [])
  end

  @tag :f06_followup
  test "the deadline sweep wins over an ingress GET that returns after the deadline", ctx do
    parent = self()
    clock = :atomics.new(1, [])

    late_bot = fn request ->
      barrier(parent, :ingress_get)
      response(200, pending()).(request)
    end

    ctx =
      fake(%{ctx | now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end}, [
        {:get, @path, late_bot}
      ])

    assert submit(ctx).status == 204
    original = Task.async(fn -> drain(ctx, :f06_ingress) end)
    assert_receive {:ingress_get, worker, _backend}, 5_000
    :atomics.put(clock, 1, 45)
    tick_deadline_cron(ctx)
    assert drain(ctx, :f06_deadline).success == 1
    send(worker, {:release, :ingress_get, :ok})
    assert Task.await(original).success == 1

    assert %{processed: true, decision: "ingress_deadline_exceeded"} =
             ChatwootStore.event(ctx.prefix, event_id(ctx, 101))

    assert [1, 2, 0, 0] = counts(ctx)
    assert_fake_calls(ctx, [:get])
  end

  @tag :f06_followup
  test "an original ingress read returning at the deadline records an outcome without the sweep",
       ctx do
    clock = :atomics.new(1, [])

    late_bot = fn request ->
      :atomics.put(clock, 1, 45)
      response(200, pending()).(request)
    end

    ctx =
      fake(%{ctx | now: fn -> DateTime.add(@now, :atomics.get(clock, 1)) end}, [
        {:get, @path, late_bot}
      ])

    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1

    assert %{processed: true, decision: "ingress_deadline_exceeded"} =
             ChatwootStore.event(ctx.prefix, event_id(ctx, 101))

    assert [1, 1, 0, 0] = counts(ctx)
    assert_fake_calls(ctx, [:get])
  end

  @tag :f06_followup
  test "the sweep records a lost human observation and preserves its receipt-time inhibit", ctx do
    ctx = fake(ctx, [get(pending()), {:get, @path, &kill_worker/1}])
    id = prepare(ctx)

    handover =
      payload(%{
        "id" => 102,
        "message_type" => "outgoing",
        "sender" => %{"type" => "user", "id" => 6}
      })

    assert submit(ctx, body: handover).status == 204
    assert %{state: "human_active"} = session(ctx)
    assert %{state: "discarded"} = kill_and_rescue(ctx, :f06_ingress)
    tick_deadline_cron(ctx)
    assert drain(at(ctx, 45), :f06_deadline, with_scheduled: true).success == 2

    assert %{processed: true, decision: "ingress_deadline_exceeded"} =
             ChatwootStore.event(ctx.prefix, event_id(ctx, 102))

    assert drain(at(ctx, 45), :f06_delivery).success == 1
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get])
  end

  @tag :f06_followup
  test "a replacement ingress decision fences the original job's late observation", ctx do
    parent = self()

    late_resolved = fn request ->
      barrier(parent, :older_ingress)
      response(200, unassigned("resolved")).(request)
    end

    ctx =
      fake(ctx, [
        {:get, @path, late_resolved},
        get(pending()),
        get(pending()),
        reply(response(200, reply_body()))
      ])

    assert submit(ctx).status == 204
    event = event_id(ctx, 101)
    original = Task.async(fn -> drain(ctx, :f06_ingress) end)
    assert_receive {:older_ingress, worker, _backend}, 5_000

    assert {:ok, _} = Oban.insert(ctx.oban, ChatwootIngressJob.new(%{"event_id" => event}))
    assert drain(ctx, :f06_ingress).success == 1
    id = intent_id(ctx)

    send(worker, {:release, :older_ingress, :ok})
    assert Task.await(original).success == 1
    assert %{state: "bot_active"} = session(ctx)
    assert %{state: "pending"} = ChatwootStore.delivery(ctx.prefix, id)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get, :get, :reply])
  end

  @tag :f06_followup
  test "untrusted events cannot fence the active reply", ctx do
    ctx = fake(ctx, [get(pending()), get(pending()), reply(response(200, reply_body()))])
    id = prepare(ctx)
    active = session(ctx)

    outbound = %{
      "id" => 102,
      "message_type" => "outgoing",
      "sender" => %{"type" => "user", "id" => 6}
    }

    assert submit(ctx, body: payload(outbound), key: :crypto.strong_rand_bytes(32)).status == 401

    wrong_inbox =
      Map.merge(outbound, %{
        "inbox" => %{"id" => 9},
        "conversation" => conversation(%{"inbox_id" => 9})
      })

    assert submit(ctx, body: payload(wrong_inbox)).status == 403

    for {type, message_id} <- Enum.with_index(~w(agent_bot contact system), 103) do
      body = payload(%{outbound | "id" => message_id, "sender" => %{"type" => type, "id" => 6}})
      assert submit(ctx, body: body).status == 204
      assert drain(ctx, :f06_ingress).success == 0
      assert session(ctx) == active
      assert %{state: "pending", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    end

    assert drain(ctx, :f06_delivery).success == 1
    insert_delivery(ctx, id)
    assert drain(ctx, :f06_delivery).success == 1
    assert %{state: "sent", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get, :reply])
  end

  for {state, queue, script, expected, reason} <- [
        {"pending", :f06_delivery, [{:get, @path, :kill}], "failed", "handoff_deadline_exceeded"},
        {"sending", :f06_delivery,
         [
           {:get, @path, :bot},
           {:handoff, @path <> "/toggle_status", :kill}
         ], "unknown", "handoff_read_deadline_exceeded"},
        {"unknown", :f06_reconcile,
         [
           {:get, @path, :bot},
           {:handoff, @path <> "/toggle_status", :timeout},
           {:get, @path, :kill}
         ], "unknown", "handoff_read_deadline_exceeded"}
      ] do
    @tag :f06_followup
    test "Cron closes a handoff in #{state} after the individual deadline job is lost", ctx do
      state = unquote(state)
      queue = unquote(queue)
      expected = unquote(expected)
      reason = unquote(reason)

      script =
        for {kind, path, action} <- unquote(Macro.escape(script)) do
          case action do
            :bot -> get(pending(), path)
            :timeout -> {kind, path, write_result(:timeout)}
            :kill -> {kind, path, &kill_worker/1}
          end
        end

      ctx = fake(%{ctx | decision: "handoff"}, [get(pending()) | script])
      id = prepare(ctx)
      if state == "unknown", do: assert(drain(ctx, :f06_delivery).success == 1)
      assert %{state: "available"} = kill_and_rescue(ctx, queue, with_scheduled: true)
      assert %{state: ^state} = ChatwootStore.delivery(ctx.prefix, id)
      if state == "sending", do: discard_checks(ctx, :f06_recovery)
      discard_checks(ctx, :f06_deadline)

      tick_deadline_cron(ctx)
      assert drain(at(ctx, 300), :f06_deadline).success == 1
      assert %{state: ^expected} = delivery = ChatwootStore.delivery(ctx.prefix, id)
      assert reason in [delivery.reason, delivery.recovery_failure]
      assert %{state: "handoff_pending"} = session(ctx)
      assert drain(at(ctx, 300), queue, with_scheduled: true).success == 1
      assert_fake_calls(ctx, [:get | Enum.map(script, &elem(&1, 0))])
    end
  end

  defp tick_deadline_cron(ctx) do
    cron_name = {ChatwootDeadlineJob, ctx.prefix}

    start_supervised!(
      {Oban,
       name: cron_name,
       repo: Repo,
       prefix: ctx.prefix,
       queues: false,
       peer: Oban.Peers.Isolated,
       cron: [crontab: ChatwootDeadlineJob.crontab()],
       log: false}
      |> Supervisor.child_spec(id: cron_name)
    )

    cron = Oban.Registry.whereis(cron_name, {:plugin, Oban.Cron})
    send(cron, :evaluate)
    :sys.get_state(cron)

    assert %{rows: [[true]]} =
             sql!(
               ctx,
               "SELECT meta->'cron' FROM @schema.oban_jobs WHERE queue = 'f06_deadline' AND meta->'cron' = 'true'::jsonb"
             )
  end

  defp at(ctx, seconds), do: %{ctx | now: fn -> DateTime.add(@now, seconds) end}

  defp kill_worker(_request), do: Process.exit(self(), :kill)

  defp kill_and_rescue(ctx, queue, opts \\ []) do
    {pid, ref} = spawn_monitor(fn -> drain(ctx, queue, opts) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

    assert %{rows: [[id, attempt]]} =
             sql!(
               ctx,
               "SELECT id, attempt FROM @schema.oban_jobs WHERE queue = $1 AND state = 'executing'",
               [Atom.to_string(queue)]
             )

    lost = where(Oban.Job, [job], job.id == ^id)

    assert {:ok, [%{id: ^id} = job]} =
             Oban.Engine.rescue_jobs(Oban.config(ctx.oban), lost, rescue_after: 0)

    Map.put(job, :attempt, attempt)
  end

  defp discard_checks(ctx, queue) do
    crash = %{ctx | now: fn -> kill_worker(nil) end}

    assert %{state: "available"} = kill_and_rescue(crash, queue, with_scheduled: true)
    assert %{state: "available"} = kill_and_rescue(crash, queue)
    assert %{state: "discarded"} = kill_and_rescue(crash, queue)
  end

  defp insert_delivery(ctx, id) do
    assert {:ok, _} =
             Oban.insert(
               ctx.oban,
               ChatwootDeliveryJob.new(%{"delivery_id" => id}, max_attempts: 3)
             )
  end

  defp insert_reconciliation(ctx, id) do
    job =
      Oban.Job.new(%{"delivery_id" => id},
        worker: "VoelgoedAi.Feasibility.ChatwootReconcileJob",
        queue: :f06_reconcile,
        max_attempts: 3
      )

    assert {:ok, _} = Oban.insert(ctx.oban, job)
  end

  defp submit(ctx, opts \\ []) do
    body = Keyword.get(opts, :body, @body)
    timestamp = Integer.to_string(DateTime.to_unix(@now) + Keyword.get(opts, :offset, 0))
    key = Keyword.get(opts, :key, ctx.signing_key)
    signed_body = Keyword.get(opts, :signed_body, body)
    signature = :crypto.mac(:hmac, :sha256, key, timestamp <> "." <> signed_body)

    headers = [
      {"x-chatwoot-timestamp", timestamp},
      {"x-chatwoot-signature", "sha256=" <> Base.encode16(signature, case: :lower)},
      {"x-chatwoot-delivery", Keyword.get(opts, :delivery, "synthetic-id")},
      {"content-type", Keyword.get(opts, :content_type, "application/json")}
    ]

    conn = build_conn()
    conn = %{conn | req_headers: Keyword.get(opts, :headers, &Function.identity/1).(headers)}
    conn = put_private(conn, :f06_context, ctx)

    conn =
      register_before_send(conn, fn conn ->
        refute Repo.in_transaction?()
        Keyword.get(opts, :before_send, fn -> :ok end).()
        conn
      end)

    dispatch(
      conn,
      ChatwootEndpoint,
      :post,
      "/webhooks/#{Keyword.get(opts, :installation, ctx.installation)}",
      body
    )
  end

  defp payload(changes), do: @body |> Jason.decode!() |> Map.merge(changes) |> Jason.encode!()

  defp conversation(changes),
    do: @body |> Jason.decode!() |> Map.fetch!("conversation") |> Map.merge(changes)

  defp transaction_barrier(parent, phase) do
    assert Repo.in_transaction?()
    barrier(parent, phase)
  end

  defp barrier(parent, phase) do
    send(parent, {phase, self(), backend()})

    receive do
      {:release, ^phase, action} -> action
    after
      5_000 -> raise "F06 barrier timed out at #{phase}"
    end
  end

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)
    pid
  end

  defp assert_blocked_by(waiting, blocker, attempts \\ 100)

  defp assert_blocked_by(_waiting, _blocker, 0),
    do: flunk("the second backend never waited for the receipt lock")

  defp assert_blocked_by(waiting, blocker, attempts) do
    %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [waiting], log: false)

    unless blocker in blockers do
      Process.sleep(10)
      assert_blocked_by(waiting, blocker, attempts - 1)
    end
  end

  defp counts(ctx) do
    %{rows: [row]} =
      sql!(ctx, """
      SELECT (SELECT count(*) FROM @schema.inbound_events),
             (SELECT count(*) FROM @schema.oban_jobs),
             (SELECT count(*) FROM @schema.sessions),
             (SELECT count(*) FROM @schema.deliveries)
      """)

    row
  end

  defp assert_one_ingress_job(ctx) do
    id = event_id(ctx, 101)
    assert {:ok, <<_::48, 7::4, _::76>>} = Ecto.UUID.dump(id)
    assert counts(ctx) == [1, 1, 0, 0]

    assert %{rows: [[%{"event_id" => ^id} = args, "f06_ingress", 1]]} =
             sql!(ctx, "SELECT args, queue, max_attempts FROM @schema.oban_jobs")

    assert map_size(args) == 1
  end

  defp prepare(ctx) do
    assert submit(ctx).status == 204
    assert drain(ctx, :f06_ingress).success == 1
    intent_id(ctx)
  end

  defp event_id(ctx, message) do
    %{rows: [[id]]} =
      sql!(ctx, "SELECT id::text FROM @schema.inbound_events WHERE message_id = $1", [message])

    id
  end

  defp intent_id(ctx, message \\ 101) do
    %{rows: [[id, %{"delivery_id" => same_id} = args]]} =
      sql!(
        ctx,
        """
        SELECT d.id::text, j.args
        FROM @schema.deliveries d
        JOIN @schema.inbound_events e ON d.event_id = e.id
        JOIN @schema.oban_jobs j ON j.args->>'delivery_id' = d.id::text
        WHERE e.message_id = $1 AND j.queue = 'f06_delivery'
        """,
        [message]
      )

    assert id == same_id and map_size(args) == 1
    id
  end

  defp session(ctx, conversation \\ 3) do
    result =
      sql!(
        ctx,
        "SELECT state, epoch, active_event FROM @schema.sessions WHERE conversation_id = $1",
        [
          conversation
        ]
      )

    case result do
      %{rows: [[state, epoch, active]]} -> %{state: state, epoch: epoch, active_event: active}
      %{rows: []} -> nil
    end
  end

  defp sql!(ctx, statement, params \\ []) do
    Repo.query!(String.replace(statement, "@schema", ctx.prefix), params, log: false)
  end

  defp drain(ctx, queue, opts \\ []) do
    key = {ChatwootDelivery, ctx.prefix}
    Process.put(key, ctx)

    try do
      Oban.drain_queue(ctx.oban, [queue: queue, with_safety: false] ++ opts)
    after
      Process.delete(key)
    end
  end

  defp fake(ctx, script) do
    agent =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> {script, []} end]}})

    adapter = fn request ->
      step =
        Agent.get_and_update(agent, fn
          {[{kind, _, _} = step | remaining], calls} -> {step, {remaining, [kind | calls]}}
          {[], calls} -> {:unexpected, {[], [:unexpected | calls]}}
        end)

      refute step == :unexpected, "unexpected Req adapter entry"
      {kind, path, result} = step
      refute Repo.in_transaction?()
      assert request.url.host == "chatwoot.invalid"
      assert request.url.path == path
      assert request.options.retry == false and request.options.redirect == false

      unless Req.Request.get_header(request, "api_access_token") == [ctx.api_token],
        do: flunk("missing or incorrect synthetic API token")

      if kind == :get do
        assert request.method == :get
      else
        assert request.method == :post
        verify_write(ctx, request, kind)
      end

      result.(request)
    end

    Map.merge(ctx, %{adapter: adapter, fake_agent: agent})
  end

  defp verify_write(ctx, request, kind) do
    expected =
      case kind do
        :reply ->
          %{
            "content" => "This is the fixed F06 reply.",
            "message_type" => "outgoing",
            "private" => false
          }

        :handoff ->
          %{"status" => "open"}
      end

    assert Jason.decode!(request.body) == expected

    Repo.checkout(fn ->
      adapter_backend = backend()

      observer =
        Task.async(fn ->
          {backend(),
           sql!(
             ctx,
             """
             SELECT d.state, d.attempts, d.generation, d.epoch, s.state, s.epoch
             FROM @schema.deliveries d JOIN @schema.sessions s ON s.id = d.session_id
             WHERE d.kind = $1 AND d.state = 'sending'
             """,
             [Atom.to_string(kind)]
           )}
        end)

      {observer_backend, result} = Task.await(observer)
      refute observer_backend == adapter_backend
      state = if kind == :handoff, do: "handoff_pending", else: "bot_active"
      assert %{rows: [["sending", 1, 1, epoch, ^state, epoch]]} = result
    end)
  end

  defp assert_fake_calls(ctx, expected) do
    {remaining, calls} = Agent.get(ctx.fake_agent, & &1)
    assert remaining == []
    assert Enum.reverse(calls) == expected
  end

  defp pending(changes \\ %{}) do
    Map.merge(
      %{
        "account_id" => 1,
        "inbox_id" => 2,
        "id" => 3,
        "status" => "pending",
        "can_reply" => true,
        "meta" => %{
          "sender" => %{"id" => 4},
          "assignee_type" => "AgentBot",
          "assignee" => %{"id" => 5}
        },
        "last_non_activity_message" => %{"id" => 101}
      },
      changes
    )
  end

  defp unassigned(status) do
    pending(%{"status" => status, "meta" => %{"sender" => %{"id" => 4}}})
  end

  defp reply_body do
    %{
      "id" => 700,
      "inbox_id" => 2,
      "conversation_id" => 3,
      "message_type" => 1,
      "private" => false,
      "sender" => %{"type" => "agent_bot", "id" => 5}
    }
  end

  defp get(body, path \\ @path), do: {:get, path, response(200, body)}
  defp reply(result), do: {:reply, @path <> "/messages", result}
  defp handoff(result), do: {:handoff, @path <> "/toggle_status", result}

  defp response(status, body),
    do: fn request -> {request, Req.Response.new(status: status, body: body)} end

  defp write_result(reason) when is_atom(reason) do
    fn request -> {request, %Req.TransportError{reason: reason}} end
  end

  defp write_result(307) do
    fn request ->
      {request, Req.Response.new(status: 307, headers: [{"location", "/unexpected"}])}
    end
  end

  defp write_result(status), do: response(status, %{})
end
