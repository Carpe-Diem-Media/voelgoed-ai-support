defmodule VoelgoedAi.SupportDBCase do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Plug.Conn
  import VoelgoedAi.StaffFixtures, only: [authenticate: 1, bootstrap_admin: 1]
  import VoelgoedAi.SupportFixtures, except: [setup: 0]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Accounts, ChatwootFake, Repo}
  alias VoelgoedAi.Governance.AutomationControl
  alias VoelgoedAi.Intelligence.{Assistant, AssistantRevision}
  alias VoelgoedAi.Support.ChatwootAdapter.{Destination, Message, Observation}
  alias VoelgoedAi.Support.{InboxBinding, Ingress, RunProcessing}
  alias VoelgoedAiWeb.Endpoint

  @signing_key "synthetic-chatwoot-signing-key"

  def setup do
    staff = VoelgoedAi.SupportFixtures.setup()
    admin = bootstrap_admin(staff.admin)
    assert {:ok, operator} = Accounts.provision(admin, staff.invited, [:support_operator])
    assert {:ok, operator} = authenticate(operator.id)

    assistant = create(admin, staff.slug)
    inbox_id = next_id()
    conversation_id = next_id()
    message_id = next_id()
    account_id = next_id()
    now = DateTime.utc_now()

    destination = %Destination{
      installation: "synthetic",
      account: account_id,
      inbox: inbox_id,
      conversation: conversation_id
    }

    observation = %Observation{
      destination: destination,
      status: :pending,
      assignee: :bot,
      contact: 5,
      can_reply: true,
      team: 1
    }

    fake =
      start_supervised!(
        {ChatwootFake,
         %{
           now: now,
           observation: observation,
           history: [%Message{id: message_id, sender: :contact, visibility: :public}],
           read_barrier: nil,
           writes: [],
           write_mode: :accepted
         }}
      )

    fixture =
      allow_fixture(assistant, %{
        external_inbox_id: inbox_id,
        external_account_id: account_id,
        adapter: {ChatwootFake, fake},
        signing_key: @signing_key,
        clock: fn -> Agent.get(fake, & &1.now) end,
        after_claim: fn -> pause_after_claim(fake) end,
        after_authorization: fn ->
          pause_delivery(
            fake,
            :authorization_barrier,
            :delivery_authorized,
            :resume_delivery_authorization
          )
        end,
        batch_size: 5,
        history_limit: 15,
        inbox_limit: 100,
        global_limit: 100,
        # Keep the shared DevCore TEST allocation from combining unrelated
        # scenarios into one global counter. Each scenario still shares it
        # across all of its conversations and contacts.
        global_scope: "synthetic:#{account_id}:fixture_global"
      })

    revision = draft(admin, assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: nil},
               admin
             )

    assert {:ok, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)
    inbox = Map.take(fixture, [:installation_ref, :external_account_id, :external_inbox_id])

    assert {:ok, binding} =
             invoke(
               InboxBinding,
               :create_draft,
               Map.put(inbox, :assistant_id, assistant.id),
               admin
             )

    assert {:ok, _} = invoke(InboxBinding, :enable, %{id: binding.id}, admin)

    assert {:ok, _} =
             invoke(
               InboxBinding,
               :change_mode,
               %{id: binding.id, operating_mode: :automatic},
               admin
             )

    assert {:ok, _} =
             invoke(AutomationControl, :enable_automation, %{binding_id: binding.id}, admin)

    on_exit(fn ->
      clean(inbox_id, account_id)
      assert {:ok, _} = invoke(AutomationControl, :disable_automation, %{}, admin)

      SQL.query!(
        Repo,
        "DELETE FROM audit_events WHERE control_target_id IS NOT NULL AND actor_staff_id = $1",
        [Ecto.UUID.dump!(admin.id)]
      )
    end)

    event =
      Map.merge(inbox, %{
        conversation_id: conversation_id,
        message_id: message_id,
        contact_id: 5,
        event_type: :message_created,
        kind: :input,
        received_at: now
      })

    %{
      event: event,
      fake: fake,
      admin: admin,
      operator: operator,
      binding_id: binding.id,
      assistant: assistant,
      revision: revision
    }
  end

  def signed_receipt(%{event: event} = ctx) do
    assert signed_request(ctx, & &1).status == 204

    assert %{rows: [[id]]} =
             SQL.query!(Repo, "SELECT id::text FROM inbound_events WHERE message_id = $1", [
               event.message_id
             ])

    {:ok, %{id: id}}
  end

  def signed_request(%{event: event, fake: fake}, transform, installation \\ "synthetic") do
    timestamp = Agent.get(fake, &Integer.to_string(DateTime.to_unix(&1.now)))

    bytes =
      %{
        "event" => "message_created",
        "id" => event.message_id,
        "account" => %{"id" => event.external_account_id},
        "inbox" => %{"id" => event.external_inbox_id},
        "conversation" => %{
          "id" => event.conversation_id,
          "account" => %{"id" => event.external_account_id},
          "inbox_id" => event.external_inbox_id,
          "meta" => %{"sender" => %{"id" => 5}}
        },
        "sender" => %{"id" => 5, "account" => %{"id" => event.external_account_id}},
        "private" => false,
        "message_type" => "incoming",
        "content_type" => "text",
        "content" => "Synthetic input"
      }
      |> transform.()
      |> Jason.encode!()

    digest =
      :crypto.mac(:hmac, :sha256, @signing_key, [timestamp, ".", bytes])
      |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/webhooks/chatwoot/#{installation}", bytes)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-chatwoot-timestamp", timestamp)
    |> put_req_header("x-chatwoot-signature", "sha256=" <> digest)
    |> Endpoint.call(Endpoint.init([]))
  end

  def next_conversation(ctx, increment) do
    now = Agent.get(ctx.fake, & &1.now)

    event = %{
      ctx.event
      | conversation_id: ctx.event.conversation_id + increment,
        message_id: ctx.event.message_id + increment,
        received_at: now
    }

    Agent.update(ctx.fake, fn state ->
      destination = %{state.observation.destination | conversation: event.conversation_id}

      %{
        state
        | observation: %{state.observation | destination: destination},
          history: [%Message{id: event.message_id, sender: :contact, visibility: :public}]
      }
    end)

    %{ctx | event: event}
  end

  def advance_clock(%{fake: fake}, seconds),
    do: Agent.update(fake, &%{&1 | now: DateTime.add(&1.now, seconds)})

  def append_public_input(%{fake: fake}, id),
    do:
      Agent.update(
        fake,
        &%{&1 | history: &1.history ++ [%Message{id: id, sender: :contact, visibility: :public}]}
      )

  def write_mode(%{fake: fake}, mode), do: Agent.update(fake, &%{&1 | write_mode: mode})

  def block_next_write(%{fake: fake}, pid),
    do: Agent.update(fake, &Map.put(&1, :write_barrier, pid))

  def block_next_conversation(%{fake: fake}, pid),
    do: Agent.update(fake, &Map.put(&1, :read_barrier, pid))

  def writes(%{fake: fake}), do: Agent.get(fake, &Enum.reverse(&1.writes))

  def block_after_claim(%{fake: fake}, pid),
    do: Agent.update(fake, &Map.put(&1, :claim_barrier, pid))

  defp pause_after_claim(fake),
    do: pause_delivery(fake, :claim_barrier, :delivery_claimed, :resume_delivery_claim)

  defp pause_delivery(fake, barrier, signal, reply) do
    case Agent.get_and_update(fake, &Map.pop(&1, barrier)) do
      nil ->
        :ok

      pid ->
        send(pid, {signal, self()})

        receive do
          ^reply -> :ok
        after
          1_000 -> {:error, :deadline}
        end
    end
  end

  def enable_automation(ctx) do
    assert {:ok, _} =
             invoke(
               AutomationControl,
               :enable_automation,
               %{binding_id: ctx.binding_id},
               ctx.admin
             )
  end

  def disable_automation(ctx) do
    assert {:ok, _} = invoke(AutomationControl, :disable_automation, %{}, ctx.admin)
  end

  def session_id(ctx) do
    assert %{rows: [[id]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM support_sessions WHERE conversation_id = $1",
               [ctx.event.conversation_id]
             )

    id
  end

  def delivery_rows(ctx, fields) do
    SQL.query!(Repo, "SELECT #{fields} FROM outbound_deliveries WHERE session_id = $1", [
      Ecto.UUID.dump!(session_id(ctx))
    ])
  end

  def prepare_reply(ctx) do
    assert {:ok, event_id} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(event_id)

    assert %{rows: [[run_id]]} =
             SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [
               Ecto.UUID.dump!(session_id(ctx))
             ])

    advance_clock(ctx, 2)
    assert :ok = RunProcessing.process_run(run_id)
    assert %{rows: [[delivery_id]]} = delivery_rows(ctx, "id::text")
    delivery_id
  end

  def audit_rows(target_key, id) do
    SQL.query!(
      Repo,
      """
      SELECT actor_kind, target_kind, event, reason_code
      FROM audit_events AS audit
      WHERE to_jsonb(audit)->>$1 = $2
      ORDER BY occurred_at, id
      """,
      [Atom.to_string(target_key), id]
    ).rows
  end

  defp clean(inbox_id, account_id) do
    matches = "SELECT id FROM support_sessions WHERE external_inbox_id = $1"

    for {key, subquery} <- [
          {"event_id", "SELECT id FROM inbound_events WHERE external_inbox_id = $1"},
          {"run_id", "SELECT id FROM support_runs WHERE session_id IN (#{matches})"},
          {"delivery_id", "SELECT id FROM outbound_deliveries WHERE session_id IN (#{matches})"}
        ] do
      SQL.query!(
        Repo,
        "DELETE FROM oban_jobs WHERE args->>'#{key}' IN (SELECT id::text FROM (#{subquery}) ids)",
        [inbox_id]
      )
    end

    SQL.query!(
      Repo,
      "DELETE FROM run_inputs WHERE event_id IN (SELECT id FROM inbound_events WHERE external_inbox_id = $1)",
      [inbox_id]
    )

    SQL.query!(
      Repo,
      """
      DELETE FROM audit_events
      WHERE session_target_id IN (#{matches})
        OR delivery_target_id IN (SELECT id FROM outbound_deliveries WHERE session_id IN (#{matches}))
        OR event_target_id IN (SELECT id FROM inbound_events WHERE external_inbox_id = $1)
        OR run_target_id IN (SELECT id FROM support_runs WHERE session_id IN (#{matches}))
      """,
      [inbox_id]
    )

    SQL.query!(Repo, "DELETE FROM outbound_deliveries WHERE session_id IN (#{matches})", [
      inbox_id
    ])

    SQL.query!(Repo, "DELETE FROM support_runs WHERE session_id IN (#{matches})", [inbox_id])
    SQL.query!(Repo, "DELETE FROM inbound_events WHERE external_inbox_id = $1", [inbox_id])
    SQL.query!(Repo, "DELETE FROM support_sessions WHERE external_inbox_id = $1", [inbox_id])

    SQL.query!(Repo, "DELETE FROM support_admission_windows WHERE scope LIKE $1", [
      "synthetic:#{account_id}:%"
    ])
  end

  defp next_id, do: System.unique_integer([:positive, :monotonic]) * 10
end
