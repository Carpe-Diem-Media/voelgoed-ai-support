defmodule VoelgoedAi.Knowledge.Workers.RecoverIndexing do
  @moduledoc "Fences expired index work and retains holds for dispatched attempts."
  use Oban.Worker, queue: :knowledge_indexing, max_attempts: 3

  alias VoelgoedAi.Intelligence.Embedding
  alias VoelgoedAi.Knowledge.Publication

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"embedding_id" => id} = args}) when map_size(args) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Embedding.recover(id)
      :error -> {:discard, :invalid_job}
    end
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    accounting = Embedding.sweep()
    publication = Publication.sweep()
    if accounting == :ok, do: publication, else: accounting
  end

  def perform(_), do: {:discard, :invalid_job}
end
