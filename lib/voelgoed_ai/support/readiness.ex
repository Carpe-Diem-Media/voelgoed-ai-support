defmodule VoelgoedAi.Support.Readiness do
  @moduledoc "Bounded local readiness for the configured support mode."

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Governance.EmergencyOverride
  alias VoelgoedAi.Repo

  @timeout 500

  @spec check() :: :ok | {:error, :job_supervisor | :storage | :configuration}
  def check do
    with pid when is_pid(pid) <- Oban.whereis(Oban),
         {:ok, %{rows: [[status, mode, latched, _]]}} <-
           SQL.query(
             Repo,
             """
             SELECT status, mode, emergency_latched, EXISTS (SELECT FROM oban_jobs LIMIT 1)
             FROM automation_controls WHERE singleton
             """,
             [],
             timeout: @timeout,
             log: false,
             telemetry_event: nil
           ) do
      mode_readiness(status, mode, latched)
    else
      nil -> {:error, :job_supervisor}
      _ -> {:error, :storage}
    end
  catch
    :exit, _ -> {:error, :storage}
  end

  defp mode_readiness("disabled", "disabled", _), do: :ok
  defp mode_readiness("enabled", _, true), do: :ok

  defp mode_readiness("enabled", mode, false) do
    if EmergencyOverride.asserted?() or configured?(mode),
      do: :ok,
      else: {:error, :configuration}
  end

  defp mode_readiness(_, _, _), do: {:error, :configuration}

  if Mix.env() == :test do
    alias VoelgoedAi.Support.{ChatwootAdapter, Configuration}

    defp configured?(mode) do
      with %{
             installation_ref: installation,
             external_account_id: account,
             external_inbox_id: inbox
           } =
             fixture <- ChatwootAdapter.fixture(),
           {:ok, assistant} <- Ecto.UUID.dump(fixture[:assistant_id]),
           true <- fixture_for_mode?(fixture, mode),
           {:ok, %{rows: [[revision_id]]}} <-
             SQL.query(
               Repo,
               """
               SELECT r.id::text
               FROM inbox_bindings b JOIN assistants a ON a.id = b.assistant_id
               JOIN assistant_revisions r ON r.id = a.active_revision_id AND r.assistant_id = a.id
               WHERE b.installation_ref = $1 AND b.external_account_id = $2
                 AND b.external_inbox_id = $3 AND b.operating_mode = ANY($4)
                 AND b.status = 'enabled' AND a.status = 'active' AND a.audience = 'public'
                 AND r.status = 'published'
                 AND a.id = $5 AND b.credential_ref = $6 AND b.handoff_team_id = $7
               """,
               [
                 installation,
                 account,
                 inbox,
                 binding_modes(mode, fixture),
                 assistant,
                 fixture[:credential_ref],
                 fixture[:handoff_team_id]
               ],
               timeout: @timeout,
               log: false,
               telemetry_event: nil
             ),
           {:ok, revision} <-
             Repo.transact(fn -> Configuration.qualified_revision(revision_id, @timeout) end,
               timeout: @timeout
             ) do
        {mode, revision.response_policy} in [
          {"fake", :fixed_reply},
          {"shadow_test", :shadow_decision}
        ]
      else
        _ -> false
      end
    end

    defp binding_modes("fake", _), do: ["automatic"]
    defp binding_modes("shadow_test", %{assisted_draft: true}), do: ["shadow", "assisted"]
    defp binding_modes("shadow_test", _), do: ["shadow"]

    defp fixture_for_mode?(%{adapter: {_, _}}, "fake"), do: ChatwootAdapter.write_fixture?()

    defp fixture_for_mode?(
           %{adapter: {_, _}, response_policy: :shadow_decision, shadow_evaluation: true},
           "shadow_test"
         ),
         do: true

    defp fixture_for_mode?(_, _), do: false
  else
    defp configured?(_), do: false
  end
end
