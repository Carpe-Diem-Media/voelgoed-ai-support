defmodule VoelgoedAi.SupportFixtures do
  @moduledoc false

  import ExUnit.Assertions
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, StaffFixtures}

  def setup do
    staff = StaffFixtures.setup()
    slug = Ash.UUIDv7.generate()
    # Each example owns its configuration and deletes only its own rows.
    ExUnit.Callbacks.on_exit(fn ->
      SQL.query!(
        Repo,
        """
        DELETE FROM audit_events
        WHERE assistant_target_id IN (SELECT id FROM assistants WHERE slug IN ($1, $1 || '-other'))
           OR revision_target_id IN (SELECT r.id FROM assistant_revisions r JOIN assistants a
                                     ON a.id = r.assistant_id WHERE a.slug IN ($1, $1 || '-other'))
           OR binding_target_id IN (SELECT b.id FROM inbox_bindings b JOIN assistants a
                                    ON a.id = b.assistant_id WHERE a.slug IN ($1, $1 || '-other'))
        """,
        [slug]
      )

      SQL.query!(
        Repo,
        "DELETE FROM inbox_bindings WHERE assistant_id IN (SELECT id FROM assistants WHERE slug IN ($1, $1 || '-other'))",
        [slug]
      )

      SQL.query!(
        Repo,
        "UPDATE assistants SET active_revision_id = NULL, status = 'disabled', disabled_at = now() WHERE slug IN ($1, $1 || '-other')",
        [slug]
      )

      SQL.query!(
        Repo,
        "DELETE FROM assistant_revisions WHERE assistant_id IN (SELECT id FROM assistants WHERE slug IN ($1, $1 || '-other'))",
        [slug]
      )

      SQL.query!(Repo, "DELETE FROM assistants WHERE slug IN ($1, $1 || '-other')", [slug])
    end)

    Map.put(staff, :slug, slug)
  end

  def invoke(resource, action, args, actor) do
    resource
    |> Ash.ActionInput.for_action(action, args, actor: actor)
    |> Ash.run_action()
  end

  def create(session, slug) do
    assert {:ok, assistant} =
             invoke(
               VoelgoedAi.Intelligence.Assistant,
               :create,
               %{slug: slug, display_name: "Synthetic support", audience: :public},
               session
             )

    assistant
  end

  def draft(session, assistant) do
    assert {:ok, revision} =
             invoke(
               VoelgoedAi.Intelligence.AssistantRevision,
               :create_draft,
               %{
                 assistant_id: assistant.id,
                 workflow_version: "test-v1",
                 template_version: "test-v1",
                 locale: :af,
                 response_policy: :fixed_reply
               },
               session
             )

    revision
  end

  def allow_fixture(assistant, attrs \\ %{}) do
    previous = Application.fetch_env(:voelgoed_ai, :support_fixture)

    fixture =
      Map.merge(
        %{
          assistant_id: assistant.id,
          workflow_version: "test-v1",
          template_version: "test-v1",
          locale: :af,
          response_policy: :fixed_reply,
          fixed_text: "Synthetic fixture",
          installation_ref: "synthetic",
          external_account_id: 1,
          external_inbox_id: System.unique_integer([:positive]),
          credential_ref: "synthetic",
          handoff_team_id: 1
        },
        attrs
      )

    Application.put_env(:voelgoed_ai, :support_fixture, fixture)

    unless Process.get({__MODULE__, :registered_fixture_cleanup}) do
      Process.put({__MODULE__, :registered_fixture_cleanup}, true)

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, original} -> Application.put_env(:voelgoed_ai, :support_fixture, original)
          :error -> Application.delete_env(:voelgoed_ai, :support_fixture)
        end
      end)
    end

    fixture
  end

  def blocked_task(operation) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})
          operation.()
        end)
      end)

    pid = task.pid
    assert_receive {:backend, ^pid, backend}, 5_000
    assert_waiting(backend, System.monotonic_time(:millisecond) + 4_000)
    task
  end

  defp assert_waiting(backend, deadline) do
    case SQL.query!(Repo, "SELECT pg_backend_pid() = ANY(pg_blocking_pids($1))", [backend]) do
      %{rows: [[true]]} ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "PostgreSQL lock wait was not observed"

        Process.sleep(10)
        assert_waiting(backend, deadline)
    end
  end
end
