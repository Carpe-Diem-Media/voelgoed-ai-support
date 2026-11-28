defmodule VoelgoedAi.Governance.EmergencyOverride do
  @moduledoc """
  Gates external dispatch and records an emergency latch before workers start.
  An audited disable clears the latch and advances the automation epoch.
  """

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.Repo

  def asserted?, do: Application.get_env(:voelgoed_ai, :emergency_override, false) != false

  def blocked?(control), do: asserted?() or control.emergency_latched

  def child_spec(_) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  @doc false
  def start_link do
    if asserted?() do
      case SQL.query(
             Repo,
             "UPDATE automation_controls SET emergency_latched = TRUE WHERE singleton",
             [],
             timeout: 2_000,
             log: false
           ) do
        {:ok, %{num_rows: 1}} -> :ignore
        _ -> {:error, :emergency_latch_unavailable}
      end
    else
      :ignore
    end
  end
end
