defmodule VoelgoedAi.Accounts.EntraPendingStates do
  @moduledoc """
  Tracks unspent OIDC states for the single application instance.

  A restart discards pending sign-ins. The encrypted browser cookie still holds
  the nonce and PKCE verifier, and cannot restore a spent state.

  Unauthenticated requests create entries, so the map is capped. At the cap a
  new sign-in fails closed until consumption or the sweep frees space.
  """

  use GenServer

  @ttl_ms 600_000
  @sweep_ms 60_000
  @max_pending 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def remember(state), do: GenServer.call(__MODULE__, {:remember, digest(state)})
  def consume(state), do: GenServer.call(__MODULE__, {:consume, digest(state)})

  @impl true
  def init(states) do
    schedule_sweep()
    {:ok, states}
  end

  @impl true
  def handle_call({:remember, _key}, _from, states) when map_size(states) >= @max_pending do
    {:reply, {:error, :pending_limit}, states}
  end

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

  @doc false
  def max_pending, do: @max_pending

  defp digest(state), do: :crypto.hash(:sha256, state)
  defp now, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
