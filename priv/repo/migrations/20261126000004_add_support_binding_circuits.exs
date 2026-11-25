defmodule VoelgoedAi.Repo.Migrations.AddSupportBindingCircuits do
  use Ecto.Migration

  def change do
    create table(:support_binding_circuits, primary_key: false) do
      add(:binding_id, references(:inbox_bindings, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:generation, :bigint, null: false)
      add(:failures, :integer, null: false)
      add(:retry_at, :timestamptz)
      add(:probe_until, :timestamptz)
    end

    create(
      constraint(:support_binding_circuits, :support_binding_circuit_state,
        check: """
        generation >= 0 AND failures >= 0 AND
        (probe_until IS NULL OR retry_at IS NOT NULL)
        """
      )
    )
  end
end
