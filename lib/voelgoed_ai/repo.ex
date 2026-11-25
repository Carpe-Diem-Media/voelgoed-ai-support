defmodule VoelgoedAi.Repo do
  @moduledoc "The AshPostgres repository for application data."
  use AshPostgres.Repo, otp_app: :voelgoed_ai

  @impl true
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions"]
end
