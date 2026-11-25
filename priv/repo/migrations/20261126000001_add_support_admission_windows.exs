defmodule VoelgoedAi.Repo.Migrations.AddSupportAdmissionWindows do
  use Ecto.Migration

  def change do
    create table(:support_admission_windows, primary_key: false) do
      add(:window_type, :text, primary_key: true)
      add(:scope, :text, primary_key: true)
      add(:starts_at, :utc_datetime_usec, primary_key: true)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:count, :bigint, null: false, default: 0)
    end

    create(
      constraint(:support_admission_windows, :support_admission_windows_bounds,
        check: "count >= 0 AND expires_at > starts_at AND char_length(scope) BETWEEN 1 AND 255"
      )
    )

    create(index(:support_admission_windows, [:expires_at]))
  end
end
