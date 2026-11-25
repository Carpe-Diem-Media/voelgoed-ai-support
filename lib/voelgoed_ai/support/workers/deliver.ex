defmodule VoelgoedAi.Support.Workers.Deliver do
  @moduledoc false
  use Oban.Worker, queue: :support, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}}) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      VoelgoedAi.Support.Delivery.deliver(id)
    else
      :error -> {:discard, :invalid_job}
    end
  end

  def perform(_), do: {:discard, :invalid_job}
end
