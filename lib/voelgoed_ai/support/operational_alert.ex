defmodule VoelgoedAi.Support.OperationalAlert do
  @moduledoc """
  Publishes local telemetry for work that needs operator attention. Events
  carry internal IDs and typed reasons, without provider data or payloads.
  Call after the transition has committed.
  """

  alias VoelgoedAi.Support.{InboundEvent, OutboundDelivery, SupportRun}

  def report(%InboundEvent{disposition: :triage} = event),
    do: emit(:receipt_triage, :event_id, event, event.disposition, event.reason_code)

  def report(%SupportRun{state: :failed} = run),
    do: emit(:run_attention, :run_id, run, run.state, run.reason_code)

  def report(%OutboundDelivery{state: :unknown} = intent),
    do:
      emit(
        :delivery_attention,
        :delivery_id,
        intent,
        intent.state,
        intent.reason_code || intent.uncertainty_reason
      )

  def report(%OutboundDelivery{purpose: :handoff_status, state: state} = intent)
      when state in [:failed, :cancelled],
      do: emit(:delivery_attention, :delivery_id, intent, state, intent.reason_code)

  def report(_), do: :ok

  defp emit(event, id_key, row, state, reason) do
    :telemetry.execute([:voelgoed_ai, :support, event], %{count: 1}, %{
      id_key => row.id,
      correlation_id: row.correlation_id,
      state: state,
      reason: reason
    })
  end
end
