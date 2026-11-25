defmodule VoelgoedAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    development_ai = Application.get_env(:voelgoed_ai, :development_ai, [])

    if development_ai[:live_calls_enabled] do
      with {:ok, key, :system} <- ReqLLM.Keys.get(:openai),
           true <- String.trim(key) != "" do
        :ok
      else
        _ -> raise "Export OPENAI_API_KEY to enable live OpenAI inference"
      end
    end

    children = [
      VoelgoedAi.Repo,
      {Oban, Application.fetch_env!(:voelgoed_ai, Oban)},
      VoelgoedAi.Accounts.EntraPendingStates,
      VoelgoedAiWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: VoelgoedAi.Supervisor)
  end
end
