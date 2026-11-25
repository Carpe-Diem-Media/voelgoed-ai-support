defmodule Mix.Tasks.Vgas.Staff.Bootstrap do
  use Mix.Task

  @shortdoc "Invite the first Entra staff administrator from protected standard input"
  @moduledoc """
  Invite the first administrator using the owner-verified identity document on STDIN.

  See docs/runbooks/staff-auth.md for the evidence and operator requirements.
  """

  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case VoelgoedAi.Accounts.StaffBootstrap.from_stdin() do
      :ok -> Mix.shell().info("Staff invitation created")
      {:error, reason} -> Mix.raise("Staff invitation rejected (#{reason})")
    end
  end

  def run(_), do: Mix.raise("Provide the approved invitation on standard input")
end
