defmodule VoelgoedAi.Support.Workers.ProcessEvent do
  @moduledoc false
  use Oban.Worker, queue: :support, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}}) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      VoelgoedAi.Support.RunProcessing.process_event(id)
    else
      :error -> {:discard, :invalid_job}
    end
  end

  def perform(_), do: {:discard, :invalid_job}
end
