defmodule VoelgoedAi.Knowledge.Storage do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  alias VoelgoedAi.Knowledge.{Editorial, Publication}
  alias VoelgoedAi.Intelligence.{Embedding, Generation}
  alias VoelgoedAi.Governance.{EmbeddingAccounting, FinancialControl}
  alias VoelgoedAi.Repo

  @enforce_keys [:ref]
  defstruct [:ref, owner: Editorial]

  @impl true
  def describe(_opts), do: "the owning transaction authorized this storage action"

  @impl true
  def match?(%__MODULE__{ref: ref, owner: owner}, %{subject: subject}, _opts)
      when is_reference(ref) and
             owner in [
               Editorial,
               Publication,
               Embedding,
               Generation,
               EmbeddingAccounting,
               FinancialControl
             ] do
    Repo.in_transaction?() and
      Process.get({owner, :storage}) == {ref, subject.resource, subject.action.name}
  end

  def match?(_, _, _), do: false
end
