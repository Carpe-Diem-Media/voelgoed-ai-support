defmodule VoelgoedAi.Support.Workers.Retention do
  @moduledoc "Executes a bounded page under the current synthetic retention capability."
  use Oban.Worker, queue: :support_retention, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"capability" => token} = args, conf: conf}) do
    with {:ok, ^token} <- Ecto.UUID.cast(token),
         {:ok, cursor} <- cursor(args) do
      VoelgoedAi.Support.Retention.sweep(token, cursor, conf)
    else
      _ -> {:discard, :invalid_job}
    end
  end

  def perform(_), do: {:discard, :invalid_job}

  defp cursor(%{"after_run" => id} = args) when map_size(args) == 2, do: Ecto.UUID.cast(id)
  defp cursor(args) when map_size(args) == 1, do: {:ok, nil}
  defp cursor(_), do: :error
end
