defmodule VoelgoedAi.Governance.EmbeddingAccounting do
  @moduledoc """
  Reserves and settles embedding spend under the caller's global control lock.
  Window totals contain settled spend. Every outstanding hold counts once against
  each current cap, whatever its origin. Settlement always uses its origin dates.
  """
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Governance.{SpendWindow, UsageLedger, UsageReservation}
  alias VoelgoedAi.Intelligence.Embedding
  alias VoelgoedAi.Knowledge.Storage
  alias VoelgoedAi.Repo

  @max_bigint 9_223_372_036_854_775_807

  @doc "Price trusted whole input tokens using a frozen rational nano-USD rate."
  def cost(tokens, price) when is_integer(tokens) and tokens in 1..@max_bigint do
    with :ok <- valid_price(price) do
      bounded(div(tokens * price.rate_nano_usd + price.token_unit - 1, price.token_unit))
    end
  end

  def cost(_, _), do: {:error, :invalid_usage}

  defp valid_price(%{
         version: version,
         rate_nano_usd: rate,
         token_unit: unit,
         max_input_tokens: max
       })
       when is_binary(version) and byte_size(version) in 1..64 and
              is_integer(rate) and rate in 1..@max_bigint and
              is_integer(unit) and unit in 1..@max_bigint and
              is_integer(max) and max in 1..@max_bigint,
       do: :ok

  defp valid_price(_), do: {:error, :invalid_price}

  @doc false
  def reserve(capability, control, attempt, now, %{price: price, day_cap: day, month_cap: month})
      when is_integer(day) and day in 1..@max_bigint and
             is_integer(month) and month in 1..@max_bigint do
    with :ok <- Embedding.authorize_accounting(capability, attempt.id, :reserve),
         false <- control.embedding_inhibited,
         :ok <- valid_price(price),
         {:ok, amount} <- cost(price.max_input_tokens, price) do
      dates = dates(now)

      attrs =
        Map.merge(dates, %{
          inference_run_id: attempt.id,
          price_version: price.version,
          rate_nano_usd: price.rate_nano_usd,
          token_unit: price.token_unit,
          max_input_tokens: price.max_input_tokens,
          reserved_nano_usd: amount
        })

      # The caller rolls back the entire claim if either cap rejects, including
      # a newly inserted reservation or window. The control lock serializes
      # this aggregate with all reservation and origin-window changes.
      with {:ok, reservation} <- insert(UsageReservation, attrs),
           {:ok, exposure} <- exposure(),
           {:ok, windows} <- lock_windows(dates),
           true <-
             windows.day.settled_nano_usd + exposure <= day and
               windows.month.settled_nano_usd + exposure <= month do
        {:ok, reservation}
      else
        false -> {:error, :budget_exhausted}
        error -> error
      end
    else
      true -> {:error, :embedding_inhibited}
      error -> error
    end
  end

  def reserve(_, _, _, _, _), do: {:error, :invalid_budget}

  @doc false
  def lock_reservation(capability, attempt) do
    with :ok <- Embedding.authorize_accounting(capability, attempt.id, :lock_reservation),
         {:ok, %UsageReservation{} = reservation} <-
           read_one(UsageReservation, :for_attempt, %{id: attempt.id}) do
      {:ok, reservation}
    else
      {:ok, nil} -> {:error, :missing_reservation}
      error -> error
    end
  end

  @doc false
  def finish(capability, control, attempt, reservation, now, outcome) do
    with :ok <- Embedding.authorize_accounting(capability, attempt.id, :finish),
         true <- reservation.inference_run_id == attempt.id do
      settle(control, attempt, reservation, now, outcome)
    else
      false -> {:error, :invalid_reservation}
      error -> error
    end
  end

  defp settle(
         _control,
         %{dispatched_at: nil},
         %{state: :reserved} = reservation,
         now,
         {:release, reason}
       ) do
    with {:ok, _} <-
           change(reservation, %{state: :released, settled_at: now, reason_code: reason}),
         do: {:ok, :released}
  end

  defp settle(
         _control,
         %{dispatched_at: dispatched},
         %{state: state} = reservation,
         _now,
         {:hold, reason}
       )
       when not is_nil(dispatched) and state in [:reserved, :unknown] do
    with {:ok, _} <- change(reservation, %{state: :unknown, reason_code: reason}),
         do: {:ok, :unknown}
  end

  defp settle(
         control,
         %{dispatched_at: dispatch} = attempt,
         %{state: state} = reservation,
         now,
         {:usage, tokens, vector_status}
       )
       when not is_nil(dispatch) and state in [:reserved, :unknown] do
    with {:ok, actual} <- cost(tokens, price(reservation)) do
      reason =
        cond do
          actual > reservation.reserved_nano_usd -> :over_reserve
          vector_status == :invalid_vector -> :invalid_vector
          true -> :trusted_usage
        end

      entry = %{
        entry_kind: :settlement,
        entry_key: "settlement",
        input_tokens: tokens,
        amount_nano_usd: actual,
        reason_code: reason
      }

      record(control, attempt, reservation, now, entry, :settled, reason == :over_reserve)
    else
      {:error, :amount_overflow} -> inhibit_and_hold(control, attempt, reservation, now)
      error -> error
    end
  end

  defp settle(
         control,
         attempt,
         %{state: :unknown} = reservation,
         now,
         {:conservative_closure, staff_id}
       ) do
    entry = %{
      entry_kind: :settlement,
      entry_key: "settlement",
      amount_nano_usd: reservation.reserved_nano_usd,
      closure_approved_by_id: staff_id,
      reason_code: :conservative_closure
    }

    record(control, attempt, reservation, now, entry, :conservatively_settled, false)
  end

  defp settle(
         control,
         attempt,
         %{state: :conservatively_settled} = reservation,
         now,
         {:usage, tokens, _}
       ) do
    with {:ok, entries} <- read(UsageLedger, :for_reservation, %{id: reservation.id}),
         {:ok, actual} <- cost(tokens, price(reservation)) do
      case entries do
        [%{entry_kind: :settlement} = original] ->
          entry = %{
            entry_kind: :correction,
            entry_key: "late-usage",
            corrects_id: original.id,
            input_tokens: tokens,
            amount_nano_usd: actual - original.amount_nano_usd,
            reason_code: :late_usage
          }

          record(
            control,
            attempt,
            reservation,
            now,
            entry,
            :conservatively_settled,
            actual > reservation.reserved_nano_usd
          )

        _ ->
          {:error, :conflicting_evidence}
      end
    else
      {:error, :amount_overflow} ->
        with {:ok, _} <- inhibit(control), do: {:ok, :amount_overflow}

      error ->
        error
    end
  end

  defp settle(_, _, _, _, _), do: {:error, :invalid_settlement}

  defp record(control, attempt, reservation, now, entry, terminal, discrepancy?) do
    # Under the control lock these reads are stable. Check overflow before
    # changing the reservation or inserting the ledger entry. Lock spend
    # windows only once all earlier-tier writes have succeeded.
    with {:ok, day} <- projected(:day, reservation.day_window, entry.amount_nano_usd),
         {:ok, month} <- projected(:month, reservation.month_window, entry.amount_nano_usd),
         {:ok, _} <- append(attempt, reservation, entry),
         {:ok, _} <- update_reservation(reservation, entry, terminal, now),
         :ok <- maybe_inhibit(control, discrepancy?),
         {:ok, windows} <- lock_windows(reservation),
         {:ok, _} <- change(windows.day, %{settled_nano_usd: day}),
         {:ok, _} <- change(windows.month, %{settled_nano_usd: month}) do
      {:ok, entry.reason_code}
    else
      {:error, :amount_overflow} -> inhibit_and_hold(control, attempt, reservation, now)
      error -> error
    end
  end

  defp projected(kind, start, amount) do
    with {:ok, row} <-
           query(SpendWindow, :by_window, %{kind: kind, start: start}, &Ash.read_one/1, false) do
      bounded(if(row, do: row.settled_nano_usd, else: 0) + amount)
    end
  end

  defp update_reservation(reservation, %{entry_kind: :settlement} = entry, terminal, now) do
    reason = if entry.reason_code == :trusted_usage, do: nil, else: entry.reason_code

    change(reservation, %{
      state: terminal,
      actual_nano_usd: entry.amount_nano_usd,
      settled_at: now,
      reason_code: reason
    })
  end

  defp update_reservation(reservation, _entry, _terminal, _now), do: {:ok, reservation}

  defp inhibit_and_hold(control, attempt, reservation, now) do
    with {:ok, _} <- inhibit(control) do
      if reservation.state in [:reserved, :unknown] do
        settle(control, attempt, reservation, now, {:hold, :amount_overflow})
      else
        {:ok, :amount_overflow}
      end
      |> case do
        {:ok, _} -> {:ok, :amount_overflow}
        error -> error
      end
    end
  end

  defp maybe_inhibit(control, true) do
    with {:ok, _} <- inhibit(control), do: :ok
  end

  defp maybe_inhibit(_control, false), do: :ok

  defp inhibit(control) do
    storage(
      control.__struct__,
      :inhibit_embedding,
      &Ash.update(control, %{}, action: :inhibit_embedding, actor: &1)
    )
  end

  defp append(attempt, reservation, entry) do
    attrs =
      Map.merge(
        entry,
        Map.take(reservation, [:price_version, :rate_nano_usd, :token_unit, :max_input_tokens])
      )

    attrs =
      Map.merge(attrs, %{
        reservation_id: reservation.id,
        inference_run_id: attempt.id,
        provider: attempt.provider,
        model_id: attempt.model_id,
        correlation_id: attempt.correlation_id
      })

    insert(UsageLedger, attrs)
  end

  defp exposure do
    case SQL.query(Repo, """
         SELECT COALESCE(sum(reserved_nano_usd::numeric), 0)::text
         FROM usage_reservations WHERE state IN ('reserved', 'unknown')
         """) do
      {:ok, %{rows: [[total]]}} -> {:ok, String.to_integer(total)}
      {:error, _} -> {:error, :accounting_storage}
    end
  end

  defp price(row) do
    row
    |> Map.take([:rate_nano_usd, :token_unit, :max_input_tokens])
    |> Map.put(:version, row.price_version)
  end

  defp dates(now) do
    day = DateTime.to_date(now)
    %{day_window: day, month_window: Date.beginning_of_month(day)}
  end

  defp lock_windows(dates) do
    with {:ok, day} <- window(:day, dates.day_window),
         {:ok, month} <- window(:month, dates.month_window) do
      {:ok, %{day: day, month: month}}
    end
  end

  defp window(kind, start) do
    case read_one(SpendWindow, :by_window, %{kind: kind, start: start}) do
      {:ok, nil} -> insert(SpendWindow, %{kind: kind, window_start: start})
      result -> result
    end
  end

  defp bounded(value) when value in 0..@max_bigint, do: {:ok, value}
  defp bounded(_value), do: {:error, :amount_overflow}

  defp read_one(resource, action, args) do
    query(resource, action, args, &Ash.read_one/1)
  end

  defp read(resource, action, args), do: query(resource, action, args, &Ash.read/1)

  defp query(resource, action, args, fun, lock \\ true) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      fun.(if(lock, do: Ash.Query.lock(query, :for_update), else: query))
    end)
  end

  defp insert(resource, attrs),
    do:
      storage(resource, :insert_row, &Ash.create(resource, attrs, action: :insert_row, actor: &1))

  defp change(%resource{} = row, attrs),
    do: storage(resource, :change_row, &Ash.update(row, attrs, action: :change_row, actor: &1))

  defp storage(resource, action, fun) do
    ref = make_ref()
    key = {__MODULE__, :storage}
    Process.put(key, {ref, resource, action})

    try do
      fun.(%Storage{ref: ref, owner: __MODULE__})
    after
      Process.delete(key)
    end
  end
end
