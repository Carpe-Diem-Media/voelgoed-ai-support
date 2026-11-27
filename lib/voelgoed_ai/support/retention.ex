defmodule VoelgoedAi.Support.Retention do
  @moduledoc """
  Holds, releases and purges a completed synthetic reply. The current fixture
  authorizes a single inbox and grants separate staff approvals per occurrence.
  All writes are excluded from non-TEST builds.
  """

  if Mix.env() == :test do
    use VoelgoedAi.Support.WorkStore, [:create, :update]

    alias Ecto.Adapters.SQL
    alias VoelgoedAi.Accounts.StaffAccess
    alias VoelgoedAi.Governance.AuditEvent
    alias VoelgoedAi.{Repo, Support}
    alias Support.{ChatwootAdapter, Configuration, Ownership, SupportRun}
    alias Support.Workers.Retention, as: Worker

    @scope [:installation_ref, :external_account_id, :external_inbox_id]
    @age_seconds 7 * 86_400
    @max_batch 25

    @doc """
    Apply the exact configured fixture approval for this staff session and run.
    A release either restores PRESENT or purges an eligible reply atomically.
    Returns only the resulting state.
    """
    def staff_transition(session, action, id, approval) when action in [:hold, :release] do
      with true <- disposable_database?(),
           {:ok, ^id} <- Ecto.UUID.cast(id) do
        StaffAccess.with_current(session, :admin, fn staff ->
          with_run(id, fn config, source, run, now ->
            with {:ok, settings} <- current_settings(config),
                 %{token: ^approval, session: ^session, target: ^id, occurrence: occurrence} <-
                   settings[action],
                 {:ok, ^approval} <- Ecto.UUID.cast(approval),
                 true <- run.retention_occurrence == occurrence do
              staff_change(action, staff, source, run, now)
            else
              _ -> {:error, :denied}
            end
          end)
        end)
        |> redact_error()
      else
        _ -> {:error, :denied}
      end
    end

    def staff_transition(_, _, _, _), do: {:error, :denied}

    def sweep(token, cursor, oban) do
      with {:ok, {inbox, batch}} <- start_page(token),
           {:ok, ids} <- candidates(inbox, cursor, batch),
           :ok <- sweep_page(ids, token),
           :ok <- continue_page(ids, batch, token, oban) do
        :ok
      else
        {:error, :denied} ->
          {:discard, :retention_disabled}

        _ ->
          {:error, :retention_failed}
      end
    end

    defp start_page(token) do
      Repo.transact(fn ->
        with true <- disposable_database?(),
             %{inbox: inbox, capability: ^token} <-
               Application.get_env(:voelgoed_ai, :retention_fixture),
             {:ok, config} <- Configuration.lock_inbox(inbox),
             {:ok, %{capability: ^token, batch_size: batch}} <- current_settings(config),
             true <- batch in 1..@max_batch,
             :ok <- expire_windows(config.binding, batch) do
          {:ok, {inbox, batch}}
        else
          {:error, :scope_denied} -> {:error, :denied}
          {:error, _} = error -> error
          _ -> {:error, :denied}
        end
      end)
    end

    defp disposable_database? do
      config = Repo.config()

      config[:hostname] == "127.0.0.1" and config[:port] in [55434, 55436, 55437] and
        config[:username] == "vgas_test" and config[:database] == "vgas_test" and
        System.get_env("VGAS_VERIFY_PGVECTOR") == "true"
    end

    defp current_settings(%{binding: binding, assistant: assistant}) do
      inbox = Map.take(binding, @scope)

      with %{inbox: ^inbox, capability: capability} = settings <-
             Application.get_env(:voelgoed_ai, :retention_fixture),
           {:ok, ^capability} <- Ecto.UUID.cast(capability),
           %{installation_ref: "synthetic", assistant_id: assistant_id} = fixture <-
             ChatwootAdapter.fixture(),
           true <- assistant_id == assistant.id and Map.take(fixture, @scope) == inbox do
        {:ok, settings}
      else
        _ -> {:error, :denied}
      end
    end

    # Admission takes the same global control lock before computing its clock.
    # Delete only expired fixture keys, in the same order in which admission
    # acquires them. Contact and conversation counters are account-wide.
    defp expire_windows(binding, batch) do
      %{external_account_id: account, external_inbox_id: inbox} = binding
      scope = "synthetic:#{account}"
      now = ChatwootAdapter.now() |> DateTime.to_naive()

      with %{global_scope: global} <- ChatwootAdapter.fixture(),
           true <- global == "#{scope}:fixture_global",
           {:ok, _} <-
             SQL.query(
               Repo,
               """
               WITH expired AS (
                 SELECT window_type, scope, starts_at
                 FROM support_admission_windows
                 WHERE expires_at <= $1 AND (
                   (window_type = 'inbox_minute' AND scope = $2)
                   OR (NOT EXISTS (
                     SELECT FROM inbox_bindings WHERE installation_ref = 'synthetic'
                     AND external_account_id = $5 AND external_inbox_id <> $6
                   ) AND (
                     (window_type = 'global_minute' AND scope = $3)
                     OR (window_type IN ('contact_minute','contact_hour','contact_day') AND scope ~ $4)
                     OR (window_type = 'conversation_day' AND scope ~ $7)
                   ))
                 )
                 ORDER BY window_type, scope, starts_at LIMIT $8 FOR UPDATE
               )
               DELETE FROM support_admission_windows windows USING expired
               WHERE (windows.window_type, windows.scope, windows.starts_at) =
                 (expired.window_type, expired.scope, expired.starts_at)
               """,
               [
                 now,
                 "#{scope}:inbox:#{inbox}:input",
                 global,
                 "^#{scope}:contact:[0-9]+:input$",
                 account,
                 inbox,
                 "^#{scope}:conversation:[0-9]+:turn$",
                 batch
               ]
             ) do
        :ok
      else
        _ -> {:error, :retention_failed}
      end
    end

    defp candidates(inbox, cursor, batch) do
      %{installation_ref: installation, external_account_id: account, external_inbox_id: inbox} =
        inbox

      now = ChatwootAdapter.now()
      cutoff = now |> DateTime.add(-@age_seconds) |> DateTime.to_naive()

      with {:ok, %{rows: rows}} <-
             SQL.query(
               Repo,
               """
               SELECT run.id::text
               FROM support_runs run JOIN support_sessions session ON session.id = run.session_id
               WHERE session.installation_ref = $1 AND session.external_account_id = $2
                 AND session.external_inbox_id = $3 AND run.retention_state = 'present'
                 AND run.finished_at <= $4 AND ($5::uuid IS NULL OR run.id > $5)
               ORDER BY run.id LIMIT $6
               """,
               [installation, account, inbox, cutoff, cursor && Ecto.UUID.dump!(cursor), batch]
             ) do
        {:ok, Enum.map(rows, &hd/1)}
      end
    end

    defp sweep_page(ids, token) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        result =
          Repo.transact(fn ->
            with_run(id, fn config, source, run, now ->
              with {:ok, %{capability: ^token}} <- current_settings(config),
                   true <- run.retention_state == :present,
                   {:ok, true} <- eligible(source, run, now) do
                transition(run, :purged, :purge_reply, :synthetic_cutoff, nil, now)
              else
                {:ok, false} -> {:ok, :deferred}
                false -> {:ok, :deferred}
                {:error, _} = error -> error
                _ -> {:error, :denied}
              end
            end)
          end)

        case result do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp continue_page(ids, batch, token, oban) when length(ids) == batch do
      next =
        Worker.new(%{"capability" => token, "after_run" => List.last(ids)},
          unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]
        )

      case Oban.insert((oban && oban.name) || Oban, next) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    defp continue_page(_, _, _, _), do: :ok

    defp with_run(id, operation) do
      with {:ok, %SupportRun{} = candidate} <- Ownership.get(SupportRun, id) do
        Ownership.locked_session(candidate.session_id, fn config, source, _ ->
          with {:ok, _latest} <- Ownership.lock_latest(source),
               {:ok, %SupportRun{session_id: session_id} = run} <-
                 Ownership.get(SupportRun, id, lock: true),
               true <- session_id == source.id do
            operation.(config, source, run, ChatwootAdapter.now())
          else
            _ -> {:error, :denied}
          end
        end)
      else
        {:ok, nil} -> {:ok, :missing}
        error -> error
      end
    end

    defp staff_change(:hold, staff, _, %{retention_state: :present} = run, now),
      do: transition(run, :held, :hold_reply, :fixture_hold, staff, now)

    defp staff_change(:release, staff, source, %{retention_state: :held} = run, now) do
      with {:ok, eligible?} <- eligible(source, run, now) do
        state = if eligible?, do: :purged, else: :present
        transition(run, state, :release_reply, :fixture_release, staff, now)
      end
    end

    defp staff_change(_, _, _, _, _), do: {:error, :denied}

    defp eligible(source, %{state: :completed, finished_at: finished_at}, now) do
      if DateTime.before?(now, DateTime.add(finished_at, @age_seconds)),
        do: {:ok, false},
        else: dependencies_clear(source)
    end

    # These writers all take the global control lock. Read across generations
    # while that lock is held so an older UNKNOWN cannot disappear from scope.
    defp dependencies_clear(session) do
      with {:ok, %{rows: [[clear]]}} <-
             SQL.query(
               Repo,
               """
               WITH sessions AS (
                 SELECT id FROM support_sessions
                 WHERE installation_ref = $1 AND external_account_id = $2
                   AND external_inbox_id = $3 AND conversation_id = $4
               ), runs AS (SELECT id, state FROM support_runs WHERE session_id IN (SELECT id FROM sessions))
               SELECT NOT (
                 EXISTS (SELECT FROM runs WHERE state IN ('queued','running','retry_wait'))
                 OR EXISTS (SELECT FROM outbound_deliveries WHERE session_id IN (SELECT id FROM sessions)
                            AND state IN ('pending','sending','unknown'))
                 OR EXISTS (SELECT FROM inference_runs i LEFT JOIN usage_reservations r ON r.inference_run_id = i.id
                            WHERE i.support_run_id IN (SELECT id FROM runs)
                             AND (i.state IN ('queued','running','unknown') OR r.state IN ('reserved','unknown')
                              OR (i.overflow_evidence IS NOT NULL AND i.overflow_resolved_at IS NULL)))
                 OR EXISTS (SELECT FROM knowledge_gaps WHERE support_run_id IN (SELECT id FROM runs)
                            AND status IN ('open','in_review'))
                 OR EXISTS (SELECT FROM inbound_events WHERE installation_ref = $1 AND external_account_id = $2
                            AND external_inbox_id = $3 AND conversation_id = $4 AND kind = 'input'
                            AND state = 'dispatched' AND disposition = 'pending')
               )
               """,
               Enum.map(@scope ++ [:conversation_id], &Map.fetch!(session, &1))
             ) do
        {:ok, clear}
      end
    end

    defp transition(run, state, event, reason, staff, now) do
      occurrence = Ash.UUIDv7.generate()

      decision =
        if state == :purged,
          do: %{run.typed_decision | reply_text: nil, purged?: true},
          else: run.typed_decision

      audit = %{
        actor_kind: if(staff, do: :staff, else: :support_worker),
        actor_staff_id: staff && staff.id,
        target_kind: :support_run,
        run_target_id: run.id,
        event: event,
        reason_code: reason,
        correlation_id: run.correlation_id,
        occurred_at: now,
        operational_before: retention_fact(run.retention_state, run.retention_occurrence),
        operational_after: retention_fact(state, occurrence)
      }

      with {:ok, _} <-
             store_update(run, :transition_retention, %{
               retention_state: state,
               retention_occurrence: occurrence,
               typed_decision: decision
             }),
           {:ok, _} <- store_create(AuditEvent, :append_retention, audit) do
        {:ok, state}
      end
    end

    defp retention_fact(state, nil), do: %{status: state}
    defp retention_fact(state, occurrence), do: %{status: state, retention_occurrence: occurrence}

    defp redact_error({:ok, state}) when state in [:present, :held, :purged], do: {:ok, state}
    defp redact_error({:error, :denied}), do: {:error, :denied}
    defp redact_error({:ok, :missing}), do: {:error, :denied}
    defp redact_error(_), do: {:error, :retention_failed}
  else
    @doc "Reject fixture retention approvals outside TEST."
    def staff_transition(_, _, _, _), do: {:error, :denied}
    def sweep(_, _, _), do: {:discard, :retention_disabled}
  end
end
