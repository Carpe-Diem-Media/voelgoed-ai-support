defmodule VoelgoedAi.Feasibility.ChatwootMigration do
  @moduledoc false
  use Ecto.Migration

  def up do
    Oban.Migration.up(prefix: prefix(), create_schema: false, repo: repo())
    schema = prefix()

    execute("""
    CREATE TABLE #{schema}.inbound_events (
      id uuid PRIMARY KEY,
      installation text NOT NULL,
      account_id bigint NOT NULL CHECK (account_id > 0),
      inbox_id bigint NOT NULL CHECK (inbox_id > 0),
      conversation_id bigint NOT NULL CHECK (conversation_id > 0),
      contact_id bigint NOT NULL CHECK (contact_id > 0),
      message_id bigint CHECK (message_id > 0),
      event_type text NOT NULL,
      outcome text NOT NULL CHECK (outcome IN ('dispatched','ignored')),
      purpose text NOT NULL CHECK (purpose IN ('input','human_reply','ignore')),
      received_at timestamptz NOT NULL,
      processed boolean NOT NULL DEFAULT false,
      decision text,
      UNIQUE (installation, account_id, event_type, message_id)
    )
    """)

    execute("""
    CREATE TABLE #{schema}.sessions (
      id uuid PRIMARY KEY,
      installation text NOT NULL,
      account_id bigint NOT NULL,
      inbox_id bigint NOT NULL,
      conversation_id bigint NOT NULL,
      contact_id bigint NOT NULL,
      state text NOT NULL CHECK (state IN ('unverified','bot_active','handoff_pending','human_active','closed')),
      epoch bigint NOT NULL DEFAULT 0,
      last_verified_at timestamptz,
      active_event uuid REFERENCES #{schema}.inbound_events(id),
      UNIQUE (installation, account_id, conversation_id)
    )
    """)

    execute("""
    CREATE TABLE #{schema}.deliveries (
      id uuid PRIMARY KEY,
      session_id uuid NOT NULL REFERENCES #{schema}.sessions(id),
      event_id uuid NOT NULL REFERENCES #{schema}.inbound_events(id),
      kind text NOT NULL CHECK (kind IN ('reply','handoff')),
      state text NOT NULL CHECK (state IN ('pending','sending','sent','failed','cancelled','unknown')),
      epoch bigint NOT NULL,
      generation bigint NOT NULL DEFAULT 0,
      attempts integer NOT NULL DEFAULT 0 CHECK (attempts IN (0,1)),
      read_attempts integer NOT NULL DEFAULT 0 CHECK (read_attempts >= 0),
      deadline timestamptz NOT NULL,
      claimed_at timestamptz,
      finished_at timestamptz,
      external_message_id bigint CHECK (external_message_id > 0),
      reason text,
      recovery_failure text,
      UNIQUE (event_id, kind)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX one_outstanding_reply ON #{schema}.deliveries (session_id)
    WHERE kind = 'reply' AND state IN ('pending','sending','unknown')
    """)
  end
end

defmodule VoelgoedAi.Feasibility.ChatwootStore do
  @moduledoc """
  Isolated PostgreSQL receipts, ownership and delivery intents for the F06 tests.
  Receipt insertion admits one job. Session row locks serialize decision, claim
  and settlement. Request adapters run after the corresponding transaction commits.
  """
  alias VoelgoedAi.Feasibility.{
    ChatwootDeadlineJob,
    ChatwootDeliveryJob,
    ChatwootIngressJob,
    ChatwootMigration,
    ChatwootRecoveryJob,
    ChatwootReconcileJob
  }

  alias VoelgoedAi.Repo

  @reply_deadline_seconds 45
  @reply_max_reads 1
  @claim_lease_microseconds 5_000_000
  # G013 gives operational handoff its own five-minute recovery window and three
  # safe attempts. This budget never authorizes a second POST.
  @handoff_recovery_seconds 300
  @handoff_max_attempts 3

  @columns Map.new(
             ~w(id installation account_id inbox_id conversation_id contact_id message_id event_type outcome
       purpose received_at processed decision state epoch last_verified_at active_event session_id
       event_id kind generation attempts read_attempts deadline claimed_at finished_at external_message_id
       reason recovery_failure)a,
             &{Atom.to_string(&1), &1}
           )

  def new_prefix, do: "vgas_f06_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  def create!(prefix) do
    %{rows: [["vgas_test", "vgas_test"]]} = Repo.query!("SELECT current_database(), current_user")

    unless Regex.match?(~r/\Avgas_f06_[0-9a-f]{16}\z/, prefix),
      do: raise(ArgumentError, "invalid F06 schema prefix")

    Repo.query!("CREATE SCHEMA #{prefix}")
  end

  def migrate!(prefix) do
    :ok =
      Ecto.Migrator.up(Repo, 1, ChatwootMigration,
        prefix: prefix,
        migration_lock: false,
        log: false
      )

    14 = Oban.Migration.migrated_version(prefix: prefix, repo: Repo)
  end

  def drop!(prefix) do
    unless Regex.match?(~r/\Avgas_f06_[0-9a-f]{16}\z/, prefix),
      do: raise(ArgumentError, "invalid F06 schema prefix")

    Repo.query!("DROP SCHEMA #{prefix} CASCADE")

    %{rows: [[false]]} =
      Repo.query!("SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = $1)", [prefix])
  end

  def receipt(%{prefix: p, oban: oban} = ctx, event, purpose) do
    Repo.transaction(fn ->
      checkpoint(ctx, :before_receipt)
      id = Ash.UUIDv7.generate()
      outcome = if purpose == "ignore", do: "ignored", else: "dispatched"

      %{num_rows: count} =
        query!(
          """
          INSERT INTO #{p}.inbound_events
            (id, installation, account_id, inbox_id, conversation_id, contact_id, message_id,
             event_type, outcome, purpose, received_at)
          VALUES ($1::text::uuid,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
          ON CONFLICT (installation, account_id, event_type, message_id) DO NOTHING
          """,
          [
            id,
            event.installation,
            event.account_id,
            event.inbox_id,
            event.conversation_id,
            event.contact_id,
            event.message_id,
            event.event_type,
            outcome,
            purpose,
            ctx.now.()
          ]
        )

      if count == 1 and outcome == "dispatched" do
        if purpose == "human_reply" do
          # CE can leave a conversation pending after a public human reply.
          # Commit the inhibit with the receipt, before either job queue can act on it.
          observe(ctx, session_for(p, event, :human), :human)
        end

        enqueue!(oban, ChatwootIngressJob.new(%{"event_id" => id}))
        checkpoint(ctx, :after_receipt_enqueue)
      end

      :ok
    end)
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, :storage_unavailable}
  end

  def event(p, id), do: one!("SELECT * FROM #{p}.inbound_events WHERE id = $1::text::uuid", [id])

  def delivery(p, id) do
    one!(
      """
      SELECT d.*, e.installation, e.account_id, e.inbox_id, e.conversation_id, e.contact_id, e.message_id
      FROM #{p}.deliveries d JOIN #{p}.inbound_events e ON d.event_id = e.id
      WHERE d.id = $1::text::uuid
      """,
      [id]
    )
  end

  def decide(%{prefix: p, oban: oban} = ctx, id, event, ownership) do
    Repo.transaction(fn ->
      session = session_for(p, event, ownership)
      session = observe(ctx, session, ownership)

      current =
        one!("SELECT processed FROM #{p}.inbound_events WHERE id = $1::text::uuid FOR UPDATE", [
          id
        ])

      unless current.processed do
        admission =
          case {event.purpose, session, ownership} do
            {"input", %{state: "bot_active", active_event: active_event} = session, :bot}
            when is_nil(active_event) or ctx.decision == "handoff" ->
              kind = ctx.decision

              epoch =
                if kind == "handoff",
                  do: fence(ctx, session, "handoff_pending"),
                  else: session.epoch

              delivery_id = Ash.UUIDv7.generate()
              deadline = deadline(ctx, event, kind)

              query!(
                """
                INSERT INTO #{p}.deliveries (id, session_id, event_id, kind, state, epoch, deadline)
                VALUES ($1::text::uuid,$2,$3::text::uuid,$4,'pending',$5,$6)
                """,
                [delivery_id, session.id, id, kind, epoch, deadline]
              )

              query!("UPDATE #{p}.sessions SET active_event = $2::text::uuid WHERE id = $1", [
                session.id,
                id
              ])

              max_attempts = if kind == "handoff", do: @handoff_max_attempts, else: 1

              enqueue!(
                oban,
                ChatwootDeliveryJob.new(%{"delivery_id" => delivery_id},
                  max_attempts: max_attempts
                )
              )

              enqueue!(
                oban,
                ChatwootDeadlineJob.new(%{"delivery_id" => delivery_id}, scheduled_at: deadline)
              )

              checkpoint(ctx, :after_decision_enqueue)
              kind

            _ ->
              "no_write"
          end

        query!(
          "UPDATE #{p}.inbound_events SET processed = true, decision = $2 WHERE id = $1::text::uuid",
          [id, admission]
        )
      end

      :ok
    end)
  end

  @doc "Spend one delivery read attempt before entering the HTTP adapter."
  def reserve_read(%{prefix: p} = ctx, delivery, state) do
    limit = if delivery.kind == "reply", do: @reply_max_reads, else: @handoff_max_attempts

    case query!(
           """
           UPDATE #{p}.deliveries SET read_attempts = read_attempts + 1
           WHERE id = $1 AND state = $2
             AND deadline > $3 AND read_attempts < $4 AND recovery_failure IS NULL
           RETURNING read_attempts
           """,
           [delivery.id, state, ctx.now.(), limit]
         ) do
      %{rows: [[attempt]]} -> {:ok, attempt}
      %{rows: []} -> :unavailable
    end
  end

  def claim(%{prefix: p, oban: oban} = ctx, delivery, ownership, read_attempt) do
    Repo.transaction(fn ->
      session = lock_session(p, delivery.session_id)
      current = lock_delivery(p, delivery.id)

      if current.state == "pending" do
        cond do
          not DateTime.before?(ctx.now.(), current.deadline) ->
            expire_current(ctx, current)

          ownership == :closed ->
            observe(ctx, session, :closed)

          ownership == :human and current.kind == "handoff" and
            session.state == "handoff_pending" and session.epoch == current.epoch ->
            finish(ctx, current, "sent", "goal_observed", nil)
            observe(ctx, session, :human)

          ownership == :human ->
            observe(ctx, session, :human)

          session.epoch != current.epoch or session.active_event != current.event_id or
              not allowed?(session.state, current.kind) ->
            finish(ctx, current, "cancelled", "guard_denied", nil)

          current.kind == "handoff" and ownership == :transient_read_error and
              read_attempt < @handoff_max_attempts ->
            :retry_preflight

          current.kind == "handoff" and ownership == :transient_read_error ->
            finish(ctx, current, "failed", "handoff_preflight_exhausted", nil)

          current.kind == "handoff" and ownership == :unknown ->
            finish(ctx, current, "failed", "handoff_ownership_unverified", nil)

          ownership == :bot ->
            claimed_at = ctx.now.()

            %{rows: [[generation]]} =
              query!(
                """
                UPDATE #{p}.deliveries
                SET state = 'sending', generation = generation + 1, attempts = 1, claimed_at = $2
                WHERE id = $1 RETURNING generation
                """,
                [current.id, claimed_at]
              )

            # Persist recovery with the claim since Oban may discard the lost write job.
            enqueue!(
              oban,
              ChatwootRecoveryJob.new(%{"delivery_id" => Ecto.UUID.load!(current.id)},
                scheduled_at: claim_expires_at(claimed_at)
              )
            )

            {:send, generation}

          ownership == :stale ->
            finish(ctx, current, "cancelled", "uncovered_input_review", nil)

          true ->
            finish(ctx, current, "cancelled", "guard_denied", nil)
        end
      end
    end)
  end

  def settle(%{prefix: p} = ctx, delivery, generation, {state, reason, external_id}) do
    Repo.transaction(fn ->
      session = lock_session(p, delivery.session_id)
      current = lock_delivery(p, delivery.id)

      if current.state == "sending" and current.generation == generation do
        cond do
          session.epoch != current.epoch ->
            mark_unknown(ctx, current, "ownership_changed_during_send")

          state == "unknown" ->
            mark_unknown(ctx, current, reason)

          state == "sent" and current.kind == "handoff" and
              not DateTime.before?(ctx.now.(), current.deadline) ->
            mark_unknown(ctx, current, "handoff_unconfirmed")

          state == "sent" and current.kind == "handoff" ->
            finish(ctx, current, state, reason, external_id)
            observe(ctx, session, :human)

          true ->
            finish(ctx, current, state, reason, external_id)
        end
      end
    end)
  end

  def recover(%{prefix: p} = ctx, delivery) do
    Repo.transaction(fn ->
      lock_session(p, delivery.session_id)
      current = lock_delivery(p, delivery.id)

      if current.state == "sending" and current.generation == delivery.generation do
        expires_at = claim_expires_at(current.claimed_at)
        now = ctx.now.()

        if DateTime.before?(now, expires_at) do
          {:snooze, DateTime.diff(expires_at, now) + 1}
        else
          mark_unknown(ctx, current, "claim_expired")
        end
      end
    end)
  end

  defp claim_expires_at(claimed_at),
    do: DateTime.add(claimed_at, @claim_lease_microseconds, :microsecond)

  def record_handoff_read(%{prefix: p} = ctx, delivery, attempt, ownership) do
    Repo.transaction(fn ->
      session = lock_session(p, delivery.session_id)
      current = lock_delivery(p, delivery.id)

      if current.state == "unknown" and current.kind == "handoff" do
        cond do
          not DateTime.before?(ctx.now.(), current.deadline) ->
            expire_current(ctx, current)

          ownership == :human and session.state in ["handoff_pending", "human_active"] ->
            finish(ctx, current, "sent", "goal_observed", nil)
            observe(ctx, session, :human)

          ownership == :closed or session.state == "closed" ->
            observe(ctx, session, :closed)
            recovery_failed(ctx, current, "handoff_conversation_closed")

          attempt == @handoff_max_attempts ->
            recovery_failed(ctx, current, "handoff_read_budget_exhausted")

          is_nil(current.recovery_failure) ->
            :retry_read

          true ->
            :ok
        end
      end
    end)
  end

  @doc "Close overdue automation work without making a remote request."
  def expire(%{prefix: p} = ctx, delivery) do
    Repo.transaction(fn ->
      lock_session(p, delivery.session_id)
      current = lock_delivery(p, delivery.id)

      if not DateTime.before?(ctx.now.(), current.deadline), do: expire_current(ctx, current)
    end)
  end

  @doc "Find overdue intents even if Oban discarded an individual deadline job."
  def sweep_deadlines(%{prefix: p} = ctx) do
    %{rows: rows} =
      query!(
        """
        SELECT id, session_id FROM #{p}.deliveries
        WHERE deadline <= $1 AND (
          state IN ('pending', 'sending')
          OR (kind = 'handoff' AND state = 'unknown' AND recovery_failure IS NULL)
        )
        """,
        [ctx.now.()]
      )

    Enum.each(rows, fn [id, session_id] ->
      {:ok, _} = expire(ctx, %{id: id, session_id: session_id})
    end)
  end

  defp expire_current(ctx, %{kind: "reply", state: "pending"} = current),
    do: finish(ctx, current, "cancelled", "reply_deadline_exceeded", nil)

  defp expire_current(ctx, %{kind: "handoff", state: "pending"} = current),
    do: finish(ctx, current, "failed", "handoff_deadline_exceeded", nil)

  defp expire_current(ctx, %{state: "sending"} = current),
    do: mark_unknown(ctx, current, "claim_expired")

  defp expire_current(ctx, %{kind: "handoff", state: "unknown"} = current),
    do: recovery_failed(ctx, current, "handoff_read_deadline_exceeded")

  defp expire_current(_ctx, _current), do: :ok

  defp mark_unknown(ctx, current, reason) do
    finish(ctx, current, "unknown", reason, nil)

    if current.kind == "handoff" do
      cond do
        not DateTime.before?(ctx.now.(), current.deadline) ->
          recovery_failed(ctx, current, "handoff_read_deadline_exceeded")

        current.read_attempts >= @handoff_max_attempts ->
          recovery_failed(ctx, current, "handoff_read_budget_exhausted")

        true ->
          enqueue!(
            ctx.oban,
            ChatwootReconcileJob.new(%{"delivery_id" => Ecto.UUID.load!(current.id)})
          )
      end
    end

    :ok
  end

  defp recovery_failed(%{prefix: p}, delivery, reason) do
    query!(
      "UPDATE #{p}.deliveries SET recovery_failure = $2 WHERE id = $1 AND recovery_failure IS NULL",
      [delivery.id, reason]
    )

    :ok
  end

  defp deadline(ctx, _event, "handoff"), do: DateTime.add(ctx.now.(), @handoff_recovery_seconds)

  defp deadline(_ctx, event, "reply"),
    do: DateTime.add(event.received_at, @reply_deadline_seconds)

  defp session_for(p, event, ownership) do
    key = [event.installation, event.account_id, event.conversation_id]

    # An observation can arrive before any input. Persist verified human control
    # under the same qualified key and lock that later inputs use.
    if ownership == :human or (event.purpose == "input" and ownership in [:bot, :closed]) do
      query!(
        """
        INSERT INTO #{p}.sessions (installation, account_id, conversation_id, id, inbox_id, contact_id, state)
        VALUES ($1,$2,$3,$4::text::uuid,$5,$6,'unverified')
        ON CONFLICT (installation, account_id, conversation_id) DO NOTHING
        """,
        key ++ [Ash.UUIDv7.generate(), event.inbox_id, event.contact_id]
      )
    end

    case one!(
           """
           SELECT * FROM #{p}.sessions
           WHERE installation = $1 AND account_id = $2 AND conversation_id = $3 FOR UPDATE
           """,
           key
         ) do
      %{inbox_id: inbox, contact_id: contact} = session
      when inbox == event.inbox_id and contact == event.contact_id ->
        session

      _ ->
        nil
    end
  end

  defp observe(_ctx, nil, _ownership), do: nil
  defp observe(_ctx, %{state: "closed"} = session, _ownership), do: session

  defp observe(ctx, session, :closed), do: transition(ctx, session, "closed")
  defp observe(ctx, session, :human), do: transition(ctx, session, "human_active")

  defp observe(ctx, %{state: "unverified"} = session, :bot),
    do: transition(ctx, session, "bot_active")

  defp observe(_ctx, session, _ownership), do: session

  defp transition(_ctx, %{state: state} = session, state), do: session

  defp transition(ctx, session, state),
    do: %{session | state: state, epoch: fence(ctx, session, state)}

  defp fence(%{prefix: p} = ctx, session, state) do
    # Keep an in-flight or unknown reply tied to the session even after takeover.
    query!(
      """
      UPDATE #{p}.deliveries SET state = 'cancelled', reason = 'ownership_changed', finished_at = $2
      WHERE session_id = $1 AND state = 'pending'
      """,
      [session.id, ctx.now.()]
    )

    %{rows: [[epoch]]} =
      query!(
        """
        UPDATE #{p}.sessions SET state = $2, epoch = epoch + 1, last_verified_at = $3,
          active_event = CASE WHEN EXISTS (
            SELECT FROM #{p}.deliveries WHERE session_id = $1 AND state IN ('sending','unknown')
          ) THEN active_event ELSE NULL END
        WHERE id = $1 RETURNING epoch
        """,
        [session.id, state, ctx.now.()]
      )

    epoch
  end

  defp finish(%{prefix: p} = ctx, delivery, state, reason, external_id) do
    query!(
      """
      UPDATE #{p}.deliveries SET state = $2, reason = $3, external_message_id = $4, finished_at = $5,
        recovery_failure = NULL
      WHERE id = $1
      """,
      [delivery.id, state, reason, external_id, ctx.now.()]
    )

    if state != "unknown" do
      query!(
        "UPDATE #{p}.sessions SET active_event = NULL WHERE id = $1 AND active_event = $2",
        [delivery.session_id, delivery.event_id]
      )
    end

    :ok
  end

  defp allowed?("bot_active", "reply"), do: true
  defp allowed?("handoff_pending", "handoff"), do: true
  defp allowed?(_state, _kind), do: false

  defp lock_session(p, id), do: one!("SELECT * FROM #{p}.sessions WHERE id = $1 FOR UPDATE", [id])

  defp lock_delivery(p, id),
    do: one!("SELECT * FROM #{p}.deliveries WHERE id = $1 FOR UPDATE", [id])

  defp enqueue!(oban, job) do
    case Oban.insert(oban, job) do
      {:ok, _job} -> :ok
      {:error, _changeset} -> Repo.rollback(:enqueue_failed)
    end
  end

  defp checkpoint(ctx, phase) do
    case Map.get(ctx, phase, fn -> :ok end).() do
      :ok -> :ok
      :rollback -> Repo.rollback(phase)
    end
  end

  defp one!(sql, params) do
    case query!(sql, params) do
      %{rows: []} ->
        nil

      %{columns: columns, rows: [row]} ->
        Map.new(Enum.zip(columns, row), fn {key, value} -> {Map.fetch!(@columns, key), value} end)
    end
  end

  defp query!(sql, params), do: Repo.query!(sql, params, log: false)
end
