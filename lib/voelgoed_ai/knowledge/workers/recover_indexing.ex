defmodule VoelgoedAi.Knowledge.Workers.RecoverIndexing do
  @moduledoc "Fences expired index work and retains holds for dispatched attempts."
  use Oban.Worker, queue: :knowledge_indexing, max_attempts: 3

  alias VoelgoedAi.Intelligence.Embedding

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"embedding_id" => id} = args}) when map_size(args) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Embedding.recover(id)
      :error -> {:discard, :invalid_job}
    end
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0, do: Embedding.sweep()
  def perform(_), do: {:discard, :invalid_job}
end
