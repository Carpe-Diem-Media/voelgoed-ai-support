defmodule VoelgoedAi.Accounts.EntraPendingStates do
  @moduledoc """
  Tracks unspent OIDC states for the single application instance.

  A restart discards pending sign-ins. The encrypted browser cookie still holds
  the nonce and PKCE verifier, and cannot restore a spent state.
  """

  use GenServer

  @ttl_ms 600_000
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def remember(state), do: GenServer.call(__MODULE__, {:remember, digest(state)})
  def consume(state), do: GenServer.call(__MODULE__, {:consume, digest(state)})

  @impl true
  def init(states) do
    schedule_sweep()
    {:ok, states}
  end

  @impl true
  def handle_call({:remember, key}, _from, states) do
    {:reply, :ok, Map.put_new(states, key, now() + @ttl_ms)}
  end

  def handle_call({:consume, key}, _from, states) do
    {expiry, remaining} = Map.pop(states, key)
    {:reply, is_integer(expiry) and expiry > now(), remaining}
  end

  @impl true
  def handle_info(:sweep, states) do
    now = now()
    schedule_sweep()
    {:noreply, Map.reject(states, fn {_key, expiry} -> expiry <= now end)}
  end

  defp digest(state), do: :crypto.hash(:sha256, state)
  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
