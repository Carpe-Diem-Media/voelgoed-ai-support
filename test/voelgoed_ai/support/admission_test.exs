defmodule VoelgoedAi.Support.AdmissionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Governance.Admission
  alias VoelgoedAi.{Repo, Support, SupportDBCase}
  alias VoelgoedAi.Support.{Ingress, RunProcessing}

  test "a denied reservation does not charge its other windows" do
    now = ~U[2026-11-26 12:00:00Z]
    scope = Ash.UUIDv7.generate()
    contact = Admission.window(:contact_minute, scope, now, 60, 1)
    inbox = Admission.window(:inbox_minute, scope, now, 60, 2)

    assert {:error, :restore_fixture} =
             Repo.transact(fn ->
               assert :ok = Admission.reserve([contact])
               assert {:error, :admission_limited} = Admission.reserve([inbox, contact])
               assert :ok = Admission.reserve([inbox])
               assert :ok = Admission.reserve([inbox])
               assert {:error, :admission_limited} = Admission.reserve([inbox])
               {:error, :restore_fixture}
             end)

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM support_admission_windows WHERE scope = $1", [
               scope
             ])
  end

  for {type, seconds, limit} <- [{:contact_minute, 60, 10}, {:contact_hour, 3600, 60}] do
    test "#{type} serializes concurrent reservations and permits the next window" do
      scope = Ash.UUIDv7.generate()
      now = ~U[2026-11-26 12:00:00Z]
      window = Admission.window(unquote(type), scope, now, unquote(seconds), unquote(limit))

      on_exit(fn ->
        SQL.query!(Repo, "DELETE FROM support_admission_windows WHERE scope = $1", [scope])
      end)

      assert {:ok, blocked} =
               Repo.transact(fn ->
                 for _ <- 1..unquote(limit), do: assert(:ok = Admission.reserve([window]))

                 blocked =
                   VoelgoedAi.SupportFixtures.blocked_task(fn ->
                     Repo.transact(fn -> Admission.reserve([window]) end)
                   end)

                 {:ok, blocked}
               end)

      assert {:error, :admission_limited} = Task.await(blocked)

      next =
        Admission.window(
          unquote(type),
          scope,
          DateTime.add(now, unquote(seconds)),
          unquote(seconds),
          unquote(limit)
        )

      assert {:ok, :reserved} =
               Repo.transact(fn ->
                 assert :ok = Admission.reserve([next])
                 {:ok, :reserved}
               end)

      limit = unquote(limit)

      assert %{rows: [[^limit], [1]]} =
               SQL.query!(
                 Repo,
                 "SELECT count FROM support_admission_windows WHERE scope = $1 ORDER BY starts_at",
                 [scope]
               )
    end
  end

  for cap <- [:inbox_limit, :global_limit] do
    test "#{cap} denies a distinct receipt without charging the other windows" do
      ctx = SupportDBCase.setup()
      fixture = Application.fetch_env!(:voelgoed_ai, :support_fixture)
      VoelgoedAi.SupportFixtures.allow_fixture(ctx.assistant, Map.put(fixture, unquote(cap), 1))

      assert {:ok, id} = Ingress.accept(ctx.event)
      assert :ok = RunProcessing.process_event(id)
      assert :ok = RunProcessing.process_event(id)
      after_first = counters(ctx)

      event = %{ctx.event | message_id: ctx.event.message_id + 1}
      SupportDBCase.append_public_input(ctx, event.message_id)
      assert {:ok, next} = Ingress.accept(event)
      assert :ok = RunProcessing.process_event(next)

      assert %{rows: [["triage", "admission_limited"]]} =
               SQL.query!(
                 Repo,
                 "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
                 [Ecto.UUID.dump!(next)]
               )

      assert after_first == counters(ctx)
      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "100 waiting receipts cap pre-admission work before it can become queued runs" do
    ctx = SupportDBCase.setup()

    for offset <- 1..100 do
      assert {:ok, _} = Ingress.accept(%{ctx.event | message_id: ctx.event.message_id + offset})
    end

    assert {:ok, overflow} = Ingress.accept(ctx.event)

    assert %{rows: [["quarantined", "triage", "admission_limited"]]} =
             SQL.query!(
               Repo,
               "SELECT state, disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(overflow)]
             )

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM oban_jobs WHERE args->>'event_id' = $1", [
               overflow
             ])

    assert [] = counters(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "five distinct conversations can run while a sixth waits for global capacity" do
    ctx = SupportDBCase.setup()

    runs =
      for number <- 1..6 do
        conversation = SupportDBCase.next_conversation(ctx, number)
        assert {:ok, receipt} = Ingress.accept(conversation.event)
        assert :ok = RunProcessing.process_event(receipt)

        assert %{rows: [[run]]} =
                 SQL.query!(Repo, "SELECT id::text FROM support_runs WHERE session_id = $1", [
                   Ecto.UUID.dump!(SupportDBCase.session_id(conversation))
                 ])

        {number, run}
      end

    SupportDBCase.advance_clock(ctx, 2)

    running =
      for {number, run} <- Enum.take(runs, 5) do
        SupportDBCase.next_conversation(ctx, number)
        SupportDBCase.block_next_conversation(ctx, self())
        task = Task.async(fn -> RunProcessing.process_run(run) end)
        assert_receive {:chatwoot_read, worker}, 1_000
        {task, worker}
      end

    {6, sixth} = List.last(runs)
    assert :ok = RunProcessing.process_run(sixth)

    assert %{rows: [["queued", 0]]} =
             SQL.query!(Repo, "SELECT state, attempt_count FROM support_runs WHERE id = $1", [
               Ecto.UUID.dump!(sixth)
             ])

    for {task, worker} <- running do
      send(worker, :resume_chatwoot_read)
      assert :ok = Task.await(task)
    end

    SupportDBCase.next_conversation(ctx, 6)
    assert :ok = RunProcessing.process_run(sixth)

    assert %{rows: [["completed", 1]]} =
             SQL.query!(Repo, "SELECT state, attempt_count FROM support_runs WHERE id = $1", [
               Ecto.UUID.dump!(sixth)
             ])

    assert [] = SupportDBCase.writes(ctx)
  end

  defp counters(ctx) do
    SQL.query!(
      Repo,
      """
      SELECT window_type, count FROM support_admission_windows
      WHERE scope LIKE $1 AND count > 0 ORDER BY window_type
      """,
      ["synthetic:#{ctx.event.external_account_id}:%"]
    ).rows
  end

  test "contact daily quota follows a contact across conversations and preserves operator access" do
    ctx = SupportDBCase.setup()
    assert {:ok, first} = Ingress.accept(ctx.event)
    assert :ok = RunProcessing.process_event(first)
    session_id = SupportDBCase.session_id(ctx)
    scope = "synthetic:#{ctx.event.external_account_id}:contact:#{ctx.event.contact_id}:input"
    daily = Admission.window(:contact_day, scope, ctx.event.received_at, 86_400, 40)

    assert {:ok, :reserved} =
             Repo.transact(fn ->
               for _ <- 1..39, do: assert(:ok = Admission.reserve([daily]))
               {:ok, :reserved}
             end)

    event = %{
      ctx.event
      | conversation_id: ctx.event.conversation_id + 1,
        message_id: ctx.event.message_id + 1
    }

    Agent.update(ctx.fake, fn state ->
      destination = %{state.observation.destination | conversation: event.conversation_id}
      %{state | observation: %{state.observation | destination: destination}}
    end)

    SupportDBCase.append_public_input(ctx, event.message_id)

    assert {:ok, second} = Ingress.accept(event)
    assert :ok = RunProcessing.process_event(second)
    assert :ok = RunProcessing.process_event(second)
    assert {:ok, ^second} = Ingress.accept(event)

    assert %{rows: [["triage", "admission_limited"]]} =
             SQL.query!(
               Repo,
               "SELECT disposition, reason_code FROM inbound_events WHERE id = $1",
               [Ecto.UUID.dump!(second)]
             )

    assert %{rows: [[40]]} =
             SQL.query!(
               Repo,
               "SELECT count FROM support_admission_windows WHERE window_type = 'contact_day' AND scope = $1",
               [scope]
             )

    assert {:ok, %{state: :handoff_pending}} = Support.request_handoff(ctx.operator, session_id)
    assert [] = SupportDBCase.writes(ctx)
  end
end
