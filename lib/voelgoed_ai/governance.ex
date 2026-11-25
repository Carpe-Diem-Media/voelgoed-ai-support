defmodule VoelgoedAi.Governance do
  @moduledoc "Append-only operational audit history."
  use Ash.Domain

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Accounts.StaffAccess.Scope
  alias VoelgoedAi.Governance.AuditEvent

  authorization do
    authorize(:always)
  end

  resources do
    resource(AuditEvent)
  end

  @doc "Read staff security events for one local staff ID as a current administrator."
  def staff_security_history(session, id) do
    StaffAccess.with_current(session, :admin, fn _admin ->
      AuditEvent
      |> Ash.Query.for_read(:staff_security_history, %{target_id: id},
        actor: %Scope{action: :staff_security_history, target: id}
      )
      |> Ash.read()
    end)
  end
end
