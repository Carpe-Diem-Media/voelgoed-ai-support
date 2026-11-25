defmodule VoelgoedAi.Feasibility.Reservations do
  @moduledoc """
  Serializes admission and settlement for deterministic VGAS-000 tests.

  This ledger is scoped to one test process tree. A production ledger must
  persist attempts and serialize admissions across PostgreSQL connections.
  """
  use GenServer

  def start_link(limits), do: GenServer.start_link(__MODULE__, limits)

  def reserve(server, id, day, ceiling) when is_integer(ceiling) and ceiling > 0,
    do: GenServer.call(server, {:reserve, id, day, ceiling})

  def finish(server, id, outcome), do: GenServer.call(server, {:finish, id, outcome})
  def fetch(server, id), do: GenServer.call(server, {:fetch, id})

  @impl true
  def init(limits), do: {:ok, {Map.new(limits), %{}}}

  @impl true
  def handle_call({:reserve, id, day, ceiling}, _from, {limits, attempts} = state) do
    {daily, monthly, active} = risk(Map.values(attempts), day)

    cond do
      Map.has_key?(attempts, id) ->
        {:reply, {:error, :duplicate}, state}

      daily + ceiling > limits.daily or monthly + ceiling > limits.monthly ->
        {:reply, {:error, :budget}, state}

      active >= limits.concurrent ->
        {:reply, {:error, :concurrency}, state}

      true ->
        attempt = %{day: day, ceiling: ceiling, status: :reserved}
        {:reply, :ok, {limits, Map.put(attempts, id, attempt)}}
    end
  end

  def handle_call({:fetch, id}, _from, {_limits, attempts} = state),
    do: {:reply, Map.get(attempts, id), state}

  def handle_call({:finish, id, outcome}, _from, {limits, attempts} = state) do
    case transition(Map.get(attempts, id), outcome) do
      {:ok, attempt} -> {:reply, :ok, {limits, Map.put(attempts, id, attempt)}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp transition(%{status: :reserved} = attempt, :unknown),
    do: {:ok, %{attempt | status: :unknown}}

  defp transition(%{status: status} = attempt, :release) when status in [:reserved, :unknown],
    do: {:ok, %{attempt | status: :released}}

  defp transition(%{status: status} = attempt, {:settle, cost, request_id})
       when status in [:reserved, :unknown] and is_integer(cost) and cost >= 0 and
              is_binary(request_id) and byte_size(request_id) > 0 do
    {:ok, Map.merge(attempt, %{status: :settled, actual: cost, request_id: request_id})}
  end

  defp transition(nil, _outcome), do: {:error, :missing}

  defp transition(%{status: status}, _outcome) when status in [:settled, :released],
    do: {:error, :terminal}

  defp transition(_attempt, _outcome), do: {:error, :invalid_transition}

  defp risk(attempts, day) do
    Enum.reduce(attempts, {0, 0, 0}, fn
      %{status: status, ceiling: cost}, {daily, monthly, active}
      when status in [:reserved, :unknown] ->
        active = if status == :reserved, do: active + 1, else: active
        {daily + cost, monthly + cost, active}

      %{status: :settled, day: charged_day, actual: cost}, {daily, monthly, active} ->
        daily = if charged_day == day, do: daily + cost, else: daily

        monthly =
          if {charged_day.year, charged_day.month} == {day.year, day.month},
            do: monthly + cost,
            else: monthly

        {daily, monthly, active}

      %{status: :released}, totals ->
        totals
    end)
  end
end
