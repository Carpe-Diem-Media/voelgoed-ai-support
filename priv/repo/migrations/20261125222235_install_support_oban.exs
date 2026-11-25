defmodule VoelgoedAi.Repo.Migrations.InstallSupportOban do
  @moduledoc "Installs and rolls back only the Oban job schema."
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 1)
end
