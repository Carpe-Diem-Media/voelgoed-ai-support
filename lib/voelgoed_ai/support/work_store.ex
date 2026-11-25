defmodule VoelgoedAi.Support.WorkStore do
  @moduledoc false

  use Ash.Policy.SimpleCheck
  alias VoelgoedAi.Repo

  @enforce_keys [:ref]
  defstruct @enforce_keys

  @impl true
  def describe(_opts), do: "an authorized support transaction owns this storage operation"

  @impl true
  def match?(%__MODULE__{ref: ref}, %{subject: subject}, _opts) when is_reference(ref) do
    Repo.in_transaction?() &&
      Process.get(__MODULE__) == {ref, subject.resource, subject.action.name}
  end

  def match?(_, _, _), do: false

  def read(resource, action, args, filter, opts \\ []) do
    with_capability(resource, action, fn actor ->
      query =
        resource
        |> Ash.Query.for_read(action, args, actor: actor)
        |> Ash.Query.filter_input(filter)

      query = if opts[:lock], do: Ash.Query.lock(query, :for_update), else: query
      query = if opts[:limit], do: Ash.Query.limit(query, opts[:limit]), else: query

      if opts[:many], do: Ash.read(query), else: Ash.read_one(query)
    end)
  end

  def create(resource, action, attrs) do
    with_capability(resource, action, fn actor ->
      Ash.create(resource, attrs, action: action, actor: actor)
    end)
  end

  def update(%resource{} = row, action, attrs) do
    with_capability(resource, action, fn actor ->
      Ash.update(row, attrs, action: action, actor: actor)
    end)
  end

  defp with_capability(resource, action, operation) do
    ref = make_ref()
    previous = Process.put(__MODULE__, {ref, resource, action})

    try do
      operation.(%__MODULE__{ref: ref})
    after
      if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
    end
  end
end
