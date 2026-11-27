defmodule VoelgoedAi.Governance.FinancialControl do
  @moduledoc """
  Authorizes synthetic staff closure and inhibit reset for one operation and target.
  Locks the current staff row before the singleton accounting control. The
  financial state and its audit commit in the same transaction.
  """

  use Ash.Policy.SimpleCheck
  use Ash.Resource.Actions.Implementation

  @impl Ash.Policy.Check
  def describe(_),
    do: "the synthetic financial decision matches the staff session and action target"

  if Mix.env() == :test do
    alias VoelgoedAi.Accounts.StaffAccess
    alias VoelgoedAi.Accounts.StaffAccess.Session
    alias VoelgoedAi.Governance.{AuditEvent, EmbeddingAccounting}
    alias VoelgoedAi.Intelligence.{Embedding, Generation}
    alias VoelgoedAi.Knowledge.Storage
    alias VoelgoedAi.Repo
    alias VoelgoedAi.Support.Configuration

    @impl Ash.Policy.SimpleCheck
    def match?(%Session{id: id}, %{subject: %Ash.ActionInput{} = input}, _) do
      approved?(input.action.name, id, target(input.arguments))
    end

    def match?(_, _, _), do: false

    @decision {__MODULE__, :decision}

    @doc "Scope one local synthetic financial decision to its action, staff ID and target."
    def with_decision(operation, actor_id, target, work) when is_function(work, 0) do
      if is_nil(Process.get(@decision)) and not Repo.in_transaction?() do
        Process.put(@decision, {operation, actor_id, target})

        try do
          work.()
        after
          Process.delete(@decision)
        end
      else
        {:error, :financial_decision_denied}
      end
    end

    defp approved?(action, actor, target),
      do: not is_nil(target) and Process.get(@decision) == {action, actor, target}

    defp budget(:embedding), do: Embedding.fixture_budget()
    defp budget(:generation), do: {:ok, Generation.fixture_budget(%{})}
    defp target(%{id: id}), do: id
    defp target(%{lane: lane, occurrence: occurrence}), do: {lane, occurrence}
    defp target(_), do: nil

    @doc false
    def with_authority(input, session, work) do
      StaffAccess.with_current(session, :admin, fn staff ->
        with true <- approved?(input.action.name, staff.id, target(input.arguments)),
             {:ok, control} <- Configuration.lock_control() do
          work.(control, staff.id)
        else
          _ -> {:error, :financial_decision_denied}
        end
      end)
    end

    @impl Ash.Resource.Actions.Implementation
    def run(
          %{
            action: %{name: :reset_financial_inhibit},
            arguments: %{lane: lane, occurrence: occurrence}
          } = input,
          _,
          %{actor: session}
        ) do
      with_authority(input, session, fn control, staff_id ->
        reset(control, staff_id, lane, occurrence)
      end)
      |> case do
        {:ok, value} -> {:ok, value}
        _ -> {:error, "financial inhibit reset denied"}
      end
    end

    defp reset(control, staff_id, lane, occurrence) do
      {flag, current, action, event, now} = reset_attributes(control, lane)

      with true <- flag and current == occurrence,
           {:ok, config} <- budget(lane),
           :ok <- EmbeddingAccounting.reset_headroom(lane, now, config),
           {:ok, _} <-
             storage(
               control.__struct__,
               action,
               &Ash.update(control, %{}, action: action, actor: &1)
             ),
           {:ok, _} <-
             append(%{
               actor_kind: :staff,
               actor_staff_id: staff_id,
               target_kind: :automation_control,
               control_target_id: control.id,
               event: event,
               reason_code: :local_admin,
               operational_before: %{status: control.status, inhibited: true},
               operational_after: %{status: control.status, inhibited: false},
               correlation_id: occurrence,
               occurred_at: now
             }) do
        {:ok, %{lane: lane, occurrence: occurrence}}
      else
        false -> {:error, :stale_inhibit}
        error -> error
      end
    end

    defp reset_attributes(control, :embedding) do
      {control.embedding_inhibited, control.embedding_inhibit_occurrence,
       :clear_embedding_inhibit, :reset_embedding_inhibit, Embedding.now()}
    end

    defp reset_attributes(control, :generation) do
      {control.generation_inhibited, control.generation_inhibit_occurrence,
       :clear_generation_inhibit, :reset_generation_inhibit,
       VoelgoedAi.Support.ChatwootAdapter.now()}
    end

    defp append(attrs) do
      storage(
        AuditEvent,
        :append_financial,
        &Ash.create(AuditEvent, attrs, action: :append_financial, actor: &1)
      )
    end

    defp storage(resource, action, work) do
      ref = make_ref()
      key = {__MODULE__, :storage}
      Process.put(key, {ref, resource, action})

      try do
        work.(%Storage{ref: ref, owner: __MODULE__})
      after
        Process.delete(key)
      end
    end
  else
    @impl Ash.Policy.SimpleCheck
    def match?(_, _, _), do: false

    @impl Ash.Resource.Actions.Implementation
    def run(_, _, _), do: {:error, "financial inhibit reset denied"}
  end
end
