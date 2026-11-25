defmodule VoelgoedAi.Accounts do
  @moduledoc """
  Staff identity, local roles and session authorization.

  Management calls check the acting staff row inside the transaction that
  writes the transition and its audit event. Accept allowlist evidence only
  from a trusted operator who verified the subject for this app registration.
  """
  use Ash.Domain

  alias VoelgoedAi.Accounts.{StaffAccess, StaffLifecycle}

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Accounts.StaffUser)
  end

  defdelegate bootstrap(identity, roles), to: StaffLifecycle
  defdelegate provision(session, identity, roles), to: StaffLifecycle
  defdelegate set_roles(session, id, roles), to: StaffLifecycle
  defdelegate disable(session, id), to: StaffLifecycle
  defdelegate reactivate(session, id, identity, roles), to: StaffLifecycle
  defdelegate retire(session, id), to: StaffLifecycle
  defdelegate read_self(session), to: StaffAccess
  defdelegate read_staff(session, id), to: StaffAccess
  defdelegate require_role(session, role), to: StaffAccess
end
