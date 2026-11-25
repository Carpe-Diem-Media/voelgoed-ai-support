defmodule VoelgoedAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [VoelgoedAi.Repo, VoelgoedAiWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: VoelgoedAi.Supervisor)
  end
end
