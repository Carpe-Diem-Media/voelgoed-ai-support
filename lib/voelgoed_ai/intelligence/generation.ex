defmodule VoelgoedAi.Intelligence.Generation do
  @moduledoc """
  Governs one shadow proposal attempt. Claim and reserve commit together.
  Dispatch consumes the fence in a second transaction before any HTTP.
  Recovery and late settlement use the original lineage and price even when
  the support claim has lost authority. Only a timely first settlement can
  return a proposal, subject to a fresh support qualification.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Governance.EmbeddingAccounting, as: Accounting
  alias VoelgoedAi.Intelligence.{GenerationTransport, InferenceRun, SupportProposal}
  alias VoelgoedAi.Knowledge.Storage
  alias VoelgoedAi.Knowledge.Workers.RecoverIndexing
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ChatwootAdapter, Configuration, Ownership, RunProcessing, SupportRun}

  @scope_key {__MODULE__, :scope}
  @price %{
    version: "luna-responses-synthetic-v1",
    rate_nano_usd: 500,
    output_rate_nano_usd: 750,
    token_unit: 1,
    max_input_tokens: 1_050_000,
    max_output_tokens: 500
  }

  @enforce_keys [:ref]
  defstruct [:ref]

  @impl Ash.Policy.Check
  def describe(_), do: "the shadow claim authorized this specific generation action"

  @impl Ash.Policy.SimpleCheck
  def match?(
        %__MODULE__{ref: ref},
        %{subject: %Ash.ActionInput{resource: SupportProposal} = input},
        _
      )
      when is_reference(ref) do
    permitted?(Process.get(@scope_key), ref, input.action.name, input.arguments)
  end

  def match?(_, _, _), do: false

  defp permitted?({ref, id, claim, _}, ref, :generate, %{run_id: id, claim_generation: claim}),
    do: true

  defp permitted?(_, ref, :prompt, %{text: text}) do
    case Process.get({__MODULE__, :prompt}) do
      {^ref, ^text, _} -> not Repo.in_transaction?()
      _ -> false
    end
  end

  defp permitted?(_, _, _, _), do: false

  if Mix.env() == :test do
    @doc "Issue a process-bound generation capability for one synthetic shadow claim."
    def with_fixture(id, claim, %{wire: wire} = options, operation)
        when is_binary(id) and is_integer(claim) and is_function(wire, 1) and
               is_function(operation, 1) do
      if is_nil(Process.get(@scope_key)) and not Repo.in_transaction?() do
        ref = make_ref()
        settings = Map.put(options, :shadow_enabled?, &Ownership.shadow_evaluation_enabled?/1)
        Process.put(@scope_key, {ref, id, claim, settings})

        try do
          operation.(%__MODULE__{ref: ref})
        after
          Process.delete(@scope_key)
        end
      else
        {:error, :generation_disabled}
      end
    end
  end

  @impl Ash.Resource.Actions.Implementation
  def run(%{action: %{name: :generate}, arguments: args}, _, %{actor: %__MODULE__{ref: ref}}) do
    with false <- Repo.in_transaction?(),
         {^ref, _, _, fixture} <- Process.get(@scope_key),
         {:ok, {attempt, payload}} <-
           qualified(args, fixture.shadow_enabled?, fn config, run, revision, now, cutoff ->
             with {:ok, payload} <- payload(args, run, revision),
                  {:ok, attempt} <- reserve(config.control, run, now, cutoff, fixture) do
               {:ok, {attempt, payload}}
             end
           end),
         {:ok, decision} <- execute(attempt, payload, args, fixture) do
      {:ok, decision}
    else
      _ -> {:error, "support proposal unavailable"}
    end
  end

  def run(
        %{
          action: %{name: :close_unknown_generation},
          arguments: %{id: id, reason: :conservative_closure}
        },
        _,
        %{actor: session}
      ) do
    StaffAccess.with_current(session, :admin, fn staff ->
      with {_, _, _, %{closure_approved_by: approver}} when approver == staff.id <-
             Process.get(@scope_key),
           {:ok, control} <- Configuration.lock_control(),
           {:ok, candidate} <- read_attempt(id, false),
           {:ok, attempt, reservation} <- lock_money(candidate),
           {:ok, result} <- close(control, attempt, reservation, staff.id) do
        {:ok, result}
      else
        _ -> {:error, :denied}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      _ -> {:error, "generation closure denied"}
    end
  end

  defp qualified(%{run_id: id, claim_generation: claim}, shadow_enabled?, work) do
    RunProcessing.with_run(id, fn config, session, run, _now ->
      with true <- shadow_enabled?.(config),
           true <- RunProcessing.valid_run?(config, session, run),
           true <- run.state == :running and run.claim_generation == claim,
           {:ok, revision} <- Configuration.current_revision(config.assistant),
           true <- revision.id == run.assistant_revision_id,
           true <- revision.response_policy == :shadow_decision,
           cutoff = Enum.min([run.lease_expires_at, run.deadline_at], DateTime),
           now = ChatwootAdapter.now(),
           true <- DateTime.before?(now, cutoff) do
        work.(config, run, revision, now, cutoff)
      else
        _ -> {:error, :stale_claim}
      end
    end)
  end

  defp payload(args, run, revision) do
    context = args.context
    evidence = args.evidence

    with true <- valid_text?(context.prior, 0..6, [:contact, :bot, :human]),
         true <- valid_text?(context.current, 1..5, [:contact]),
         true <- Enum.all?(evidence, &qualified_evidence?(&1, run, revision)),
         evidence <-
           Enum.map(evidence, &Map.take(&1, [:revision_id, :title, :answer, :steps, :links])),
         {:ok, data} <-
           Jason.encode(%{
             locale: locale(revision),
             prior_public_messages: context.prior,
             current_public_messages: context.current,
             approved_evidence: evidence
           }),
         true <- byte_size(data) <= 16_384 do
      {:ok, data}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp locale(revision), do: Atom.to_string(revision.locale) <> "-ZA"

  defp valid_text?(messages, count, roles) when is_list(messages) do
    length(messages) in count and
      Enum.all?(messages, fn
        %{role: role, text: text} = msg when map_size(msg) == 2 and is_binary(text) ->
          role in roles and byte_size(text) in 1..12_000 and String.valid?(text)

        _ ->
          false
      end)
  end

  defp valid_text?(_, _, _), do: false

  defp qualified_evidence?(evidence, run, revision) do
    evidence.mode == :grounded and evidence.locale == locale(revision) and
      evidence.run_id == run.id and evidence.claim_generation == run.claim_generation and
      evidence.assistant_revision_id == revision.id and
      evidence.assistant_hash == revision.config_hash and
      Enum.all?([:assistant_epoch, :binding_epoch, :control_epoch, :ownership_epoch], fn key ->
        Map.fetch!(evidence, key) == Map.fetch!(run, key)
      end)
  end

  defp reserve(control, run, now, cutoff, fixture) do
    with {:ok, slots} <- read(:generation_slots, %{turn_ref: run.turn_ref}, &Ash.read/1),
         {:ok, ordinal} <- next_slot(run, slots),
         {:ok, attempt} <-
           storage(:insert_generation_attempt, fn actor ->
             Ash.create(
               InferenceRun,
               %{
                 support_run_id: run.id,
                 turn_ref: run.turn_ref,
                 claim_generation: run.claim_generation,
                 assistant_revision_id: run.assistant_revision_id,
                 provider: "openai",
                 model_id: SupportProposal.model(),
                 profile_id: SupportProposal.profile(),
                 prompt_version: SupportProposal.prompt_version(),
                 deadline_at: cutoff,
                 started_at: now,
                 ordinal: ordinal,
                 dispatch_fence: Ash.UUIDv7.generate(),
                 correlation_id: run.correlation_id
               },
               action: :insert_generation_attempt,
               actor: actor
             )
           end),
         config = %{
           price: @price,
           day_cap: Map.get(fixture, :day_cap, 2_000_000_000),
           month_cap: Map.get(fixture, :month_cap, 20_000_000_000)
         },
         {:ok, _} <-
           account(attempt, :reserve, &Accounting.reserve(&1, control, attempt, now, config)),
         {:ok, _} <-
           Ownership.enqueue(RecoverIndexing, %{generation_id: attempt.id}, scheduled_at: cutoff) do
      {:ok, attempt}
    end
  end

  defp next_slot(_, []), do: {:ok, 1}

  # The only approved second call in C is a qualified successor after a
  # known outcome. An ambiguous predecessor holds both spend and replay.
  defp next_slot(
         %{parent_run_id: parent, regroup_count: 1},
         [%{support_run_id: parent, ordinal: 1, state: state}]
       )
       when not is_nil(parent) and state in [:succeeded, :failed, :rejected],
       do: {:ok, 2}

  defp next_slot(_, _), do: {:error, :generation_slots_unavailable}

  defp execute(attempt, payload, args, fixture) do
    barrier(fixture, :after_claim, attempt)

    case qualified(args, fixture.shadow_enabled?, fn config, _, revision, _, cutoff ->
           with {:ok, dispatched} <- dispatch(config, attempt, cutoff),
                do: {:ok, {dispatched, locale(revision)}}
         end) do
      {:ok, {%InferenceRun{} = dispatched, approved_locale}} ->
        barrier(fixture, :after_dispatch, dispatched)
        outcome = invoke(dispatched, payload, fixture.wire, approved_locale)

        case transaction(dispatched.id, dispatched.dispatch_fence, fn control, current, hold ->
               settle(control, current, hold, outcome)
             end) do
          {:ok, {:proposal, decision}} ->
            qualified(args, fixture.shadow_enabled?, fn _config, _run, revision, now, _cutoff ->
              if DateTime.before?(now, dispatched.deadline_at) and
                   decision.locale == locale(revision),
                 do: {:ok, decision},
                 else: {:error, :stale_claim}
            end)

          {:ok, {:attention, reason}} ->
            alert(dispatched, reason)
            {:error, reason}

          _ ->
            {:error, :generation_unavailable}
        end

      _ ->
        transaction(attempt.id, attempt.dispatch_fence, fn control, row, hold ->
          if row.state == :running and is_nil(row.dispatched_at),
            do: expire(control, row, hold, :stale_request),
            else: {:ok, :noop}
        end)

        {:error, :dispatch_denied}
    end
  end

  defp dispatch(%{control: %{generation_inhibited: false} = control}, candidate, cutoff) do
    with {:ok, %{state: :running, dispatched_at: nil} = attempt} <-
           read_attempt(candidate.id, true),
         true <- immutable?(attempt, candidate),
         {:ok, %{state: :reserved}} <- reservation(attempt),
         # Locks may have waited past either cutoff.
         now = ChatwootAdapter.now(),
         true <- DateTime.before?(now, cutoff) and DateTime.before?(now, attempt.deadline_at),
         true <- control.status == :enabled do
      change(attempt, %{dispatched_at: now})
    else
      _ -> {:error, :dispatch_denied}
    end
  end

  defp dispatch(_, _, _), do: {:error, :dispatch_denied}

  defp invoke(attempt, payload, wire, approved_locale) do
    with false <- Repo.in_transaction?(),
         remaining when remaining > 0 <-
           DateTime.diff(attempt.deadline_at, ChatwootAdapter.now(), :millisecond) do
      ref = make_ref()
      timeout = min(remaining, 45_000)

      opts =
        GenerationTransport.options(attempt, {self(), ref}, wire, timeout, attempt.deadline_at)

      key = {__MODULE__, :prompt}
      Process.put(key, {ref, payload, [total_timeout: timeout, req_http_options: opts]})

      result =
        try do
          SupportProposal
          |> Ash.ActionInput.for_action(:prompt, %{text: payload}, actor: %__MODULE__{ref: ref})
          |> Ash.run_action()
        rescue
          _ -> :invalid
        catch
          :exit, _ -> :invalid
        after
          Process.delete(key)
        end

      case {GenerationTransport.take(attempt, ref), result} do
        {{:usage, usage, true}, {:ok, %{locale: ^approved_locale}}} -> {:usage, usage, result}
        {{:usage, usage, _}, _} -> {:usage, usage, :invalid}
        {:unknown, _} -> :unknown
      end
    else
      _ -> :unknown
    end
  end

  @doc false
  def configure_prompt(flow, %{actor: %__MODULE__{ref: ref}}) do
    {^ref, _payload, req_options} = Process.get({__MODULE__, :prompt})
    %{flow | req_llm_opts: Keyword.merge(flow.req_llm_opts, req_options)}
  end

  @doc "Fence a due generation attempt and retain its hold if dispatch was committed."
  def recover(id) do
    case transaction(id, nil, fn control, current, hold ->
           if current.state == :running and
                not DateTime.before?(ChatwootAdapter.now(), current.deadline_at),
              do: expire(control, current, hold, :deadline),
              else: {:ok, :noop}
         end) do
      {:ok, {:attention, reason, attempt}} -> alert(attempt, reason)
      {:ok, _} -> :ok
      {:error, :missing_attempt} -> :ok
      _ -> {:error, :generation_storage}
    end
  end

  defp expire(control, %{dispatched_at: nil} = attempt, hold, reason) do
    now = ChatwootAdapter.now()

    with {:ok, :released} <- finish(control, attempt, hold, now, {:release, reason}),
         {:ok, _} <- change(attempt, %{state: :rejected, finished_at: now, reason_code: reason}) do
      {:ok, :released}
    end
  end

  defp expire(control, attempt, hold, reason) do
    now = ChatwootAdapter.now()

    with {:ok, :unknown} <- finish(control, attempt, hold, now, {:hold, reason}),
         {:ok, result} <-
           change(attempt, %{state: :unknown, finished_at: now, reason_code: reason}) do
      {:ok, {:attention, reason, result}}
    end
  end

  defp settle(control, %{state: :running} = attempt, hold, :unknown) do
    with {:ok, {:attention, reason, _}} <- expire(control, attempt, hold, :transport_unknown),
         do: {:ok, {:attention, reason}}
  end

  defp settle(
         control,
         %{state: state, dispatched_at: marker, input_tokens: nil} = attempt,
         hold,
         {:usage, usage, result}
       )
       when not is_nil(marker) and state in [:running, :unknown, :abandoned] do
    now = ChatwootAdapter.now()
    valid = match?({:ok, %VoelgoedAi.Support.SupportDecision{}}, result)
    status = if valid, do: :valid, else: :invalid_proposal

    with {:ok, accounting} <-
           finish(
             control,
             attempt,
             hold,
             now,
             {:usage, usage.input_tokens, usage.output_tokens, status}
           ) do
      apply_usage(attempt, now, usage, result, status, accounting)
    end
  end

  defp settle(_, %{input_tokens: input} = attempt, _, {:usage, usage, _})
       when not is_nil(input) do
    if Map.take(attempt, [
         :provider_request_id,
         :provider_response_id,
         :input_tokens,
         :output_tokens
       ]) ==
         Map.drop(usage, [:duration_us]),
       do: {:ok, :noop},
       else: {:error, :conflicting_evidence}
  end

  defp settle(_, _, _, _), do: {:ok, :noop}

  defp apply_usage(%{state: :abandoned}, _, _, _, _, :amount_overflow),
    do: {:ok, {:attention, :amount_overflow}}

  defp apply_usage(attempt, now, _, _, _, :amount_overflow) do
    with {:ok, _} <-
           change(attempt, %{state: :unknown, finished_at: now, reason_code: :amount_overflow}),
         do: {:ok, {:attention, :amount_overflow}}
  end

  defp apply_usage(%{state: :abandoned} = attempt, _, usage, _, _, accounting) do
    with {:ok, _} <- change(attempt, usage) do
      # The first ceiling charge and terminal attempt state stay immutable.
      if accounting == :late_over_reserve,
        do: {:ok, {:attention, :over_reserve}},
        else: {:ok, :settled}
    end
  end

  defp apply_usage(attempt, now, usage, result, status, accounting) do
    changes = %{
      state: if(status == :valid, do: :succeeded, else: :failed),
      reason_code: if(accounting == :trusted_usage, do: nil, else: accounting),
      finished_at: now
    }

    with {:ok, _} <- change(attempt, Map.merge(usage, changes)) do
      case {accounting, attempt.state, result} do
        {:over_reserve, _, _} -> {:ok, {:attention, :over_reserve}}
        {:trusted_usage, :running, {:ok, decision}} -> {:ok, {:proposal, decision}}
        _ -> {:ok, :settled}
      end
    end
  end

  defp close(control, %{state: :unknown} = attempt, hold, staff_id) do
    now = ChatwootAdapter.now()

    with {:ok, :conservative_closure} <-
           finish(control, attempt, hold, now, {:conservative_closure, staff_id}),
         {:ok, row} <-
           change(attempt, %{
             state: :abandoned,
             finished_at: now,
             reason_code: :conservative_closure
           }) do
      {:ok, %{id: row.id, state: row.state}}
    else
      {:ok, :amount_overflow} -> {:ok, %{id: attempt.id, state: :unknown}}
      error -> error
    end
  end

  defp close(_, %{state: :abandoned, id: id}, _, _), do: {:ok, %{id: id, state: :abandoned}}
  defp close(_, _, _, _), do: {:error, :not_unknown}

  defp transaction(id, fence, work) do
    Repo.transact(fn ->
      with {:ok, control} <- Configuration.lock_control(),
           {:ok, candidate} <- read_attempt(id, false),
           true <- is_nil(fence) or candidate.dispatch_fence == fence,
           {:ok, attempt, hold} <- lock_money(candidate) do
        work.(control, attempt, hold)
      else
        false -> {:error, :stale_fence}
        error -> error
      end
    end)
  end

  defp lock_money(candidate) do
    # Money is owned by the original parent even after binding/assistant
    # authorization changes. There is no permission read in this phase.
    with {:ok, %SupportRun{} = run} <-
           Ownership.get(SupportRun, candidate.support_run_id, lock: true),
         {:ok, attempt} <- read_attempt(candidate.id, true),
         true <-
           immutable?(attempt, candidate) and run.turn_ref == attempt.turn_ref and
             run.assistant_revision_id == attempt.assistant_revision_id,
         {:ok, hold} <- reservation(attempt) do
      {:ok, attempt, hold}
    else
      _ -> {:error, :stale_fence}
    end
  end

  defp immutable?(current, candidate) do
    keys = [
      :id,
      :dispatch_fence,
      :turn_ref,
      :ordinal,
      :support_run_id,
      :assistant_revision_id,
      :claim_generation,
      :deadline_at,
      :provider,
      :model_id,
      :profile_id,
      :prompt_version
    ]

    Map.take(current, keys) == Map.take(candidate, keys)
  end

  @doc false
  def authorize_accounting(ref, id, action) do
    if is_reference(ref) and Repo.in_transaction?() and
         Process.get({__MODULE__, :accounting}) == {ref, id, action},
       do: :ok,
       else: {:error, :denied}
  end

  defp reservation(attempt),
    do: account(attempt, :lock_reservation, &Accounting.lock_reservation(&1, attempt))

  defp finish(control, attempt, hold, now, outcome),
    do: account(attempt, :finish, &Accounting.finish(&1, control, attempt, hold, now, outcome))

  defp account(attempt, action, work) do
    ref = make_ref()
    key = {__MODULE__, :accounting}
    Process.put(key, {ref, attempt.id, action})

    try do
      work.({__MODULE__, ref})
    after
      Process.delete(key)
    end
  end

  defp read_attempt(id, lock) do
    case read(:storage_row, %{id: id}, fn query ->
           Ash.read_one(if lock, do: Ash.Query.lock(query, :for_update), else: query)
         end) do
      {:ok, %{purpose: :generate} = row} -> {:ok, row}
      {:ok, _} -> {:error, :missing_attempt}
      error -> error
    end
  end

  defp read(action, args, work),
    do: storage(action, &work.(Ash.Query.for_read(InferenceRun, action, args, actor: &1)))

  defp change(row, attrs),
    do: storage(:change_row, &Ash.update(row, attrs, action: :change_row, actor: &1))

  defp storage(action, work) do
    ref = make_ref()
    key = {__MODULE__, :storage}
    Process.put(key, {ref, InferenceRun, action})

    try do
      work.(%Storage{ref: ref, owner: __MODULE__})
    after
      Process.delete(key)
    end
  end

  defp barrier(fixture, stage, attempt),
    do: Map.get(fixture, stage, fn _ -> :ok end).(attempt)

  defp alert(attempt, reason) do
    :telemetry.execute([:voelgoed_ai, :intelligence, :generation_attention], %{count: 1}, %{
      inference_run_id: attempt.id,
      correlation_id: attempt.correlation_id,
      reason: reason
    })
  end
end
