defmodule VoelgoedAi.Feasibility.DurableLedger do
  @moduledoc """
  Single-table PostgreSQL feasibility ledger. Each test owns its table.
  Admission takes a table lock so even the first reservation is serialized.
  Dispatch and provider calls occur after the admission transaction commits.
  """
  alias VoelgoedAi.Repo

  def create! do
    table = "vgas_f03_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Repo.query!("""
    CREATE TABLE #{table} (
      id bigint PRIMARY KEY,
      day date NOT NULL,
      model text NOT NULL,
      ceiling bigint NOT NULL CHECK (ceiling > 0),
      state text NOT NULL DEFAULT 'reserved'
        CHECK (state IN ('reserved', 'dispatching', 'unknown', 'released', 'settled')),
      evidence jsonb,
      price_version text NOT NULL DEFAULT 'vgas-000-openai-standard-v1',
      result text,
      actual numeric CHECK (actual >= 0 AND actual = trunc(actual)),
      CHECK ((state = 'settled') = (actual IS NOT NULL))
    )
    """)

    table
  end

  def drop!(table), do: Repo.query!("DROP TABLE #{table}")
  def missing(table), do: table <> "_missing"

  def reserve(table, id, day, model, ceiling, limits) do
    locked(table, fn ->
      %{rows: [[duplicate, inhibited, daily_ok, monthly_ok, active]]} =
        Repo.query!(
          """
          SELECT coalesce(bool_or(id = $1), false),
            coalesce(bool_or(coalesce(actual, (evidence->>'charge')::numeric) > ceiling), false),
            coalesce(sum(CASE
              WHEN state IN ('reserved','dispatching','unknown') THEN ceiling
              WHEN state = 'settled' AND day = $2 THEN actual ELSE 0 END), 0) + $3::bigint <= $4::bigint,
            coalesce(sum(CASE
              WHEN state IN ('reserved','dispatching','unknown') THEN ceiling
              WHEN state = 'settled' AND date_trunc('month', day::timestamp) =
                date_trunc('month', $2::date::timestamp) THEN actual ELSE 0 END), 0) + $3::bigint <= $5::bigint,
            count(*) FILTER (WHERE state IN ('reserved','dispatching'))
          FROM #{table}
          """,
          [id, day, ceiling, limits[:daily], limits[:monthly]]
        )

      cond do
        duplicate ->
          {:error, :duplicate}

        inhibited ->
          {:error, :inhibited}

        not daily_ok or not monthly_ok ->
          {:error, :budget}

        active >= limits[:concurrent] ->
          {:error, :concurrency}

        true ->
          Repo.query!("INSERT INTO #{table} (id, day, model, ceiling) VALUES ($1,$2,$3,$4)", [
            id,
            day,
            model,
            ceiling
          ])

          :ok
      end
    end)
  end

  def claim(table, id) do
    locked(table, fn ->
      %{num_rows: count} =
        Repo.query!(
          """
          UPDATE #{table} SET state = 'dispatching'
          WHERE id = $1 AND state = 'reserved'
            AND NOT EXISTS (SELECT 1 FROM #{table} WHERE coalesce(actual, (evidence->>'charge')::numeric) > ceiling)
          """,
          [id]
        )

      if count == 1, do: :ok, else: {:error, :dispatch_denied}
    end)
  end

  def record(table, id, evidence) do
    case Repo.query(
           """
           UPDATE #{table} SET evidence = $2
           WHERE id = $1 AND state IN ('dispatching','unknown') AND evidence IS NULL
           """,
           [id, evidence],
           log: false
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :already_recorded}
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  @doc "Reconcile only after the attempt has returned or its worker is known to have stopped."
  def recover(table, id, result \\ nil) do
    case Repo.query(
           """
           UPDATE #{table}
           SET state = CASE
               WHEN state = 'reserved' THEN 'released'
               WHEN state IN ('dispatching','unknown') AND evidence->>'charge' IS NOT NULL THEN 'settled'
               WHEN state = 'dispatching' THEN 'unknown'
               ELSE state END,
             result = coalesce(result, $2),
           actual = CASE WHEN state IN ('dispatching','unknown') THEN (evidence->>'charge')::numeric ELSE actual END
           WHERE id = $1
           RETURNING state
           """,
           [id, result],
           log: false
         ) do
      {:ok, %{rows: [[state]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> {:error, :missing}
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  def reject_before_send(table, id) do
    case Repo.query(
           "UPDATE #{table} SET state = 'released' WHERE id = $1 AND state = 'reserved'",
           [id]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, "released"}
      {:ok, _} -> {:error, :already_claimed}
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  def fetch(table, id) do
    case Repo.query!(
           "SELECT state, ceiling, actual, evidence, result FROM #{table} WHERE id = $1",
           [id]
         ).rows do
      [[state, ceiling, actual, evidence, result]] ->
        %{
          state: state,
          ceiling: ceiling,
          actual: actual && Decimal.to_integer(actual),
          evidence: evidence,
          result: result
        }

      [] ->
        nil
    end
  end

  defp locked(table, function) do
    case Repo.transaction(
           fn ->
             Repo.query!("LOCK TABLE #{table} IN SHARE ROW EXCLUSIVE MODE", [], log: false)
             function.()
           end,
           timeout: 5000,
           log: false
         ) do
      {:ok, result} -> result
      {:error, _} -> {:error, :storage_unavailable}
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :storage_unavailable}
  end
end
