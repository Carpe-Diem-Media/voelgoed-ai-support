defmodule VoelgoedAi.Support.ActionScope do
  @moduledoc """
  Exact application scopes for support configuration and jobs. Callers construct
  these from qualified records and trusted job context, never request fields.
  """

  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Accounts.StaffAccess.Session
  alias VoelgoedAi.Governance.{AuditEvent, AutomationControl}
  alias VoelgoedAi.Intelligence.{Assistant, AssistantRevision}
  alias VoelgoedAi.Support.{InboxBinding, JobAction}

  defmodule Ingress do
    @moduledoc "Scope for a trusted ingress operation."
    @enforce_keys [:action, :resource, :target, :inbox]
    defstruct @enforce_keys
  end

  defmodule Processing do
    @moduledoc "Scope for one support processing operation."
    @enforce_keys [:action, :resource, :target, :inbox]
    defstruct @enforce_keys
  end

  defmodule Delivery do
    @moduledoc "Scope for one delivery operation."
    @enforce_keys [:action, :resource, :target, :inbox]
    defstruct @enforce_keys
  end

  defmodule Reconciliation do
    @moduledoc "Scope for one reconciliation operation."
    @enforce_keys [:action, :resource, :target, :inbox]
    defstruct @enforce_keys
  end

  @impl true
  def describe(_opts), do: "the application actor is authorized for this exact operation"

  @impl true
  def match?(
        %Session{},
        %{subject: %Ash.ActionInput{resource: AuditEvent, action: %{name: :system_history}}},
        _opts
      ),
      do: true

  def match?(scope, %{subject: %Ash.ActionInput{} = input}, _opts), do: permits?(scope, input)
  def match?(_, _, _), do: false

  def permits?(%kind{action: action, resource: resource, target: target}, %Ash.ActionInput{
        action: %{name: action},
        resource: resource,
        arguments: arguments
      })
      when kind in [Ingress, Processing, Delivery, Reconciliation] do
    case {action, resource} do
      {:read_configuration, InboxBinding} ->
        target == arguments.id

      {:read_configuration, AutomationControl} ->
        target == :global

      {:read_configuration, resource} when resource in [Assistant, AssistantRevision] ->
        kind == Processing and target == arguments.id

      {:system_history, AuditEvent} ->
        kind == Reconciliation and target == {arguments.target_kind, arguments.id}

      {:operational_history, AuditEvent} ->
        kind in [Processing, Reconciliation] and target == {arguments.target_kind, arguments.id}

      _ ->
        JobAction.kind(resource, action) == kind and target == arguments[:id]
    end
  end

  def permits?(_, _), do: false

  defmodule Admin do
    @moduledoc false
    use Ash.Policy.SimpleCheck
    alias VoelgoedAi.Accounts.StaffAccess.Session

    @impl true
    def describe(_opts), do: "a staff session whose current admin grant is checked in the action"

    @impl true
    def match?(%Session{}, %{subject: %Ash.ActionInput{}}, _opts), do: true
    def match?(_, _, _), do: false
  end

  defmodule Storage do
    @moduledoc false
    use Ash.Policy.SimpleCheck

    alias VoelgoedAi.Repo
    alias VoelgoedAi.Support.Configuration

    @enforce_keys [:ref]
    defstruct @enforce_keys

    @impl true
    def describe(_opts),
      do: "the authorized configuration operation is using its storage capability"

    @impl true
    def match?(%__MODULE__{ref: ref}, %{subject: subject}, _opts) when is_reference(ref) do
      Process.get({Configuration, :storage}) == {ref, subject.resource, subject.action.name} and
        Repo.in_transaction?()
    end

    def match?(_, _, _), do: false
  end
end
