defmodule VoelgoedAi.Support.Operations do
  @moduledoc "Bounded, redacted projections for the staff operations page."

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Governance.{EmergencyOverride, EmbeddingAccounting}
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.Readiness

  @query_options [timeout: 750, checkout_retries: 0, log: false, telemetry_event: nil]

  def access(staff) do
    with {:ok, _} <- operator_roles(staff), do: {:ok, :authorized}
  end

  def snapshot(staff, selected) do
    # Authorization is checked again at the end so a slow projection cannot
    # return information after expiry, revocation or a grant change.
    with {:ok, roles} <- operator_roles(staff) do
      binding = qualified_binding()
      operator = if :support_operator in roles, do: operator(binding, selected)
      admin = if :admin in roles, do: admin(staff, binding)

      case operator_roles(staff) do
        {:ok, ^roles} -> {:ok, %{admin: admin, operator: operator}}
        _ -> {:error, :denied}
      end
    end
  end

  defp operator_roles(staff) do
    with {:ok, roles} <- StaffAccess.current_roles(staff),
         true <- :admin in roles or :support_operator in roles do
      {:ok, roles}
    else
      _ -> {:error, :denied}
    end
  end

  defp admin(staff, binding) do
    configuration = configuration(binding)
    history = history(binding)
    spend = EmbeddingAccounting.staff_exposure(staff)
    readiness = Readiness.check()

    %{
      status: effective_status(readiness),
      readiness: readiness,
      configuration: configuration,
      audit: history,
      spend: spend
    }
  end

  defp effective_status(readiness) do
    case rows("SELECT status, emergency_latched FROM automation_controls WHERE singleton", []) do
      [[status, latched]] ->
        cond do
          EmergencyOverride.blocked?(%{emergency_latched: latched}) -> :emergency_disabled
          status == "disabled" -> :disabled
          status == "enabled" and readiness == :ok -> :enabled
          true -> :configuration_unavailable
        end

      _ ->
        :control_unavailable
    end
  end

  defp history(binding) do
    case rows(
           """
           SELECT event, reason_code, occurred_at FROM audit_events
           WHERE (target_kind = 'automation_control' AND control_target_id =
                    (SELECT id FROM automation_controls WHERE singleton))
              OR (target_kind = 'inbox_binding' AND binding_target_id = $1)
           ORDER BY occurred_at DESC, id DESC LIMIT 25
           """,
           [binding && binding.id]
         ) do
      nil ->
        nil

      records ->
        for [event, reason, at] <- records,
            do: %{event: event, reason_code: reason, occurred_at: at}
    end
  end

  defp rows(query, arguments) do
    case SQL.query(Repo, query, arguments, @query_options) do
      {:ok, %{rows: rows}} -> rows
      {:error, _} -> nil
    end
  end

  if Mix.env() == :test do
    alias VoelgoedAi.Support.{BindingCircuit, ChatwootAdapter}

    defp qualified_binding do
      with %{
             installation_ref: installation,
             external_account_id: account,
             external_inbox_id: inbox
           } <-
             ChatwootAdapter.fixture(),
           scope = [installation, account, inbox],
           [[id]] <-
             rows(
               """
               SELECT id FROM inbox_bindings
               WHERE installation_ref = $1 AND external_account_id = $2 AND external_inbox_id = $3
               """,
               scope
             ) do
        %{id: id, scope: scope}
      else
        _ -> nil
      end
    end

    defp configuration(nil), do: nil

    defp configuration(%{id: id}) do
      case rows(
             """
             SELECT a.status, b.status, b.operating_mode, c.retry_at, c.probe_until, c.permanent_epoch
             FROM inbox_bindings b JOIN assistants a ON a.id = b.assistant_id
             LEFT JOIN support_binding_circuits c ON c.binding_id = b.id
             WHERE b.id = $1
             """,
             [id]
           ) do
        [[assistant, binding, mode, retry_at, probe_until, permanent_epoch]] ->
          %{
            assistant: assistant,
            binding: binding,
            mode: mode,
            circuit:
              BindingCircuit.projection_label(
                retry_at,
                probe_until,
                permanent_epoch,
                ChatwootAdapter.now()
              ),
            binding_id: Ecto.UUID.load!(id)
          }

        _ ->
          nil
      end
    end

    defp operator(nil, _selected),
      do: %{rows: [], detail: nil, alerts: [], available: false, detail_denied: false}

    defp operator(%{id: id} = binding, selected) do
      detail = detail(binding, selected)

      %{
        rows: queue(id),
        detail: detail,
        alerts: alerts(id),
        available: true,
        detail_denied: is_binary(selected) and is_nil(detail)
      }
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
        [binding_id]
      )
    end

    defp alerts(binding_id) do
      rows(
        """
        SELECT kind, opened_at FROM support_alert_episodes
        WHERE binding_id = $1 ORDER BY opened_at DESC, id DESC LIMIT 25
        """,
        [binding_id]
      )
    end

    defp detail(_, nil), do: nil

    defp detail(%{id: binding_id, scope: scope}, selected) do
      with {:ok, id} <- Ecto.UUID.dump(selected),
           [[state, reason]] <-
             rows(
               """
               SELECT state, reason_code FROM support_sessions
               WHERE id = $1 AND binding_id = $2 AND installation_ref = $3
                 AND external_account_id = $4 AND external_inbox_id = $5
               """,
               [id, binding_id | scope]
             ) do
        %{
          session: %{id: Ecto.UUID.load!(id), state: state, reason_code: reason},
          deliveries: deliveries(id),
          draft_id: draft_id(current_draft(id)),
          audit: session_history(id)
        }
      else
        _ -> nil
      end
    end

    defp deliveries(id) do
      case rows(
             """
             SELECT id::text, purpose, state, attempt_count, reason_code, uncertainty_reason
             FROM outbound_deliveries WHERE session_id = $1 ORDER BY id LIMIT 100
             """,
             [id]
           ) do
        nil ->
          nil

        records ->
          for [id, purpose, state, attempts, reason, uncertainty] <- records do
            %{
              id: id,
              purpose: purpose,
              state: state,
              attempt_count: attempts,
              reason_code: reason,
              uncertainty_reason: uncertainty
            }
          end
      end
    end

    defp draft_id([[id]]), do: id
    defp draft_id(_), do: nil

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
        [id, ChatwootAdapter.now()]
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
        [id]
      )
    end
  else
    defp qualified_binding, do: nil
    defp configuration(nil), do: nil

    defp operator(nil, _selected),
      do: %{rows: [], detail: nil, alerts: [], available: false, detail_denied: false}
  end
end
