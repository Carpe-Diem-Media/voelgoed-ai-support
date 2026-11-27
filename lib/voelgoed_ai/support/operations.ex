defmodule VoelgoedAi.Support.Operations do
  @moduledoc "Bounded, redacted projections for the staff operations page."

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Governance.{AuditEvent, EmergencyOverride, EmbeddingAccounting}
  alias VoelgoedAi.Support.{Configuration, Readiness}

  def access(staff) do
    StaffAccess.with_current(staff, nil, fn row ->
      if :admin in row.roles or :support_operator in row.roles,
        do: {:ok, :authorized},
        else: {:error, :denied}
    end)
  end

  def snapshot(staff, selected) do
    readiness = Readiness.check()

    StaffAccess.with_current(staff, nil, fn row ->
      with true <- :admin in row.roles or :support_operator in row.roles,
           {:ok, admin} <- admin(staff, :admin in row.roles, readiness),
           {:ok, operator} <- operator(staff, :support_operator in row.roles, selected) do
        {:ok, %{admin: admin, operator: operator}}
      else
        false -> {:error, :denied}
        error -> error
      end
    end)
  end

  defp admin(_, false, _), do: {:ok, nil}

  defp admin(staff, true, readiness) do
    with {:ok, control} <- Configuration.lock_control(),
         {:ok, configuration} <- configuration(),
         {:ok, audit} <- history(staff, :automation_control, control.id),
         {:ok, binding_audit} <- binding_history(staff, configuration) do
      {:ok,
       %{
         status: effective_status(control, readiness),
         readiness: readiness,
         configuration: configuration,
         spend: EmbeddingAccounting.staff_exposure(staff),
         audit:
           (audit ++ binding_audit)
           |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
           |> Enum.take(25)
           |> Enum.map(&Map.take(&1, [:event, :reason_code, :occurred_at]))
       }}
    end
  end

  defp effective_status(control, readiness) do
    cond do
      EmergencyOverride.blocked?(control) -> :emergency_disabled
      control.status == :disabled -> :disabled
      readiness == :ok -> :enabled
      true -> :configuration_unavailable
    end
  end

  defp history(staff, kind, id) do
    AuditEvent
    |> Ash.ActionInput.for_action(
      :operational_history,
      %{target_kind: kind, id: id},
      actor: staff
    )
    |> Ash.run_action()
  end

  if Mix.env() == :test do
    alias Ecto.Adapters.SQL
    alias VoelgoedAi.{Repo, Support}
    alias VoelgoedAi.Support.{BindingCircuit, ChatwootAdapter, Ownership}

    @timeout 750

    defp configuration do
      with %{} = fixture <- ChatwootAdapter.fixture(),
           {:ok, config} <- Configuration.lock_inbox(inbox(fixture)) do
        {:ok,
         %{
           assistant: config.assistant.status,
           binding: config.binding.status,
           mode: config.binding.operating_mode,
           circuit: BindingCircuit.label(config.binding),
           binding_id: config.binding.id
         }}
      else
        nil -> {:ok, nil}
        {:error, :scope_denied} -> {:ok, nil}
        error -> error
      end
    end

    defp binding_history(_, nil), do: {:ok, []}

    defp binding_history(staff, configuration),
      do: history(staff, :inbox_binding, configuration.binding_id)

    defp operator(_, false, _), do: {:ok, nil}

    defp operator(staff, true, selected) do
      with %{} = fixture <- ChatwootAdapter.fixture(),
           {:ok, config} <- Configuration.lock_inbox(inbox(fixture)),
           {:ok, rows} <- queue(config.binding.id),
           {:ok, alerts} <- alerts(config.binding.id),
           {:ok, detail} <- detail(staff, selected) do
        {:ok,
         %{
           rows: rows,
           detail: detail,
           alerts: alerts,
           available: true,
           detail_denied: is_binary(selected) and is_nil(detail)
         }}
      else
        nil ->
          {:ok, %{rows: [], detail: nil, alerts: [], available: false, detail_denied: false}}

        {:error, :scope_denied} ->
          {:ok, %{rows: [], detail: nil, alerts: [], available: false, detail_denied: false}}

        error ->
          error
      end
    end

    defp queue(binding_id) do
      rows(
        """
        SELECT s.id::text, s.state, s.reason_code, s.updated_at,
               EXISTS (
                 SELECT 1 FROM outbound_deliveries d
                 WHERE d.session_id = s.id AND d.state = 'unknown'
               )
        FROM support_sessions s
        WHERE s.binding_id = $1 AND (
          s.state IN ('bot_active', 'handoff_pending') OR
          EXISTS (SELECT 1 FROM outbound_deliveries d WHERE d.session_id = s.id AND d.state = 'unknown')
        )
        ORDER BY s.updated_at DESC, s.id DESC LIMIT 25
        """,
        [Ecto.UUID.dump!(binding_id)]
      )
    end

    defp alerts(binding_id) do
      rows(
        """
        SELECT kind, opened_at FROM support_alert_episodes
        WHERE binding_id = $1 ORDER BY opened_at DESC, id DESC LIMIT 25
        """,
        [Ecto.UUID.dump!(binding_id)]
      )
    end

    defp detail(_, nil), do: {:ok, nil}

    defp detail(staff, id) do
      with {:ok, id} <- Ecto.UUID.cast(id),
           {:ok, session} <-
             Ownership.locked_session(id, fn _, row, _ ->
               {:ok, Map.take(row, [:id, :state, :reason_code])}
             end),
           {:ok, deliveries} <- Support.reconciliation_projection(staff, id),
           {:ok, [[draft_id]]} <- current_draft(id),
           {:ok, audit} <- session_history(id) do
        {:ok, %{session: session, deliveries: deliveries, draft_id: draft_id, audit: audit}}
      else
        _ -> {:ok, nil}
      end
    end

    defp current_draft(id) do
      rows(
        """
        SELECT (SELECT r.id::text FROM support_runs r JOIN support_sessions s ON s.id = r.session_id
          JOIN inbox_bindings b ON b.id = s.binding_id JOIN assistants a ON a.id = b.assistant_id
          CROSS JOIN automation_controls c
          WHERE r.session_id = $1 AND r.assisted_draft AND r.state = 'completed'
            AND r.retention_state IS DISTINCT FROM 'purged' AND r.retention_state IS DISTINCT FROM 'held'
            AND s.state = 'bot_active' AND NOT s.human_inhibit AND b.operating_mode = 'assisted'
            AND c.status = 'enabled' AND NOT c.emergency_latched
            AND r.ownership_epoch = s.ownership_epoch AND r.control_epoch = c.security_epoch
            AND r.binding_epoch = b.security_epoch AND r.assistant_epoch = a.security_epoch
            AND r.deadline_at > $2 ORDER BY r.finished_at DESC, r.id DESC LIMIT 1)
        """,
        [Ecto.UUID.dump!(id), ChatwootAdapter.now()]
      )
    end

    defp session_history(id) do
      rows(
        """
        SELECT event, reason_code, occurred_at FROM audit_events
        WHERE session_target_id = $1 OR delivery_target_id IN (
          SELECT id FROM outbound_deliveries WHERE session_id = $1
        )
        ORDER BY occurred_at DESC, id DESC LIMIT 25
        """,
        [Ecto.UUID.dump!(id)]
      )
    end

    defp rows(query, arguments) do
      case SQL.query(Repo, query, arguments, timeout: @timeout, log: false, telemetry_event: nil) do
        {:ok, %{rows: rows}} -> {:ok, rows}
        {:error, _} -> {:error, :unavailable}
      end
    end

    defp inbox(row),
      do: Map.take(row, [:installation_ref, :external_account_id, :external_inbox_id])
  else
    defp configuration, do: {:ok, nil}
    defp binding_history(_, _), do: {:ok, []}
    defp operator(_, false, _), do: {:ok, nil}

    defp operator(_, true, _),
      do: {:ok, %{rows: [], detail: nil, alerts: [], available: false, detail_denied: false}}
  end
end
