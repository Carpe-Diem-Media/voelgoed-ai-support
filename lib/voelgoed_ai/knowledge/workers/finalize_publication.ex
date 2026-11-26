defmodule VoelgoedAi.Knowledge.Workers.FinalizePublication do
  @moduledoc "Finalises a ready generation or applies a durable index rollback request."
  use Oban.Worker, queue: :knowledge_indexing, max_attempts: 3

  alias VoelgoedAi.Knowledge.Publication

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: Publication.perform_job(__MODULE__, args)
end
