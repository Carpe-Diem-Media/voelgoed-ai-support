defmodule VoelgoedAi.Support.OperationalAlert do
  @moduledoc """
  Publishes local telemetry for work that needs operator attention. Events
  carry internal IDs and typed reasons, without provider data or payloads.
  Call after the transition has committed.
  """

  alias VoelgoedAi.Support.{InboundEvent, OutboundDelivery, SupportRun}

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  @doc false
  def record(binding_id, kind, episode, now)
      when kind in [:circuit_open, :delivery_unknown, :handoff_failed] do
    SQL.query!(
      Repo,
      """
      INSERT INTO support_alert_episodes (id, binding_id, kind, episode, opened_at)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (binding_id, kind, episode) DO NOTHING
      """,
      [uuid(Ash.UUIDv7.generate()), uuid(binding_id), Atom.to_string(kind), episode, now],
      telemetry_event: nil
    )

    :ok
  end

  @doc false
  def delivery_fact(row, kind) when kind in [:delivery_unknown, :handoff_failed] do
    case SQL.query!(
           Repo,
           "SELECT binding_id::text FROM support_sessions WHERE id = $1",
           [uuid(row.session_id)],
           telemetry_event: nil
         ).rows do
      [[binding]] -> record(binding, kind, row.id, DateTime.utc_now())
    end
  end

  def delivery_fact(_, _), do: :ok

  @doc false
  def scan_queue(binding, now) do
    result =
      SQL.query!(
        Repo,
        """
        SELECT EXISTS (SELECT 1 FROM inbound_events
          WHERE installation_ref = $1 AND external_account_id = $2 AND external_inbox_id = $3
            AND state = 'dispatched' AND disposition = 'pending' AND received_at <= $4)
        """,
        [
          binding.installation_ref,
          binding.external_account_id,
          binding.external_inbox_id,
          DateTime.add(now, -45)
        ],
        telemetry_event: nil
      )

    if result.rows == [[true]] do
      id = Ash.UUIDv7.generate()

      SQL.query!(
        Repo,
        """
        INSERT INTO support_alert_episodes (id, binding_id, kind, episode, opened_at)
        VALUES ($1, $2, 'queue_overdue', $3, $4)
        ON CONFLICT (binding_id) WHERE kind = 'queue_overdue' AND closed_at IS NULL DO NOTHING
        """,
        [uuid(id), uuid(binding.id), id, now],
        telemetry_event: nil
      )
    else
      SQL.query!(
        Repo,
        """
        UPDATE support_alert_episodes SET closed_at = $2
        WHERE binding_id = $1 AND kind = 'queue_overdue' AND closed_at IS NULL
        """,
        [uuid(binding.id), now],
        telemetry_event: nil
      )
    end

    :ok
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

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
