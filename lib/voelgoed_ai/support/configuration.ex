defmodule VoelgoedAi.Support.Configuration do
  @moduledoc """
  Runs authorized configuration actions on the application Repo. Staff grants
  and rows are rechecked under locks. Audit and epoch changes commit together.

  Every mutation locks rows in one order: staff row, global control,
  assistants in id order, then the binding. Later support work follows the
  same order before it locks sessions, so the two cannot deadlock.
  """

  use Ash.Resource.Actions.Implementation

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Accounts.StaffAccess.Session
  alias VoelgoedAi.Governance.{AuditEvent, AutomationControl}
  alias VoelgoedAi.Intelligence.{Assistant, AssistantKnowledgeGrant, AssistantRevision}
  alias VoelgoedAi.Knowledge.KnowledgeCollection
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.{ActionScope, InboxBinding, Ownership}
  alias VoelgoedAi.Support.ActionScope.Storage

  @revision_fields [:workflow_version, :template_version, :locale, :response_policy]
  @inbox_fields [:installation_ref, :external_account_id, :external_inbox_id]
  @grant_limit 20
  @grant_actions [:grant_collection, :remove_collection]
  @routing_fields [:credential_ref, :handoff_team_id]

  @impl true
  def run(input, _opts, %{actor: %Session{} = session}) do
    StaffAccess.with_current(session, :admin, fn admin ->
      execute(input.resource, input.action.name, input.arguments, admin.id)
    end)
    |> result()
  end

  def run(input, _opts, %{actor: scope}) do
    if ActionScope.permits?(scope, input) do
      Repo.transact(fn -> scoped_read(input.resource, input.arguments, scope.inbox) end)
      |> result()
    else
      {:error, "configuration access denied"}
    end
  end

  defp execute(Assistant, :create, args, admin) do
    insert(Assistant, Map.put(args, :disabled_at, DateTime.utc_now()), :create, admin)
  end

  defp execute(Assistant, :read_configuration, %{id: id}, _admin),
    do: project(get(Assistant, id))

  defp execute(Assistant, action, %{id: id}, admin) do
    with {:ok, assistant} <- get(Assistant, id, :for_update),
         {:ok, attrs} <- assistant_transition(assistant, action) do
      transition(assistant, attrs, action, admin)
    end
  end

  defp execute(AssistantRevision, :create_draft, %{assistant_id: id} = args, admin) do
    with {:ok, assistant} <- get(Assistant, id, :for_update),
         :ok <- editable_assistant(assistant),
         {:ok, latest} <- read(AssistantRevision, :latest_revision, %{assistant_id: id}) do
      number = if latest, do: latest.revision_number + 1, else: 1
      attrs = Map.merge(args, %{created_by_id: admin, revision_number: number})
      insert(AssistantRevision, attrs, :create_draft, admin)
    end
  end

  defp execute(AssistantRevision, :read_configuration, %{id: id}, _admin),
    do: project(get(AssistantRevision, id))

  defp execute(AssistantRevision, action, %{id: id} = args, admin) do
    # Read the immutable parent key first. Every draft operation then locks the
    # assistant before locking or changing any of its revisions.
    with :ok <- lock_grant_control(action),
         {:ok, candidate} <- get(AssistantRevision, id),
         {:ok, assistant} <- get(Assistant, candidate.assistant_id, :for_update),
         :ok <- editable_assistant(assistant) do
      locked_revision_action(assistant, action, args, admin)
    end
  end

  defp execute(InboxBinding, :create_draft, %{assistant_id: id} = args, admin) do
    with {:ok, assistant} <- get(Assistant, id, :for_update),
         :ok <- editable_assistant(assistant),
         {:ok, fixture} <- binding_fixture(args) do
      insert(
        InboxBinding,
        Map.merge(args, Map.take(fixture, @routing_fields)),
        :create_draft,
        admin
      )
    end
  end

  defp execute(InboxBinding, :read_configuration, %{id: id}, _admin),
    do: project(get(InboxBinding, id))

  defp execute(InboxBinding, action, %{id: id} = args, admin) do
    with {:ok, binding} <- lock_binding(id, rebind_target(action, args)),
         {:ok, attrs} <- binding_transition(binding, action, args) do
      transition(binding, epoch(binding, attrs), action, admin)
    end
  end

  defp execute(AutomationControl, :read_configuration, %{}, _admin),
    do: project(get(AutomationControl, :global))

  defp execute(AutomationControl, action, args, admin) do
    with {:ok, control} <- get(AutomationControl, :global, :for_update),
         {:ok, attrs} <- control_transition(control, action, args) do
      transition(control, epoch(control, attrs), action, admin)
    end
  end

  defp execute(AuditEvent, :operational_history, args, _admin), do: history(args)

  defp assistant_transition(%{status: :disabled} = assistant, :activate) do
    with :ok <- published_fixture(assistant) do
      {:ok, epoch(assistant, %{status: :active, disabled_at: nil})}
    end
  end

  defp assistant_transition(%{status: :active} = assistant, :disable),
    do: {:ok, epoch(assistant, %{status: :disabled, disabled_at: DateTime.utc_now()})}

  # In this slice no work can be admitted. The disabled state and new epoch
  # fence the assistant without deleting its pointer or history. Enabled
  # bindings must be disabled first. The assistant lock held here blocks a
  # concurrent enable or rebind, which locks the assistant before the binding.
  defp assistant_transition(%{status: :disabled} = assistant, :retire) do
    case read(InboxBinding, :enabled_for_assistant, %{assistant_id: assistant.id}) do
      {:ok, nil} -> {:ok, epoch(assistant, %{status: :retired})}
      {:ok, _binding} -> {:error, :enabled_binding}
      error -> error
    end
  end

  defp assistant_transition(_, _), do: {:error, :invalid_transition}

  defp editable_assistant(%{status: :retired}), do: {:error, :invalid_transition}
  defp editable_assistant(_assistant), do: :ok

  defp locked_revision_action(assistant, :publish, args, admin) do
    prior_id = assistant.active_revision_id

    with :ok <- expected_pointer(assistant, Map.fetch(args, :expected_active_revision_id)),
         {:ok, rows} <- lock_publication_revisions(assistant, args.id),
         %{status: :draft} = draft <- Map.fetch!(rows, args.id) do
      publish_revision(draft, Map.get(rows, prior_id), assistant, admin)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transition}
    end
  end

  defp locked_revision_action(assistant, action, %{id: id} = args, admin) do
    with {:ok, %{status: :draft} = revision} <- lock_owned_revision(assistant, id) do
      revision_transition(revision, assistant, action, args, admin)
    else
      {:ok, _} -> {:error, :invalid_transition}
      error -> error
    end
  end

  defp lock_publication_revisions(assistant, candidate_id) do
    [candidate_id, assistant.active_revision_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn id, {:ok, rows} ->
      case lock_owned_revision(assistant, id) do
        {:ok, row} -> {:cont, {:ok, Map.put(rows, id, row)}}
        error -> {:halt, error}
      end
    end)
  end

  defp lock_owned_revision(assistant, id) do
    case get(AssistantRevision, id, :for_update) do
      {:ok, %{assistant_id: owner} = row} when owner == assistant.id -> {:ok, row}
      {:ok, _} -> {:error, :invalid_revision_pointer}
      error -> error
    end
  end

  defp revision_transition(revision, assistant, action, %{collection_id: id}, admin)
       when action in @grant_actions do
    with {:ok, %KnowledgeCollection{} = collection} <- collection(id, :for_update),
         {:ok, grants} <- grants(revision.id),
         {:ok, changed?} <- change_grant(action, assistant, revision, collection, grants),
         :ok <- audit_grant(changed?, revision, collection, action, admin),
         {:ok, grants} <- grants(revision.id) do
      {:ok, Map.put(projection(revision), :collection_ids, Enum.map(grants, & &1.collection_id))}
    else
      {:ok, nil} -> {:error, :inactive_collection}
      error -> error
    end
  end

  defp revision_transition(revision, _assistant, :edit_draft, args, admin) do
    attrs =
      args |> Map.take(@revision_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)

    transition(revision, attrs, :edit_draft, admin)
  end

  defp revision_transition(revision, _assistant, :discard, _args, admin),
    do: transition(revision, %{status: :discarded}, :discard, admin)

  defp publish_revision(revision, previous, assistant, admin) do
    with {:ok, grants} <- grants(revision.id),
         :ok <- validate_grants(assistant, grants),
         collection_ids = Enum.map(grants, & &1.collection_id),
         {:ok, hash} <- fixture_hash(%{revision | config_hash_version: 2}, collection_ids),
         :ok <- supersede(previous, admin),
         {:ok, published} <-
           change(
             revision,
             %{
               status: :published,
               config_hash: hash,
               config_hash_version: 2,
               published_by_id: admin,
               published_at: DateTime.utc_now()
             },
             :publish,
             admin
           ),
         {:ok, _} <-
           change(
             assistant,
             epoch(assistant, %{active_revision_id: revision.id}),
             :switch_revision,
             admin
           ) do
      {:ok, Map.put(projection(published), :collection_ids, collection_ids)}
    end
  end

  defp lock_grant_control(action) when action in [:publish | @grant_actions] do
    with {:ok, _control} <- lock_control(), do: :ok
  end

  defp lock_grant_control(_action), do: :ok

  @doc false
  def lock_control, do: get(AutomationControl, :global, :for_update)

  defp change_grant(:grant_collection, assistant, revision, collection, grants) do
    with :ok <- eligible_grant(assistant, collection) do
      cond do
        Enum.any?(grants, &(&1.collection_id == collection.id)) ->
          {:ok, false}

        length(grants) >= @grant_limit ->
          {:error, :grant_limit}

        true ->
          attrs = %{assistant_revision_id: revision.id, collection_id: collection.id}

          with {:ok, _} <-
                 storage(AssistantKnowledgeGrant, :create_grant, fn actor ->
                   Ash.create(AssistantKnowledgeGrant, attrs, action: :create_grant, actor: actor)
                 end),
               do: {:ok, true}
      end
    end
  end

  defp change_grant(:remove_collection, _assistant, _revision, collection, grants) do
    case Enum.find(grants, &(&1.collection_id == collection.id)) do
      nil ->
        {:ok, false}

      grant ->
        with :ok <-
               storage(AssistantKnowledgeGrant, :remove_grant, fn actor ->
                 Ash.destroy(grant, action: :remove_grant, actor: actor)
               end),
             do: {:ok, true}
    end
  end

  defp collection(id, lock), do: read(KnowledgeCollection, :storage_row, %{id: id}, lock)

  defp grants(id) do
    storage(AssistantKnowledgeGrant, :for_revision, fn actor ->
      AssistantKnowledgeGrant
      |> Ash.Query.for_read(:for_revision, %{id: id}, actor: actor)
      |> Ash.read()
    end)
  end

  # IDs are sorted by the storage read. Collection changes also hold control,
  # so eligibility and membership remain stable until the pointer commits.
  defp validate_grants(assistant, grants) when length(grants) <= @grant_limit do
    Enum.reduce_while(grants, :ok, fn grant, :ok ->
      case collection(grant.collection_id, :for_update) do
        {:ok, row} ->
          case eligible_grant(assistant, row) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp validate_grants(_assistant, _grants), do: {:error, :grant_limit}

  defp eligible_grant(%{audience: :public}, %{audience: :internal}),
    do: {:error, :internal_collection}

  defp eligible_grant(_assistant, %{status: :active}), do: :ok
  defp eligible_grant(_assistant, _collection), do: {:error, :inactive_collection}

  defp audit_grant(false, _revision, _collection, _action, _admin), do: :ok

  defp audit_grant(true, revision, collection, action, admin) do
    with {:ok, _} <- audit(revision, revision, action, admin, %{collection_id: collection.id}),
         do: :ok
  end

  defp expected_pointer(%{active_revision_id: expected}, {:ok, expected}), do: :ok
  defp expected_pointer(_, :error), do: {:error, :missing_expected_revision_pointer}
  defp expected_pointer(_, _), do: {:error, :stale_revision_pointer}

  defp supersede(nil, _admin), do: :ok

  defp supersede(%{status: :published} = revision, admin) do
    with {:ok, _} <- change(revision, %{status: :superseded}, :supersede, admin), do: :ok
  end

  defp supersede(_, _), do: {:error, :invalid_revision_pointer}

  defp binding_transition(%{status: status} = binding, :enable, _args)
       when status in [:draft, :disabled] do
    with :ok <- eligible_binding(binding) do
      {:ok, %{status: :enabled}}
    end
  end

  defp binding_transition(%{status: :enabled}, :disable, _args), do: {:ok, %{status: :disabled}}

  defp binding_transition(%{status: :disabled} = binding, :rebind, %{assistant_id: id}) do
    candidate = %{binding | assistant_id: id}

    with {:ok, fixture} <- binding_fixture(candidate),
         :ok <- eligible_assistant(id) do
      {:ok, Map.put(Map.take(fixture, @routing_fields), :assistant_id, id)}
    end
  end

  defp binding_transition(%{status: status} = binding, :change_mode, %{operating_mode: :automatic})
       when status != :retired do
    with :ok <- eligible_binding(binding),
         {:ok, :fake} <- control_mode(%{binding | operating_mode: :automatic}) do
      {:ok, %{operating_mode: :automatic}}
    end
  end

  defp binding_transition(%{status: status}, :change_mode, %{operating_mode: mode})
       when status != :retired,
       do: {:ok, %{operating_mode: mode}}

  defp binding_transition(%{status: :disabled}, :retire, _args), do: {:ok, %{status: :retired}}
  defp binding_transition(_, _, _), do: {:error, :invalid_transition}

  defp control_transition(_control, :disable_automation, _args),
    do: {:ok, %{status: :disabled, mode: :disabled}}

  defp control_transition(%{status: :disabled}, :enable_automation, %{binding_id: id}) do
    with {:ok, %{status: :enabled} = binding} <- lock_binding(id),
         :ok <- eligible_binding(binding),
         {:ok, mode} <- control_mode(binding) do
      {:ok, %{status: :enabled, mode: mode}}
    else
      {:ok, _} -> {:error, :invalid_transition}
      error -> error
    end
  end

  defp control_transition(_, _, _), do: {:error, :invalid_transition}

  defp control_mode(%{operating_mode: :automatic}) do
    if match?(%{response_policy: :shadow_decision}, fixture()),
      do: {:error, :invalid_transition},
      else: {:ok, :fake}
  end

  defp control_mode(%{operating_mode: :shadow} = binding) do
    with true <- Ownership.shadow_fixture?(binding),
         {:ok, assistant} <- get(Assistant, binding.assistant_id),
         {:ok, %{response_policy: :shadow_decision}} <- current_revision(assistant) do
      {:ok, :shadow_test}
    else
      _ -> {:error, :unverified_test_binding}
    end
  end

  defp control_mode(_), do: {:error, :invalid_transition}

  # The binding's assistant is read unlocked first so that its lock is taken
  # before the binding's. A rebind between the two reads is reported as a
  # conflict instead of locking a different assistant out of order.
  defp lock_binding(id, other_assistants \\ []) do
    with {:ok, candidate} <- get(InboxBinding, id),
         :ok <- lock_assistants([candidate.assistant_id | other_assistants]),
         {:ok, binding} <- get(InboxBinding, id, :for_update) do
      if binding.assistant_id == candidate.assistant_id,
        do: {:ok, binding},
        else: {:error, :concurrent_configuration_change}
    end
  end

  # UUID strings share one fixed format, so string order matches PostgreSQL's.
  defp lock_assistants(ids) do
    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case get(Assistant, id, :for_update) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def lock_inbox(inbox) do
    with {:ok, control} <- get(AutomationControl, :global, :for_update),
         {:ok, %InboxBinding{} = candidate} <- read(InboxBinding, :qualified_inbox, inbox),
         {:ok, assistant} <- get(Assistant, candidate.assistant_id, :for_update),
         {:ok, binding} <- get(InboxBinding, candidate.id, :for_update),
         true <- binding.assistant_id == assistant.id do
      {:ok, %{control: control, assistant: assistant, binding: binding}}
    else
      {:ok, nil} -> {:error, :scope_denied}
      false -> {:error, :concurrent_configuration_change}
      error -> error
    end
  end

  @doc false
  def current_revision(%Assistant{active_revision_id: id}) when is_binary(id) do
    with {:ok, %{status: :published} = revision} <- get(AssistantRevision, id),
         {:ok, hash} <- published_hash(revision),
         true <- hash == revision.config_hash do
      {:ok, revision}
    else
      _ -> {:error, :stale_policy}
    end
  end

  def current_revision(_), do: {:error, :stale_policy}

  @doc false
  def render_fixed_reply(assistant, run, delivery) do
    with {:ok, revision} <- current_revision(assistant),
         true <- revision.id == run.assistant_revision_id,
         :fixed_reply <- revision.response_policy,
         true <- revision.template_version == delivery.template_version,
         true <- revision.config_hash == delivery.template_hash,
         %{fixed_text: text} <- fixture() do
      {:ok, text}
    else
      _ -> {:error, :stale_policy}
    end
  end

  defp rebind_target(:rebind, %{assistant_id: id}), do: [id]
  defp rebind_target(_action, _args), do: []

  defp eligible_binding(binding) do
    with {:ok, fixture} <- binding_fixture(binding),
         true <- same_fields?(binding, fixture, @routing_fields) do
      eligible_assistant(binding.assistant_id)
    else
      _ -> {:error, :unverified_test_binding}
    end
  end

  defp eligible_assistant(id) do
    with {:ok, %{status: :active, audience: :public} = assistant} <-
           get(Assistant, id, :for_update) do
      published_fixture(assistant)
    else
      {:ok, _} -> {:error, :inactive_assistant}
      error -> error
    end
  end

  defp published_fixture(assistant) do
    with :public <- assistant.audience,
         id when not is_nil(id) <- assistant.active_revision_id,
         {:ok, %{status: :published, assistant_id: owner} = revision} <-
           get(AssistantRevision, id),
         true <- owner == assistant.id,
         {:ok, hash} <- published_hash(revision),
         true <- revision.config_hash == hash do
      :ok
    else
      _ -> {:error, :unverified_test_revision}
    end
  end

  defp binding_fixture(binding) do
    case fixture() do
      %{credential_ref: ref, handoff_team_id: team} = fixture
      when is_binary(ref) and is_integer(team) ->
        if same_fields?(binding, fixture, [:assistant_id | @inbox_fields]),
          do: {:ok, fixture},
          else: {:error, :unverified_test_binding}

      _ ->
        {:error, :unverified_test_binding}
    end
  end

  defp published_hash(%{config_hash_version: 1} = revision), do: fixture_hash(revision, [])

  defp published_hash(%{config_hash_version: 2} = revision) do
    with {:ok, grants} <- grants(revision.id),
         true <- length(grants) <= @grant_limit do
      fixture_hash(revision, Enum.map(grants, & &1.collection_id))
    else
      _ -> {:error, :stale_policy}
    end
  end

  if Mix.env() == :test do
    defp fixture_hash(%{response_policy: :shadow_decision} = revision, collection_ids) do
      version = VoelgoedAi.Support.DecisionTemplates.version()

      with %{shadow_evaluation: true} = fixture <- fixture(),
           true <- revision.workflow_version == version and revision.template_version == version,
           true <- revision.config_hash_version == 2,
           true <- same_fields?(revision, fixture, [:assistant_id | @revision_fields]) do
        value = Enum.map(@revision_fields, &Map.fetch!(revision, &1))
        {:ok, hash_revision([2, value, collection_ids])}
      else
        _ -> {:error, :unverified_test_revision}
      end
    end
  else
    defp fixture_hash(%{response_policy: :shadow_decision}, _),
      do: {:error, :unverified_test_revision}
  end

  defp fixture_hash(revision, collection_ids) do
    case fixture() do
      %{fixed_text: text} = fixture when is_binary(text) and byte_size(text) in 1..4096 ->
        if same_fields?(revision, fixture, [:assistant_id | @revision_fields]) do
          value = Enum.map(@revision_fields ++ [:fixed_text], &Map.fetch!(fixture, &1))

          # Preserve the original fixed-reply hash for predecessor rows.
          value =
            if revision.config_hash_version == 2, do: [2, value, collection_ids], else: value

          {:ok, hash_revision(value)}
        else
          {:error, :unverified_test_revision}
        end

      _ ->
        {:error, :unverified_test_revision}
    end
  end

  defp hash_revision(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  end

  # Only deterministic TEST fixtures can authorize activation in this slice.
  if Mix.env() == :test do
    defp fixture, do: Application.get_env(:voelgoed_ai, :support_fixture)
  else
    defp fixture, do: nil
  end

  defp same_fields?(left, right, fields), do: Map.take(left, fields) == Map.take(right, fields)
  defp epoch(row, attrs), do: Map.put(attrs, :security_epoch, row.security_epoch + 1)

  defp scoped_read(resource, args, {installation, account, inbox}) do
    with {:ok, %InboxBinding{} = binding} <-
           read(InboxBinding, :qualified_inbox, %{
             installation_ref: installation,
             external_account_id: account,
             external_inbox_id: inbox
           }) do
      scoped_configuration(resource, args, binding)
    else
      _ -> {:error, :denied}
    end
  end

  defp scoped_read(_, _, _), do: {:error, :denied}

  defp scoped_configuration(InboxBinding, %{id: id}, %{id: id} = binding),
    do: {:ok, projection(binding)}

  defp scoped_configuration(Assistant, %{id: id}, %{assistant_id: id}),
    do: project(get(Assistant, id))

  # Publication bumps the assistant epoch. A run pinned to a superseded
  # revision retains its FK for history, but cannot render another reply.
  defp scoped_configuration(AssistantRevision, %{id: id}, %{assistant_id: assistant_id}) do
    with {:ok, %{assistant_id: ^assistant_id, status: :published} = revision} <-
           get(AssistantRevision, id) do
      {:ok, projection(revision)}
    else
      _ -> {:error, :denied}
    end
  end

  defp scoped_configuration(AutomationControl, %{}, _binding),
    do: project(get(AutomationControl, :global))

  defp scoped_configuration(AuditEvent, %{target_kind: :inbox_binding, id: id} = args, %{id: id}),
    do: history(args)

  defp scoped_configuration(AuditEvent, %{target_kind: :assistant, id: id} = args, %{
         assistant_id: id
       }),
       do: history(args)

  defp scoped_configuration(
         AuditEvent,
         %{target_kind: :assistant_revision, id: id} = args,
         binding
       ) do
    with {:ok, _} <- scoped_configuration(AssistantRevision, %{id: id}, binding),
         do: history(args)
  end

  defp scoped_configuration(_, _, _), do: {:error, :denied}

  defp projection(%Assistant{} = row),
    do:
      Map.take(row, [
        :id,
        :slug,
        :display_name,
        :kind,
        :audience,
        :status,
        :active_revision_id,
        :security_epoch,
        :disabled_at
      ])

  defp projection(%AssistantRevision{} = row),
    do:
      Map.take(row, [
        :id,
        :assistant_id,
        :revision_number,
        :status,
        :config_hash,
        :config_hash_version,
        :published_at | @revision_fields
      ])

  defp projection(%InboxBinding{} = row),
    do:
      Map.take(row, [
        :id,
        :assistant_id,
        :status,
        :operating_mode,
        :handoff_team_id,
        :security_epoch | @inbox_fields
      ])

  defp projection(%AutomationControl{} = row),
    do: Map.take(row, [:id, :status, :mode, :security_epoch])

  defp project({:ok, row}), do: {:ok, projection(row)}
  defp project(error), do: error

  defp get(resource, id, lock \\ nil) do
    args = if id == :global, do: %{}, else: %{id: id}

    case read(resource, :configuration_row, args, lock) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp read(resource, action, args, lock \\ nil) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      query = if lock, do: Ash.Query.lock(query, lock), else: query
      Ash.read_one(query)
    end)
  end

  defp insert(resource, attrs, event, admin) do
    with {:ok, row} <-
           storage(
             resource,
             :create_row,
             &Ash.create(resource, attrs, action: :create_row, actor: &1)
           ),
         {:ok, _} <- audit(nil, row, event, admin) do
      {:ok, projection(row)}
    end
  end

  defp transition(row, attrs, event, admin), do: project(change(row, attrs, event, admin))

  defp change(%resource{} = row, attrs, event, admin) do
    with {:ok, updated} <-
           storage(resource, :update_row, &Ash.update(row, attrs, action: :update_row, actor: &1)),
         {:ok, _} <- audit(row, updated, event, admin) do
      {:ok, updated}
    end
  end

  defp audit(before, row, event, admin, metadata \\ %{}) do
    {kind, foreign_key} = audit_target(row.__struct__)

    attrs = %{
      foreign_key => row.id,
      target_kind: kind,
      actor_kind: :staff,
      actor_staff_id: admin,
      event: event,
      reason_code: :local_admin,
      operational_before: audit_state(before),
      operational_after: Map.merge(audit_state(row), metadata),
      correlation_id: Ash.UUIDv7.generate()
    }

    storage(AuditEvent, :append_operational, fn actor ->
      Ash.create(AuditEvent, audit_attributes(attrs), action: :append_operational, actor: actor)
    end)
  end

  if Mix.env() == :test do
    defp audit_attributes(%{event: event} = attrs) do
      if Process.get({__MODULE__, :reject_audit}) == event,
        do: Map.delete(attrs, :actor_staff_id),
        else: attrs
    end
  else
    defp audit_attributes(attrs), do: attrs
  end

  defp audit_state(nil), do: nil
  defp audit_state(row), do: projection(row) |> Map.drop([:id, :disabled_at, :published_at])

  defp audit_target(Assistant), do: {:assistant, :assistant_target_id}
  defp audit_target(AssistantRevision), do: {:assistant_revision, :revision_target_id}
  defp audit_target(InboxBinding), do: {:inbox_binding, :binding_target_id}
  defp audit_target(AutomationControl), do: {:automation_control, :control_target_id}

  defp history(args) do
    storage(AuditEvent, :operational_rows, fn actor ->
      AuditEvent
      |> Ash.Query.for_read(:operational_rows, args, actor: actor)
      |> Ash.read()
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         Enum.map(
           rows,
           &Map.take(&1, [
             :id,
             :event,
             :reason_code,
             :actor_staff_id,
             :target_kind,
             :correlation_id,
             :occurred_at,
             :operational_before,
             :operational_after
           ])
         )}

      error ->
        error
    end
  end

  # Only private calls in this module mint capabilities. They expire before
  # the action returns and cannot be reused across processes or actions.
  defp storage(resource, action, operation) do
    key = {__MODULE__, :storage}
    ref = make_ref()
    previous = Process.put(key, {ref, resource, action})

    try do
      operation.(%Storage{ref: ref})
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end

  defp result({:error, reason}) when is_atom(reason), do: {:error, Atom.to_string(reason)}
  defp result({:error, _}), do: {:error, "configuration storage failed"}
  defp result(success), do: success
end
