defmodule VoelgoedAi.Repo.Migrations.QueueCircuitAlertOpenings do
  use Ecto.Migration

  def up do
    create table(:support_circuit_alerts_pending, primary_key: false) do
      add(:binding_id, references(:inbox_bindings, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:generation, :bigint, primary_key: true)
      add(:opened_at, :timestamptz, null: false)
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM support_circuit_alerts_pending) THEN
        RAISE EXCEPTION 'rollback would remove unprojected circuit openings';
      END IF;
    END;
    $$;
    """)

    drop(table(:support_circuit_alerts_pending))
  end
end
