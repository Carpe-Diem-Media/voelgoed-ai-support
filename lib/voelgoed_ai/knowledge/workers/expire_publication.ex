defmodule VoelgoedAi.Knowledge.Workers.ExpirePublication do
  @moduledoc "Expires the current revision when its approved validity ends."
  use Oban.Worker, queue: :knowledge_indexing, max_attempts: 3

  alias VoelgoedAi.Knowledge.Publication

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: Publication.perform_job(__MODULE__, args)
end
