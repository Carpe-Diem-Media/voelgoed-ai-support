defmodule VoelgoedAi.Support.Workers.Sweep do
  @moduledoc """
  Runs individual deadline checks and bounded recovery scans. Schedule
  the empty-argument job with Oban.Cron when job execution is authorized.
  """
  use Oban.Worker, queue: :support, max_attempts: 1

  alias VoelgoedAi.Support.Recovery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}}),
    do: valid_id(id, &Recovery.delivery_deadline/1)

  def perform(%Oban.Job{args: %{"run_id" => id}}),
    do: valid_id(id, &Recovery.run_deadline/1)

  def perform(%Oban.Job{args: %{"idle_after" => id}}),
    do: valid_id(id, &Recovery.sweep_idle/1)

  def perform(%Oban.Job{args: args}) when map_size(args) == 0, do: Recovery.sweep()
  def perform(_), do: {:discard, :invalid_job}

  defp valid_id(id, callback) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> callback.(id)
      :error -> {:discard, :invalid_job}
    end
  end
end
