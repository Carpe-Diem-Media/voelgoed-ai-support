defmodule VoelgoedAi.Support.OperationalAlert do
  @moduledoc """
  Publishes local telemetry for work that needs operator attention. Events
  carry internal IDs and typed reasons, without provider data or payloads.
  Call after the transition has committed.
  """

  alias VoelgoedAi.Support.{InboundEvent, OutboundDelivery, SupportRun}

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  @batch_size 25
  @query_options [timeout: 1_000, log: false, telemetry_event: nil]

  @doc false
  def project(binding, now) do
    with false <- Repo.in_transaction?(),
         {:ok, :projected} <-
           Repo.transact(
             fn ->
               with {:ok, _} <- query("SET LOCAL statement_timeout = '750ms'", []),
                    {:ok, _} <- project_circuits(binding),
                    {:ok, _} <- project_deliveries(binding),
                    {:ok, _} <- scan_queue(binding, now) do
                 {:ok, :projected}
               end
             end,
             timeout: 4_000
           ) do
      :ok
    else
      _ -> projection_failed(binding)
    end
  rescue
    DBConnection.ConnectionError -> projection_failed(binding)
  end

  defp projection_failed(binding) do
    :telemetry.execute([:voelgoed_ai, :support, :alert_projection_failed], %{count: 1}, %{
      binding_id: binding.id,
      reason: :alert_projection_unavailable
    })

    {:error, :alert_projection_unavailable}
  end

  defp project_circuits(binding) do
    query(
      """
      WITH pending AS (
        SELECT generation, opened_at FROM support_circuit_alerts_pending
        WHERE binding_id = $1 ORDER BY generation
        LIMIT $2 FOR UPDATE SKIP LOCKED
      ), projected AS (
        INSERT INTO support_alert_episodes (id, binding_id, kind, episode, opened_at)
        SELECT uuidv7(), $1, 'circuit_open', generation::text, opened_at FROM pending
        ON CONFLICT (binding_id, kind, episode) DO NOTHING
      )
      DELETE FROM support_circuit_alerts_pending
      WHERE binding_id = $1 AND generation IN (SELECT generation FROM pending)
      """,
      [uuid(binding.id), @batch_size]
    )
  end

  defp project_deliveries(binding) do
    query(
      """
      INSERT INTO support_alert_episodes (id, binding_id, kind, episode, opened_at)
      SELECT uuidv7(), $1, facts.event, facts.delivery_id::text, facts.opened_at
      FROM (
        SELECT a.event, d.id AS delivery_id, min(a.occurred_at) AS opened_at
        FROM support_sessions s
        JOIN outbound_deliveries d ON d.session_id = s.id
        JOIN audit_events a ON a.delivery_target_id = d.id
        WHERE s.binding_id = $1 AND a.event IN ('delivery_unknown', 'handoff_failed')
          AND NOT EXISTS (
            SELECT 1 FROM support_alert_episodes e
            WHERE e.binding_id = $1 AND e.kind = a.event AND e.episode = d.id::text
          )
        GROUP BY a.event, d.id
        ORDER BY min(a.occurred_at), d.id, a.event
        LIMIT $2
      ) facts
      ON CONFLICT (binding_id, kind, episode) DO NOTHING
      """,
      [uuid(binding.id), @batch_size]
    )
  end

  defp scan_queue(binding, now) do
    with {:ok, %{rows: [[overdue]]}} <-
           query(
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
             ]
           ) do
      queue_episode(binding.id, now, overdue)
    end
  end

  defp queue_episode(binding_id, now, true) do
    id = Ash.UUIDv7.generate()

    query(
      """
      INSERT INTO support_alert_episodes (id, binding_id, kind, episode, opened_at)
      VALUES ($1, $2, 'queue_overdue', $3, $4)
      ON CONFLICT (binding_id) WHERE kind = 'queue_overdue' AND closed_at IS NULL DO NOTHING
      """,
      [uuid(id), uuid(binding_id), id, now]
    )
  end

  defp queue_episode(binding_id, now, false) do
    query(
      """
      UPDATE support_alert_episodes SET closed_at = $2
      WHERE binding_id = $1 AND kind = 'queue_overdue' AND closed_at IS NULL AND opened_at <= $2
      """,
      [uuid(binding_id), now]
    )
  end

  defp query(statement, args), do: SQL.query(Repo, statement, args, @query_options)

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
