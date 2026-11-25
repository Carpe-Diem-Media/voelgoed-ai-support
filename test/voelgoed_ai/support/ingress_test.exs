defmodule VoelgoedAi.Support.IngressTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.StaffFixtures, only: [bootstrap_admin: 1]
  import VoelgoedAi.SupportFixtures, except: [setup: 0]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Intelligence.{Assistant, AssistantRevision}
  alias VoelgoedAi.Support.{InboxBinding, Ingress}

  setup do
    ctx = VoelgoedAi.SupportFixtures.setup()
    admin = bootstrap_admin(ctx.admin)
    assistant = create(admin, ctx.slug)
    fixture = allow_fixture(assistant)
    revision = draft(admin, assistant)

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: nil},
               admin
             )

    assert {:ok, _} = invoke(Assistant, :activate, %{id: assistant.id}, admin)

    identity = Map.take(fixture, [:installation_ref, :external_account_id, :external_inbox_id])

    assert {:ok, binding} =
             invoke(
               InboxBinding,
               :create_draft,
               Map.put(identity, :assistant_id, assistant.id),
               admin
             )

    assert {:ok, _} = invoke(InboxBinding, :enable, %{id: binding.id}, admin)

    event =
      Map.merge(identity, %{
        conversation_id: 4,
        contact_id: 5,
        message_id: System.unique_integer([:positive]),
        event_type: :message_created,
        kind: :input,
        received_at: DateTime.utc_now()
      })

    %{event: event}
  end

  test "a repeated signed receipt keeps the initial timestamp and durable job", %{event: event} do
    assert {:error, :restore_fixture} =
             Repo.transact(fn ->
               assert {:ok, id} = Ingress.accept(event)

               assert {:ok, ^id} =
                        Ingress.accept(%{event | received_at: DateTime.add(event.received_at, 1)})

               assert %{rows: [["dispatched", timestamp]]} =
                        SQL.query!(
                          Repo,
                          "SELECT state, received_at FROM inbound_events WHERE id = $1",
                          [
                            Ecto.UUID.dump!(id)
                          ]
                        )

               assert timestamp == DateTime.to_naive(event.received_at)
               assert %{rows: [[1]]} = job_count(id)
               {:error, :restore_fixture}
             end)
  end

  test "another connection cannot see the receipt before its job is inserted", %{event: event} do
    on_exit(fn ->
      SQL.query!(
        Repo,
        """
        DELETE FROM oban_jobs WHERE args->>'event_id' IN
          (SELECT id::text FROM inbound_events WHERE message_id = $1)
        """,
        [event.message_id]
      )

      SQL.query!(Repo, "DELETE FROM inbound_events WHERE message_id = $1", [event.message_id])
    end)

    assert {:ok, waiter} =
             Repo.transact(fn ->
               SQL.query!(Repo, "LOCK TABLE oban_jobs IN SHARE MODE")
               waiter = blocked_task(fn -> Ingress.accept(event) end)

               assert %{rows: [[0]]} =
                        SQL.query!(
                          Repo,
                          "SELECT count(*) FROM inbound_events WHERE message_id = $1",
                          [
                            event.message_id
                          ]
                        )

               {:ok, waiter}
             end)

    assert {:ok, id} = Task.await(waiter, 5_000)
    assert %{rows: [[1]]} = job_count(id)

    assert %{rows: [["dispatched"]]} =
             SQL.query!(Repo, "SELECT state FROM inbound_events WHERE id = $1", [
               Ecto.UUID.dump!(id)
             ])
  end

  test "failed enqueue rolls back its receipt and a later attempt can register", %{event: event} do
    assert {:error, _} =
             Repo.transact(fn ->
               SQL.query!(Repo, """
               ALTER TABLE oban_jobs ADD CONSTRAINT reject_ingress_fixture_job
                 CHECK (NOT (args ? 'event_id')) NOT VALID
               """)

               assert {:error, _} = Ingress.accept(event)
               {:error, :restore_fixture}
             end)

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM inbound_events WHERE message_id = $1", [
               event.message_id
             ])

    assert {:error, :restore_fixture} =
             Repo.transact(fn ->
               assert {:ok, id} = Ingress.accept(event)
               assert %{rows: [[1]]} = job_count(id)
               {:error, :restore_fixture}
             end)
  end

  defp job_count(id),
    do:
      SQL.query!(
        Repo,
        "SELECT count(*) FROM oban_jobs WHERE args = jsonb_build_object('event_id', $1::text)",
        [id]
      )
end
