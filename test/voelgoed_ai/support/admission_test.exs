defmodule VoelgoedAi.Support.AdmissionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Governance.Admission
  alias VoelgoedAi.Repo

  test "a denied reservation does not charge its other windows" do
    now = ~U[2026-11-26 12:00:00Z]
    scope = Ash.UUIDv7.generate()
    contact = Admission.window(:contact_minute, scope, now, 60, 1)
    inbox = Admission.window(:inbox_minute, scope, now, 60, 2)

    assert {:error, :restore_fixture} =
             Repo.transact(fn ->
               assert :ok = Admission.reserve([contact])
               assert {:error, :admission_limited} = Admission.reserve([inbox, contact])
               assert :ok = Admission.reserve([inbox])
               assert :ok = Admission.reserve([inbox])
               assert {:error, :admission_limited} = Admission.reserve([inbox])
               {:error, :restore_fixture}
             end)

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM support_admission_windows WHERE scope = $1", [
               scope
             ])
  end
end
