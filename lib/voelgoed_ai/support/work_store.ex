defmodule VoelgoedAi.Support.WorkStore do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.{Repo, Support}
  alias VoelgoedAi.Governance.AuditEvent

  alias VoelgoedAi.Support.{
    Delivery,
    InboundEvent,
    Ingress,
    OutboundDelivery,
    Ownership,
    Recovery,
    RunInput,
    RunProcessing,
    SupportRun,
    SupportSession,
    SystemAudit
  }

  @enforce_keys [:ref]
  defstruct @enforce_keys

  alias VoelgoedAi.Governance.MisuseProtection

  @owners %{
    Support => %{
      AuditEvent => [:append_support_operator],
      OutboundDelivery => [:for_session, :abandon],
      SupportSession => [:return_to_bot, :close]
    },
    Ingress => %{
      InboundEvent => [:by_identity, :register, :ignore, :quarantine, :dispatch, :pending],
      SupportRun => [:active],
      SupportSession => [:observe_signed_handoff_takeover]
    },
    Ownership => %{
      InboundEvent => [:by_id, :pending],
      OutboundDelivery => [:by_id, :for_session, :prepare],
      SupportRun => [:by_id, :active, :cancel],
      SupportSession => [
        :by_id,
        :by_conversation,
        :register,
        :activate_bot,
        :observe_human_takeover,
        :request_handoff,
        :confirm_handoff,
        :close,
        :inhibit_closed,
        :verify_owner
      ]
    },
    MisuseProtection => %{InboundEvent => [:misuse_facts, :record_misuse]},
    RunProcessing => %{
      InboundEvent => [:record_disposition, :pending],
      SupportSession => [:mark_verified_input],
      RunInput => [:cover, :release, :set_position, :for_run],
      SupportRun => [
        :active,
        :queue,
        :extend_batch,
        :claim,
        :complete,
        :complete_shadow,
        :complete_evidenced,
        :shadow_clarifications,
        :cancel,
        :supersede,
        :fail
      ]
    },
    Delivery => %{
      OutboundDelivery => [
        :for_session,
        :reserve_read,
        :claim,
        :authorize_dispatch,
        :confirm_sent,
        :cancel,
        :fail,
        :safe_retry,
        :mark_unknown,
        :reconcile
      ],
      SupportRun => [:active]
    },
    Recovery => %{
      SupportSession => [:idle_candidates],
      InboundEvent => [:pending],
      OutboundDelivery => [:recoverable, :safe_retry, :record_read_exhausted],
      SupportRun => [:recoverable, :recover_expired_claim, :requeue]
    },
    SystemAudit => %{AuditEvent => [:append_system, :system_rows]}
  }

  defmacro __using__(operations) do
    wrappers =
      Enum.map(operations, fn
        :read ->
          quote do
            defp store_read(resource, action, args, filter, opts \\ []) do
              unquote(__MODULE__).read(&work_store_owner/0, resource, action, args, filter, opts)
            end
          end

        :create ->
          quote do
            defp store_create(resource, action, attrs) do
              unquote(__MODULE__).create(&work_store_owner/0, resource, action, attrs)
            end
          end

        :update ->
          quote do
            defp store_update(row, action, attrs) do
              unquote(__MODULE__).update(&work_store_owner/0, row, action, attrs)
            end
          end
      end)

    quote do
      # The private local capture binds the caller at compile time.
      defp work_store_owner, do: __MODULE__
      unquote_splicing(wrappers)
    end
  end

  @impl true
  def describe(_opts), do: "an authorized support transaction owns this storage operation"

  @impl true
  def match?(%__MODULE__{ref: ref}, %{subject: subject}, _opts) when is_reference(ref) do
    case Process.get(__MODULE__) do
      {^ref, resource, action, owner}
      when resource == subject.resource and action == subject.action.name ->
        Repo.in_transaction?() and owned?(owner, resource, action)

      _ ->
        false
    end
  end

  def match?(_, _, _), do: false

  @doc false
  def read(owner, resource, action, args, filter, opts) do
    with_capability(owner, resource, action, fn actor ->
      query =
        resource
        |> Ash.Query.for_read(action, args, actor: actor)
        |> Ash.Query.filter_input(filter)

      query = if opts[:lock], do: Ash.Query.lock(query, :for_update), else: query
      query = if opts[:sort], do: Ash.Query.sort(query, opts[:sort]), else: query
      query = if opts[:limit], do: Ash.Query.limit(query, opts[:limit]), else: query

      if opts[:many], do: Ash.read(query), else: Ash.read_one(query)
    end)
  end

  @doc false
  def create(owner, resource, action, attrs) do
    with_capability(owner, resource, action, fn actor ->
      Ash.create(resource, attrs, action: action, actor: actor)
    end)
  end

  @doc false
  def update(owner, %resource{} = row, action, attrs) do
    with_capability(owner, resource, action, fn actor ->
      Ash.update(row, attrs, action: action, actor: actor)
    end)
  end

  # Exposed so tests can prove each module is limited to its own actions;
  # a capability still requires the caller's private local capture.
  @doc false
  def owns?(module, resource, action),
    do: action in (@owners |> Map.get(module, %{}) |> Map.get(resource, []))

  defp owned?(owner, resource, action) when is_function(owner, 0) do
    info = Function.info(owner)

    info[:type] == :local and info[:name] == :work_store_owner and
      owns?(info[:module], resource, action)
  end

  defp owned?(_, _, _), do: false

  defp with_capability(owner, resource, action, operation) do
    if Repo.in_transaction?() and owned?(owner, resource, action) do
      ref = make_ref()
      previous = Process.put(__MODULE__, {ref, resource, action, owner})

      try do
        operation.(%__MODULE__{ref: ref})
      after
        if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
      end
    else
      {:error, :denied}
    end
  end
end
