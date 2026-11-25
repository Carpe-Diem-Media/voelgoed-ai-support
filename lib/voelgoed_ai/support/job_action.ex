defmodule VoelgoedAi.Support.JobAction do
  @moduledoc """
  Runs an ID-only support job under a scope derived from the durable target.
  The action rechecks the qualified inbox before orchestration starts. Its
  transaction boundaries belong to the workflow, so reads and POSTs run
  outside database transactions.
  """
  use Ash.Resource.Actions.Implementation

  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.{
    ActionScope,
    ChatwootAdapter,
    Delivery,
    InboundEvent,
    OutboundDelivery
  }

  alias VoelgoedAi.Support.{Ownership, Recovery, RunProcessing, SupportRun, SupportSession}

  @doc false
  def invoke(resource, action, id) do
    with {:ok, inbox} when not is_nil(inbox) <- qualified_inbox(resource, id) do
      actor =
        struct!(kind(resource, action),
          action: action,
          resource: resource,
          target: id,
          inbox: inbox
        )

      resource
      |> Ash.ActionInput.for_action(action, %{id: id}, actor: actor)
      |> Ash.run_action()
    end
    |> RunProcessing.job_result()
  end

  @doc false
  def kind(InboundEvent, :process_receipt), do: ActionScope.Processing
  def kind(SupportRun, :process_run), do: ActionScope.Processing
  def kind(SupportRun, :recover_run), do: ActionScope.Reconciliation
  def kind(OutboundDelivery, :deliver_intent), do: ActionScope.Delivery
  def kind(OutboundDelivery, :reconcile_intent), do: ActionScope.Reconciliation
  def kind(OutboundDelivery, :recover_intent), do: ActionScope.Reconciliation
  def kind(_, _), do: nil

  @impl true
  def run(input, _opts, %{actor: actor}) do
    id = input.arguments.id

    with true <- ActionScope.permits?(actor, input),
         {:ok, inbox} when not is_nil(inbox) <- qualified_inbox(input.resource, id),
         true <- inbox == actor.inbox do
      case execute(input.action.name, id) do
        :ok -> {:ok, :ok}
        {:error, _} -> {:error, "support job failed"}
      end
    else
      _ -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp execute(:process_receipt, id), do: RunProcessing.perform_event(id)
  defp execute(:process_run, id), do: RunProcessing.perform_run(id)
  defp execute(:deliver_intent, id), do: Delivery.perform(id)
  defp execute(:reconcile_intent, id), do: Recovery.perform_reconciliation(id)
  defp execute(:recover_run, id), do: Recovery.perform_run_recovery(id)
  defp execute(:recover_intent, id), do: Recovery.perform_delivery_recovery(id)

  defp qualified_inbox(resource, id) do
    Repo.transact(fn ->
      with {:ok, row} <- Ownership.get(resource, id),
           {:ok, target} <- qualified_record(resource, row) do
        case target do
          nil ->
            {:ok, nil}

          row ->
            if ChatwootAdapter.in_scope?(row) do
              {:ok, {row.installation_ref, row.external_account_id, row.external_inbox_id}}
            else
              {:error, :scope_denied}
            end
        end
      end
    end)
  end

  defp qualified_record(_, nil), do: {:ok, nil}
  defp qualified_record(InboundEvent, event), do: {:ok, event}
  defp qualified_record(_, row), do: Ownership.get(SupportSession, row.session_id)
end
