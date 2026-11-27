defmodule VoelgoedAi.Release do
  @moduledoc "Apply forward migrations from a release before starting the service."

  @doc "Apply all pending migrations in version order using the configured repositories."
  @spec migrate() :: :ok
  def migrate do
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(:voelgoed_ai)

    for repo <- Application.fetch_env!(:voelgoed_ai, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          repo,
          &Ecto.Migrator.run(&1, :up, all: true, strict_version_order: true)
        )
    end

    :ok
  end
end
