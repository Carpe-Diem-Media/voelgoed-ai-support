defmodule VoelgoedAi.Support do
  @moduledoc "Support configuration and current-operator recovery commands."
  use Ash.Domain

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Governance.AuditEvent
  alias VoelgoedAi.Support.{ChatwootAdapter, Delivery, OutboundDelivery, Ownership, WorkStore}

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Support.InboxBinding)
    resource(VoelgoedAi.Support.SupportSession)
    resource(VoelgoedAi.Support.InboundEvent)
    resource(VoelgoedAi.Support.SupportRun)
    resource(VoelgoedAi.Support.OutboundDelivery)
    resource(VoelgoedAi.Support.RunInput)
  end

  @doc "Inhibit automation and stage an explicit handoff with the current operator grant."
  def request_handoff(staff, session_id) do
    operator_session(staff, session_id, fn operator, config, session, now ->
      with {:ok, updated} <- Ownership.request_locked(config, session, now),
           {:ok, _} <- audit(operator, session, updated, :request_handoff) do
        {:ok, project(updated)}
      end
    end)
  end

  @doc "Project safe intent metadata for an authorized support operator."
  def reconciliation_projection(staff, session_id) do
    operator_session(staff, session_id, fn _, _, session, _ ->
      with {:ok, rows} <-
             WorkStore.read(OutboundDelivery, :for_session, %{}, %{session_id: session.id},
               many: true,
               sort: [:id],
               limit: 100
             ) do
        {:ok, Enum.map(rows, &project_delivery/1)}
      end
    end)
  end

  @doc "Close UNKNOWN without asserting remote delivery or granting permission to resend."
  def abandon_delivery(staff, delivery_id, :acknowledge_uncertainty) do
    StaffAccess.with_current(staff, :support_operator, fn operator ->
      Delivery.with_delivery(delivery_id, fn _, session, row, now ->
        if row.state == :unknown do
          with {:ok, _} <- Ownership.human_takeover(session, %{}, now),
               {:ok, updated} <-
                 WorkStore.update(row, :abandon, %{
                   state: :abandoned,
                   reason_code: :manual_closure,
                   read_sequence: row.read_sequence + 1
                 }),
               {:ok, _} <- audit(operator, row, updated, :abandon_delivery) do
            {:ok, project_delivery(updated)}
          end
        else
          {:error, :invalid_transition}
        end
      end)
    end)
  end

  def abandon_delivery(_, _, _), do: {:error, :denied}

  @doc "Record authorized local closure and fence pending work."
  def close_session(staff, session_id) do
    operator_session(staff, session_id, fn operator, _, session, now ->
      if session.state != :closed do
        with {:ok, updated} <-
               Ownership.close_locked(session, %{human_inhibit: true}, now, :manual_closure),
             {:ok, _} <- audit(operator, session, updated, :close_session) do
          {:ok, project(updated)}
        end
      else
        {:error, :invalid_transition}
      end
    end)
  end

  @doc "Return control only with a current operator grant and a fresh verified bot assignment."
  def return_to_bot(staff, session_id) do
    with {:ok, {session, epoch, deadline}} <-
           operator_session(staff, session_id, &reserve_return/4),
         {:ok, observation} <- ChatwootAdapter.observe(session, deadline) do
      operator_session(staff, session_id, fn operator, config, current, now ->
        if DateTime.compare(now, deadline) == :lt and Ownership.current?(config, current, epoch) and
             current.state == :human_active and Ownership.write_enabled?(config) and
             Ownership.eligible_bot?(config, %{current | human_inhibit: false}, observation) do
          with {:ok, nil} <- Ownership.blocking_delivery(current, lock: true),
               {:ok, updated} <-
                 WorkStore.update(current, :return_to_bot, %{
                   state: :bot_active,
                   human_inhibit: false,
                   ownership_epoch: current.ownership_epoch + 1,
                   observed_status: observation.status,
                   observed_assignee: observation.assignee,
                   observed_at: now
                 }),
               {:ok, _} <- audit(operator, current, updated, :return_to_bot) do
            {:ok, project(updated)}
          else
            {:ok, _} -> {:error, :awaiting_operator}
            error -> error
          end
        else
          {:error, :scope_denied}
        end
      end)
    end
  end

  defp reserve_return(_, config, %{state: :human_active} = session, now) do
    {:ok, {session, Ownership.epoch_snapshot(config, session), DateTime.add(now, 2)}}
  end

  defp reserve_return(_, _, _, _), do: {:error, :invalid_transition}

  defp operator_session(staff, session_id, operation) do
    StaffAccess.with_current(staff, :support_operator, fn operator ->
      Ownership.locked_session(session_id, &operation.(operator, &1, &2, &3))
    end)
  end

  defp audit(operator, before, after_row, event) do
    {kind, key} =
      case after_row do
        %OutboundDelivery{} -> {:outbound_delivery, :delivery_target_id}
        _ -> {:support_session, :session_target_id}
      end

    WorkStore.create(AuditEvent, :append_support_operator, %{
      key => after_row.id,
      target_kind: kind,
      actor_kind: :staff,
      actor_staff_id: operator.id,
      event: event,
      reason_code: :local_operator,
      correlation_id: after_row.correlation_id,
      operational_before: %{status: before.state, ownership_epoch: before.ownership_epoch},
      operational_after: %{status: after_row.state, ownership_epoch: after_row.ownership_epoch}
    })
  end

  defp project(session), do: Map.take(session, [:id, :state, :ownership_epoch, :reason_code])

  defp project_delivery(row) do
    Map.take(row, [
      :id,
      :session_id,
      :purpose,
      :state,
      :attempt_count,
      :reason_code,
      :uncertainty_reason,
      :correlation_id
    ])
  end
end
