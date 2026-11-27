defmodule VoelgoedAi.Governance.EmbeddingAccounting do
  @moduledoc """
  Reserves and settles shared inference spend under the caller's global control lock.
  Window totals contain settled spend. Every outstanding hold counts once against
  each current cap, whatever its origin. Settlement always uses its origin dates.
  """
  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Governance.{AuditEvent, SpendWindow, UsageLedger, UsageReservation}
  alias VoelgoedAi.Intelligence.{Embedding, Generation}
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

  defp authorize({Generation, ref}, %{purpose: :generate, id: id}, action),
    do: Generation.authorize_accounting(ref, id, action)

  defp authorize(ref, %{purpose: purpose, id: id}, action)
       when purpose in [:article_embedding, :query_embedding],
       do: Embedding.authorize_accounting(ref, id, action)

  defp authorize(_, _, _), do: {:error, :denied}

  defp admission_price(%{purpose: :generate}, %{generation_inhibited: false}, price) do
    case price do
      %{max_output_tokens: output} when is_integer(output) and output in 1..@max_bigint ->
        charge(price.max_input_tokens, output, price)

      _ ->
        {:error, :invalid_price}
    end
  end

  defp admission_price(%{purpose: :generate}, _, _), do: {:error, :generation_inhibited}

  defp admission_price(_, %{embedding_inhibited: false}, price) do
    with :ok <- valid_price(price), do: cost(price.max_input_tokens, price)
  end

  defp admission_price(_, _, _), do: {:error, :embedding_inhibited}

  defp charge(input, nil, price), do: cost(input, price)

  defp charge(input, output, %{output_rate_nano_usd: rate} = price)
       when is_integer(input) and input in 1..@max_bigint and
              is_integer(output) and output in 0..@max_bigint and
              is_integer(rate) and rate in 1..@max_bigint do
    with :ok <- valid_price(price) do
      bounded(
        div(input * price.rate_nano_usd + output * rate + price.token_unit - 1, price.token_unit)
      )
    end
  end

  defp charge(_, _, _), do: {:error, :invalid_usage}

  @doc false
  def reserve(capability, control, attempt, now, %{price: price, day_cap: day, month_cap: month})
      when is_integer(day) and day in 1..@max_bigint and
             is_integer(month) and month in 1..@max_bigint do
    with :ok <- authorize(capability, attempt, :reserve),
         {:ok, amount} <- admission_price(attempt, control, price) do
      dates = dates(now)

      attrs =
        Map.merge(dates, %{
          inference_run_id: attempt.id,
          price_version: price.version,
          rate_nano_usd: price.rate_nano_usd,
          token_unit: price.token_unit,
          max_input_tokens: price.max_input_tokens,
          max_output_tokens: price[:max_output_tokens],
          output_rate_nano_usd: price[:output_rate_nano_usd],
          reserved_nano_usd: amount
        })

      # The caller rolls back the entire claim if either cap rejects, including
      # a newly inserted reservation or window. The control lock serializes
      # this aggregate with all reservation and origin-window changes.
      with {:ok, reservation} <- insert(UsageReservation, attrs),
           {:ok, exposure} <- exposure(control),
           {:ok, windows} <- lock_windows(dates),
           true <-
             windows.day.settled_nano_usd + exposure <= day and
               windows.month.settled_nano_usd + exposure <= month do
        {:ok, reservation}
      else
        false -> {:error, :budget_exhausted}
        error -> error
      end
    end
  end

  def reserve(_, _, _, _, _), do: {:error, :invalid_budget}

  @doc false
  def validate_dispatch(attempt, control, reservation, now, config) do
    with %{state: :reserved} <- reservation,
         %{price: expected, day_cap: day, month_cap: month} <- config,
         true <- valid_caps?(day, month),
         {_, %{"day_cap" => admitted_day, "month_cap" => admitted_month} = quote} <-
           attempt_quote(attempt),
         true <- valid_caps?(admitted_day, admitted_month),
         admitted = %{config | day_cap: admitted_day, month_cap: admitted_month},
         true <-
           budget_quote(attempt.provider, attempt.model_id, attempt.profile_id, admitted) ===
             quote,
         {:ok, ceiling} <- admission_price(attempt, control, expected),
         true <- reservation.reserved_nano_usd == ceiling,
         true <-
           price(reservation) ==
             Map.merge(%{max_output_tokens: nil, output_rate_nano_usd: nil}, expected),
         :ok <- headroom(control, now, min(day, admitted_day), min(month, admitted_month), 0) do
      :ok
    else
      _ -> {:error, :admission_denied}
    end
  end

  @doc false
  def budget_quote(provider, model, profile, config) do
    %{
      "provider" => provider,
      "model" => model,
      "profile" => profile,
      "price" => Map.new(config.price, fn {key, value} -> {Atom.to_string(key), value} end),
      "day_cap" => config.day_cap,
      "month_cap" => config.month_cap
    }
  end

  if Mix.env() == :test do
    alias VoelgoedAi.Intelligence.InferenceRun

    @doc false
    def reset_headroom(control, lane, occurrence, now) do
      cleared = %{generation_inhibited: false, embedding_inhibited: false}

      with {true, ^occurrence, %{"attempt_id" => id, "quote" => quote} = reference} <-
             inhibit_state(control, lane),
           true <- is_map(quote) and trip_matches?(control, lane, occurrence, reference),
           {:ok, %InferenceRun{dispatched_at: %DateTime{}} = attempt} <-
             query(InferenceRun, :storage_row, %{id: id}, &Ash.read_one/1, false),
           {^lane, ^quote} <- attempt_quote(attempt),
           {:ok, %{price: expected, day_cap: day, month_cap: month} = config} <-
             reset_budget(lane, quote),
           true <- valid_caps?(day, month),
           true <-
             budget_quote(attempt.provider, attempt.model_id, attempt.profile_id, config) ===
               quote,
           {:ok, ceiling} <- admission_price(attempt, cleared, expected),
           {:ok, %UsageReservation{reserved_nano_usd: ^ceiling} = reservation} <-
             query(UsageReservation, :for_attempt, %{id: id}, &Ash.read_one/1, false),
           true <-
             price(reservation) ===
               Map.merge(%{max_output_tokens: nil, output_rate_nano_usd: nil}, expected),
           {:ok, %{rows: [[false]]}} <-
             SQL.query(
               Repo,
               """
               SELECT EXISTS (
                 SELECT 1 FROM inference_runs i JOIN usage_reservations r ON r.inference_run_id = i.id
                 WHERE (i.purpose = 'generate') = $1
                 AND (r.state = 'unknown' OR (r.state = 'reserved' AND i.dispatched_at IS NOT NULL))
               )
               """,
               [lane == :generation]
             ) do
        headroom(control, now, day, month, ceiling)
      else
        _ -> {:error, :unresolved_exposure}
      end
    end

    defp reset_budget(:generation, quote), do: Generation.reset_budget(quote)
    defp reset_budget(:embedding, quote), do: Embedding.reset_budget(quote)
  end

  defp valid_caps?(day, month),
    do:
      is_integer(day) and day in 1..@max_bigint and is_integer(month) and month in 1..@max_bigint

  defp headroom(control, now, day_cap, month_cap, additional) do
    %{day_window: day, month_window: month} = dates(now)

    with {:ok, risk} <- exposure(control),
         {:ok, daily} <- projected(:day, day, 0),
         {:ok, monthly} <- projected(:month, month, 0),
         true <- daily + risk + additional <= day_cap and monthly + risk + additional <= month_cap do
      :ok
    else
      _ -> {:error, :budget_exhausted}
    end
  end

  @doc false
  def overflow_matches?(%{overflow_evidence: nil}, _usage), do: true

  def overflow_matches?(attempt, usage) do
    attempt
    |> recorded_usage()
    |> Map.delete(:duration_us)
    |> Kernel.==(usage |> overflow_evidence() |> Map.delete(:duration_us))
  end

  @doc false
  def overflow_evidence(usage) do
    usage
    |> Map.take([
      :provider_request_id,
      :provider_response_id,
      :input_tokens,
      :output_tokens,
      :duration_us
    ])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc false
  def recorded_usage(%{overflow_evidence: nil}), do: nil

  def recorded_usage(attempt) do
    keys = [
      :provider_request_id,
      :provider_response_id,
      :input_tokens,
      :output_tokens,
      :duration_us
    ]

    for key <- keys,
        value =
          Map.get(attempt.overflow_evidence, key) ||
            Map.get(attempt.overflow_evidence, Atom.to_string(key)),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  @doc false
  def lock_reservation(capability, attempt) do
    with :ok <- authorize(capability, attempt, :lock_reservation),
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
    with :ok <- authorize(capability, attempt, :finish),
         true <- reservation.inference_run_id == attempt.id do
      settle(control, attempt, reservation, now, outcome)
    else
      false -> {:error, :invalid_reservation}
      error -> error
    end
  end

  defp settle(control, %{purpose: purpose} = attempt, reservation, now, {:usage, tokens, status})
       when purpose in [:article_embedding, :query_embedding],
       do: settle(control, attempt, reservation, now, {:usage, tokens, nil, status})

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
         {:usage, tokens, output, result_status}
       )
       when not is_nil(dispatch) and state in [:reserved, :unknown] do
    with {:ok, actual} <- charge(tokens, output, price(reservation)) do
      reason =
        cond do
          actual > reservation.reserved_nano_usd -> :over_reserve
          result_status in [:invalid_vector, :invalid_proposal] -> result_status
          true -> :trusted_usage
        end

      entry = %{
        entry_kind: :settlement,
        entry_key: "settlement",
        input_tokens: tokens,
        output_tokens: output,
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
         %{state: :unknown, dispatched_at: %DateTime{}} = attempt,
         %{state: :unknown} = reservation,
         now,
         {:conservative_closure, staff_id}
       )
       when reservation.reason_code != :amount_overflow or not is_nil(attempt.overflow_evidence) do
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
         _control,
         %{state: :abandoned, dispatched_at: %DateTime{}},
         %{state: :conservatively_settled} = reservation,
         _now,
         {:conservative_closure, staff_id}
       ) do
    with {:ok, history} <- read(UsageLedger, :for_reservation, %{id: reservation.id}),
         %{id: id, closure_approved_by_id: ^staff_id} <-
           Enum.find(history, &(&1.entry_kind == :settlement)),
         {:ok, %{actor_staff_id: ^staff_id}} <-
           query(AuditEvent, :financial_closure, %{settlement_id: id}, &Ash.read_one/1, false) do
      {:ok, :conservative_closure}
    else
      _ -> {:error, :conflicting_decision}
    end
  end

  defp settle(
         control,
         attempt,
         %{state: :conservatively_settled} = reservation,
         now,
         {:usage, tokens, output, _}
       ) do
    with {:ok, entries} <- read(UsageLedger, :for_reservation, %{id: reservation.id}),
         {:ok, actual} <- charge(tokens, output, price(reservation)) do
      case entries do
        [%{entry_kind: :settlement} = original] ->
          entry = %{
            entry_kind: :correction,
            entry_key: "late-usage",
            corrects_id: original.id,
            input_tokens: tokens,
            output_tokens: output,
            amount_nano_usd: actual - original.amount_nano_usd,
            reason_code: :late_usage
          }

          over_reserve? = actual > reservation.reserved_nano_usd

          case record(
                 control,
                 attempt,
                 reservation,
                 now,
                 entry,
                 :conservatively_settled,
                 over_reserve?
               ) do
            {:ok, :late_usage} when over_reserve? and attempt.purpose == :generate ->
              {:ok, :late_over_reserve}

            result ->
              result
          end

        _ ->
          {:error, :conflicting_evidence}
      end
    else
      {:error, :amount_overflow} ->
        inhibit_and_hold(control, attempt, reservation, now)

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
         {:ok, ledger} <- append(attempt, reservation, entry),
         {:ok, _} <- update_reservation(reservation, entry, terminal, now),
         {:ok, windows} <- lock_windows(reservation),
         {:ok, _} <- change(windows.day, %{settled_nano_usd: day}),
         {:ok, _} <- change(windows.month, %{settled_nano_usd: month}),
         :ok <- maybe_inhibit(control, attempt, now, discrepancy?),
         :ok <- audit_closure(attempt, ledger, entry, now) do
      {:ok, entry.reason_code}
    else
      {:error, :amount_overflow} when entry.reason_code == :conservative_closure ->
        with {:ok, _} <- inhibit(control, attempt, now, :amount_overflow),
             do: {:ok, :amount_overflow}

      {:error, :amount_overflow} ->
        inhibit_and_hold(control, attempt, reservation, now)

      error ->
        error
    end
  end

  defp audit_closure(attempt, ledger, %{reason_code: :conservative_closure} = entry, now) do
    attrs = %{
      actor_kind: :staff,
      actor_staff_id: entry.closure_approved_by_id,
      target_kind: :usage_settlement,
      settlement_target_id: ledger.id,
      event: :close_unknown_inference,
      reason_code: :local_admin,
      operational_before: %{status: :unknown},
      operational_after: %{status: :abandoned},
      correlation_id: attempt.correlation_id,
      occurred_at: now
    }

    with {:ok, _} <-
           storage(
             AuditEvent,
             :append_financial,
             &Ash.create(AuditEvent, attrs, action: :append_financial, actor: &1)
           ),
         do: :ok
  end

  defp audit_closure(_, _, _, _), do: :ok

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

  defp inhibit_and_hold(_control, %{overflow_evidence: evidence}, _reservation, _now)
       when not is_nil(evidence), do: {:ok, :amount_overflow}

  defp inhibit_and_hold(control, attempt, reservation, now) do
    hold =
      if reservation.state in [:reserved, :unknown] do
        settle(control, attempt, reservation, now, {:hold, :amount_overflow})
      else
        {:ok, :amount_overflow}
      end

    with {:ok, _} <- hold,
         {:ok, _} <- inhibit(control, attempt, now, :amount_overflow) do
      {:ok, :amount_overflow}
    end
  end

  defp maybe_inhibit(control, attempt, now, true) do
    with {:ok, _} <- inhibit(control, attempt, now, :over_reserve), do: :ok
  end

  defp maybe_inhibit(_control, _attempt, _now, false), do: :ok

  defp inhibit(control, attempt, now, reason) do
    {lane, quote} = attempt_quote(attempt)

    case inhibit_state(control, lane) do
      # A later trip cannot classify unresolved predecessor exposure.
      {true, nil, _} ->
        {:ok, control}

      {inhibited, previous, reference} ->
        # A conflicting or unverifiable prior quote cannot authorize a reset.
        budget =
          if is_map(quote) and
               (not inhibited or
                  (reference["quote"] === quote and
                     trip_matches?(control, lane, previous, reference))) do
            %{"attempt_id" => attempt.id, "quote" => quote}
          end

        {action, field, _event, _actor} = trip_attributes(lane)

        with {:ok, updated} <-
               storage(control.__struct__, action, fn actor ->
                 Ash.update(control, %{field => budget}, action: action, actor: actor)
               end),
             {true, occurrence, _} <- inhibit_state(updated, lane),
             {:ok, _} <-
               append_trip(control, attempt, occurrence, not is_nil(budget), now, reason) do
          {:ok, updated}
        end
    end
  end

  defp attempt_quote(%{purpose: :generate, generation_budget: quote}), do: {:generation, quote}

  defp attempt_quote(%{purpose: purpose, embedding_budget: quote})
       when purpose in [:article_embedding, :query_embedding],
       do: {:embedding, quote}

  defp inhibit_state(control, :generation) do
    {control.generation_inhibited, control.generation_inhibit_occurrence,
     control.generation_inhibit_budget}
  end

  defp inhibit_state(control, :embedding) do
    {control.embedding_inhibited, control.embedding_inhibit_occurrence,
     control.embedding_inhibit_budget}
  end

  defp trip_attributes(:generation),
    do:
      {:inhibit_generation, :generation_inhibit_budget, :trip_generation_inhibit, :support_worker}

  defp trip_attributes(:embedding),
    do:
      {:inhibit_embedding, :embedding_inhibit_budget, :trip_embedding_inhibit, :embedding_worker}

  defp trip_matches?(control, lane, occurrence, %{"attempt_id" => id, "quote" => quote}) do
    {_action, _field, event, _actor} = trip_attributes(lane)
    args = %{control_id: control.id, occurrence: occurrence, event: event}

    case query(AuditEvent, :inhibit_trip, args, &Ash.read_one/1, false) do
      {:ok, %{inhibit_attempt_id: ^id, inhibit_quote: frozen, inhibit_reset_eligible: true}} ->
        frozen === quote

      _ ->
        false
    end
  end

  defp trip_matches?(_control, _lane, _occurrence, _reference), do: false

  defp append_trip(control, attempt, occurrence, reset_eligible?, now, reason) do
    {lane, quote} = attempt_quote(attempt)
    {_action, _field, event, actor_kind} = trip_attributes(lane)

    attrs = %{
      actor_kind: actor_kind,
      target_kind: :automation_control,
      control_target_id: control.id,
      event: event,
      reason_code: reason,
      inhibit_attempt_id: attempt.id,
      inhibit_quote: quote,
      inhibit_reset_eligible: reset_eligible?,
      correlation_id: occurrence,
      occurred_at: now
    }

    storage(
      AuditEvent,
      :append_inhibit_trip,
      &Ash.create(AuditEvent, attrs, action: :append_inhibit_trip, actor: &1)
    )
  end

  defp append(attempt, reservation, entry) do
    attrs =
      Map.merge(
        entry,
        Map.take(reservation, [
          :price_version,
          :rate_nano_usd,
          :token_unit,
          :max_input_tokens,
          :max_output_tokens,
          :output_rate_nano_usd
        ])
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

  defp exposure(%{embedding_inhibited: true, embedding_inhibit_occurrence: nil}),
    do: {:error, :unclassified_inhibit}

  defp exposure(%{generation_inhibited: true, generation_inhibit_occurrence: nil}),
    do: {:error, :unclassified_inhibit}

  defp exposure(_control) do
    case SQL.query(Repo, """
         SELECT COALESCE(sum(r.reserved_nano_usd::numeric)
           FILTER (WHERE r.state IN ('reserved', 'unknown')), 0)::text,
           COALESCE(bool_or(i.overflow_evidence IS NOT NULL AND i.overflow_resolved_at IS NULL
             OR r.state = 'unknown' AND r.reason_code = 'amount_overflow'), false)
         FROM usage_reservations r JOIN inference_runs i ON i.id = r.inference_run_id
         """) do
      {:ok, %{rows: [[total, false]]}} -> {:ok, String.to_integer(total)}
      {:ok, %{rows: [[_, true]]}} -> {:error, :amount_overflow}
      {:error, _} -> {:error, :accounting_storage}
    end
  end

  defp price(row) do
    row
    |> Map.take([
      :rate_nano_usd,
      :token_unit,
      :max_input_tokens,
      :max_output_tokens,
      :output_rate_nano_usd
    ])
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
