defmodule VoelgoedAi.Knowledge.Workers.IndexArticle do
  @moduledoc "Runs one locale claim. Replay follows durable attempt state."
  use Oban.Worker, queue: :knowledge_indexing, max_attempts: 3

  alias VoelgoedAi.Intelligence.Embedding

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"embedding_id" => id} = args}) when map_size(args) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Embedding.index(id)
      :error -> {:discard, :invalid_job}
    end
  end

  def perform(_), do: {:discard, :invalid_job}
end
