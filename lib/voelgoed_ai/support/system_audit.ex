defmodule VoelgoedAi.Support.SystemAudit do
  @moduledoc """
  Records code-owned workflow facts in the transaction that updates the target.
  History exposes only internal references, the event, its reason and its time.
  """

  use Ash.Resource.Actions.Implementation

  use VoelgoedAi.Support.WorkStore, [:read, :create]

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Accounts.StaffAccess.Session
  alias VoelgoedAi.Governance.AuditEvent
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ActionScope, ChatwootAdapter, InboundEvent, OutboundDelivery}
  alias VoelgoedAi.Support.{Ownership, SupportRun, SupportSession}

  @targets %{
    inbound_event: {InboundEvent, :event_target_id},
    support_run: {SupportRun, :run_target_id},
    outbound_delivery: {OutboundDelivery, :delivery_target_id}
  }
  @kinds Map.new(@targets, fn {kind, {resource, key}} -> {resource, {kind, key}} end)
  @fields [:id, :actor_kind, :target_kind, :event, :reason_code, :correlation_id, :occurred_at]

  @doc "Append one fact for the updated record in the caller's transition transaction."
  def append(%resource{} = row, event, reason) do
    {kind, key} = Map.fetch!(@kinds, resource)

    attrs = %{
      key => row.id,
      actor_kind: :support_worker,
      target_kind: kind,
      event: event,
      reason_code: reason,
      correlation_id: row.correlation_id
    }

    store_create(AuditEvent, :append_system, audit_attributes(attrs))
  end

  @impl true
  def run(input, _opts, %{actor: %Session{} = session}) do
    StaffAccess.with_current(session, nil, fn staff ->
      if :admin in staff.roles or :support_operator in staff.roles do
        history(input.arguments, :staff)
      else
        {:error, :denied}
      end
    end)
    |> result()
  end

  def run(input, _opts, %{actor: %ActionScope.Reconciliation{} = actor}) do
    Repo.transact(fn ->
      if ActionScope.permits?(actor, input),
        do: history(input.arguments, {:reconciliation, actor.inbox}),
        else: {:error, :denied}
    end)
    |> result()
  end

  def run(_, _, _), do: result({:error, :denied})

  defp history(%{target_kind: kind, id: id} = args, inbox) do
    {resource, key} = Map.fetch!(@targets, kind)

    with {:ok, %{id: ^id} = row} <- Ownership.get(resource, id),
         {:ok, qualifier} <- qualifier(row),
         true <- authorized_inbox?(qualifier, inbox),
         {:ok, rows} <- store_read(AuditEvent, :system_rows, args, %{}, many: true) do
      {:ok,
       Enum.map(rows, &(&1 |> Map.take(@fields) |> Map.put(:target_id, Map.fetch!(&1, key))))}
    else
      {:ok, nil} -> {:error, :denied}
      false -> {:error, :denied}
      error -> error
    end
  end

  defp qualifier(%InboundEvent{} = event), do: {:ok, event}
  defp qualifier(row), do: Ownership.get(SupportSession, row.session_id)

  defp authorized_inbox?(nil, _), do: false

  defp authorized_inbox?(_row, :staff), do: true

  defp authorized_inbox?(row, {:reconciliation, inbox}) do
    ChatwootAdapter.in_scope?(row) and
      inbox == {row.installation_ref, row.external_account_id, row.external_inbox_id}
  end

  defp result({:error, :denied}), do: {:error, "system audit access denied"}
  defp result({:error, _}), do: {:error, "system audit read failed"}
  defp result(success), do: success

  if Mix.env() == :test do
    defp audit_attributes(%{event: event} = attrs) do
      if Process.get({__MODULE__, :reject_audit}) == event,
        do: Map.delete(attrs, :correlation_id),
        else: attrs
    end
  else
    defp audit_attributes(attrs), do: attrs
  end
end
