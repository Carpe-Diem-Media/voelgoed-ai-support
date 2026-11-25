defmodule VoelgoedAi.ChatwootFeasibilityTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest, only: [build_conn: 0, dispatch: 5]
  import Plug.Conn

  alias VoelgoedAi.Feasibility.{
    ChatwootDelivery,
    ChatwootEndpoint,
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
    assert counts(ctx) == [1, 2, 1, 1]
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
    assert counts(ctx) == [2, 4, 1, 1]
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
    assert counts(ctx) == [2, 3, 1, 1]

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

    assert counts(ctx) == [2, 4, 1, 2]
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
        get(pending(%{"last_non_activity_message" => %{"id" => 102}})),
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
    assert %{state: "cancelled", attempts: 0} = ChatwootStore.delivery(ctx.prefix, id)
    assert_fake_calls(ctx, [:get, :get, :get, :get])
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
      script = if replay?, do: script ++ [get(pending())], else: script
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
    assert counts(ctx) == [2, 3, 1, 1]
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
        get(
          pending(%{
            "last_non_activity_message" => %{
              "id" => 700,
              "content" => "This is the fixed F06 reply."
            }
          })
        ),
        get(pending()),
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

    assert {:ok, _} = ChatwootDelivery.reconcile(advanced, id)
    assert :ok == ChatwootDelivery.deliver(advanced, id)
    assert {:ok, :ok} = ChatwootDelivery.decide(advanced, event_id(ctx, 101))
    assert submit(ctx, body: payload(%{"id" => 102})).status == 204
    assert drain(advanced, :f06_ingress).success == 1
    assert %{state: "unknown", attempts: 1} = ChatwootStore.delivery(ctx.prefix, id)
    assert counts(ctx) == [2, 4, 1, 1]
    assert_fake_calls(ctx, [:get, :get, :reply, :get, :get, :get])
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
    assert {:ok, _} = ChatwootDelivery.reconcile(advanced, id)

    assert %{state: "sent", attempts: 1, reason: "goal_observed"} =
             ChatwootStore.delivery(ctx.prefix, id)

    assert %{state: "human_active"} = session(ctx)
    assert_fake_calls(ctx, [:get, :get, :handoff, :get])
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
