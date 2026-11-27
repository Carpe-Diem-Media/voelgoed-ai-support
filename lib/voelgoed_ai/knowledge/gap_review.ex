defmodule VoelgoedAi.Knowledge.GapReview do
  @moduledoc """
  Runs scoped gap review under the staff and control locks. Each action
  compares the submitted version and writes the review and its audit together.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_), do: "a current staff session with explicit gap scope"

  if Mix.env() == :test do
    require Ash.Query

    alias VoelgoedAi.Accounts.StaffAccess
    alias VoelgoedAi.Accounts.StaffAccess.Session
    alias VoelgoedAi.Governance.AuditEvent
    alias VoelgoedAi.Knowledge.{GapEvidence, KnowledgeGap, Retrieval, Storage}
    alias VoelgoedAi.Repo
    alias VoelgoedAi.Support.Configuration

    @editor :knowledge_editor
    @reviewer :knowledge_reviewer
    @operator :support_operator
    @open_roles [@editor, @reviewer, @operator]
    @page_size 25

    @impl Ash.Policy.SimpleCheck
    def match?(%Session{}, %{subject: %Ash.ActionInput{}}, _opts), do: true
    def match?(_, _, _), do: false

    @impl Ash.Resource.Actions.Implementation
    def run(input, _, %{actor: session}) do
      StaffAccess.with_current(session, nil, fn staff ->
        with {:ok, _} <- Configuration.lock_control(),
             {:ok, scope} <- scope(staff, roles(input.action.name)) do
          execute(input.action.name, input.arguments, scope, staff)
        end
      end)
      |> case do
        {:ok, _} = success ->
          success

        {:error, reason} when reason in [:denied, :stale_review, :ineligible_revision] ->
          {:error, Atom.to_string(reason)}

        _ ->
          {:error, "gap storage failed"}
      end
    end

    @doc "Checks admission to the gap route without extending editorial access."
    def access(session) do
      StaffAccess.with_current(session, nil, fn staff ->
        with {:ok, _} <- scope(staff, @open_roles), do: {:ok, :authorized}
      end)
    end

    @doc false
    def register(owner, %{id: id, state: :completed, shadow_disposition: :local_handoff}, finding) do
      with true <- Repo.in_transaction?() and Retrieval.worker_owner?(owner),
           %{support_run_id: ^id, evidence: {_, _, evidence}} <- finding,
           origin = Map.drop(finding, [:evidence, :support_run_id]),
           {:ok, nil} <- read([support_run_id: id], &Ash.read_one/1),
           {:ok, prior} <- terminal(origin),
           [first, second | _] = Enum.map(evidence, &elem(&1, 0)) ++ [nil, nil] do
        attrs =
          Map.merge(origin, %{
            support_run_id: id,
            first_source_id: first,
            second_source_id: second,
            recurrence_of_id: prior && prior.id
          })

        storage(
          KnowledgeGap,
          :register,
          &Ash.create(KnowledgeGap, attrs, action: :register, actor: &1)
        )
      else
        {:ok, %KnowledgeGap{}} -> {:error, :duplicate_gap_origin}
        {:error, _} = error -> error
        _ -> {:error, :denied}
      end
    end

    defp terminal(origin) do
      filters =
        origin
        |> Map.delete(:assistant_revision_id)
        |> Map.to_list()
        |> Keyword.put(:status, in: [:dismissed, :addressed])

      read(filters, fn query ->
        query |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(1) |> Ash.read_one()
      end)
    end

    defp scope(staff, roles) do
      with %{
             binding_id: binding,
             assistant_id: assistant,
             collection_id: collection,
             staff_ids: ids
           } <-
             GapEvidence.fixture(),
           true <- staff.id in ids and Enum.any?(roles, &(&1 in staff.roles)) do
        {:ok, [binding_id: binding, assistant_id: assistant, collection_id: collection]}
      else
        _ -> {:error, :denied}
      end
    end

    defp address(gap, args, staff) do
      if args.attested and
           VoelgoedAi.Knowledge.Editorial.reviewer_scope?(gap.collection_id, staff) and
           GapEvidence.addressable?(gap, args.revision_id, DateTime.utc_now()) do
        {:ok, %{status: :addressed, resolved_revision_id: args.revision_id}}
      else
        {:error, :ineligible_revision}
      end
    end

    defp roles(:address), do: [@reviewer]
    defp roles(:dismiss), do: [@reviewer, @operator]
    defp roles(_), do: @open_roles

    defp execute(:list_gaps, args, scope, staff) do
      before_id = args[:before_id]

      with {:ok, rows} <-
             read(scope, fn query ->
               query = if before_id, do: Ash.Query.filter(query, id < ^before_id), else: query
               query |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(@page_size + 1) |> Ash.read()
             end) do
        page = Enum.take(rows, @page_size)

        {:ok,
         %{
           rows: Enum.map(page, &view/1),
           before_id: if(length(rows) > @page_size, do: List.last(page).id),
           can_address: @reviewer in staff.roles,
           can_dismiss: Enum.any?([@reviewer, @operator], &(&1 in staff.roles))
         }}
      end
    end

    defp execute(action, args, scope, staff) do
      with {:ok, %KnowledgeGap{} = gap} <-
             read([id: args.id] ++ scope, &(&1 |> Ash.Query.lock(:for_update) |> Ash.read_one())),
           true <- gap.review_version == args.expected_version,
           {:ok, attrs} <- transition(gap, action, args, staff),
           attrs = Map.put(attrs, :review_version, gap.review_version + 1),
           {:ok, updated} <-
             storage(KnowledgeGap, :change_review, fn actor ->
               Ash.update(gap, attrs, action: :change_review, actor: actor)
             end),
           {:ok, _} <- audit(gap, updated, staff, action) do
        {:ok, view(updated)}
      else
        {:ok, nil} -> {:error, :denied}
        false -> {:error, :stale_review}
        error -> error
      end
    end

    defp transition(%{status: :open}, :review, _, _), do: {:ok, %{status: :in_review}}
    defp transition(%{status: :in_review}, :defer, _, _), do: {:ok, %{status: :open}}

    defp transition(%{status: :in_review}, :dismiss, %{reason: reason}, _),
      do: {:ok, %{status: :dismissed, dismissal_reason: reason}}

    defp transition(%{status: :in_review} = gap, :address, args, staff),
      do: address(gap, args, staff)

    defp transition(_, _, _, _), do: {:error, :stale_review}

    defp audit(before, after_review, staff, action) do
      event = %{
        review: :gap_reviewed,
        defer: :gap_deferred,
        dismiss: :gap_dismissed,
        address: :gap_addressed
      }

      attrs = %{
        actor_kind: :staff,
        actor_staff_id: staff.id,
        target_kind: :knowledge_gap,
        knowledge_gap_target_id: before.id,
        event: Map.fetch!(event, action),
        reason_code: after_review.dismissal_reason || :local_admin,
        operational_before: %{status: before.status, version: before.review_version},
        operational_after: %{status: after_review.status, version: after_review.review_version},
        correlation_id: Ash.UUIDv7.generate()
      }

      storage(
        AuditEvent,
        :append_gap_review,
        &Ash.create(AuditEvent, attrs, action: :append_gap_review, actor: &1)
      )
    end

    defp view(gap) do
      Map.take(gap, [
        :id,
        :topic,
        :locale,
        :applicability,
        :cause,
        :status,
        :review_version,
        :inserted_at,
        :dismissal_reason,
        :resolved_revision_id,
        :recurrence_of_id
      ])
    end

    defp read(filters, operation) do
      storage(KnowledgeGap, :scoped_rows, fn actor ->
        KnowledgeGap
        |> Ash.Query.for_read(:scoped_rows, %{}, actor: actor)
        |> Ash.Query.filter(^filters)
        |> operation.()
      end)
    end

    defp storage(resource, action, operation) do
      key = {__MODULE__, :storage}
      ref = make_ref()
      Process.put(key, {ref, resource, action})

      try do
        operation.(%Storage{ref: ref, owner: __MODULE__})
      after
        Process.delete(key)
      end
    end
  else
    @impl Ash.Policy.SimpleCheck
    def match?(_, _, _), do: false

    @impl Ash.Resource.Actions.Implementation
    def run(_, _, _), do: {:error, "gap review is disabled"}
  end
end
