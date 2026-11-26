defmodule VoelgoedAi.Knowledge.Storage do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Knowledge.Editorial
  alias VoelgoedAi.Repo

  @enforce_keys [:ref]
  defstruct @enforce_keys

  @impl true
  def describe(_opts), do: "the owning editorial transaction authorized this storage action"

  @impl true
  def match?(%__MODULE__{ref: ref}, %{subject: subject}, _opts) when is_reference(ref) do
    Repo.in_transaction?() and
      Process.get({Editorial, :storage}) == {ref, subject.resource, subject.action.name}
  end

  def match?(_, _, _), do: false
end
