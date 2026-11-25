defmodule VoelgoedAi.CITimingFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_options), do: {:ok, {%{}, %{}}}

  @impl true
  def handle_cast({:module_started, module}, {started, timings}) do
    key = {module.name, module.parameters}
    {:noreply, {Map.put(started, key, System.monotonic_time(:microsecond)), timings}}
  end

  def handle_cast({:module_finished, module}, {started, timings}) do
    {start, started} = Map.pop!(started, {module.name, module.parameters})
    elapsed = max(1, System.monotonic_time(:microsecond) - start) / 1_000_000
    timings = Map.update(timings, Path.relative_to_cwd(module.file), elapsed, &(&1 + elapsed))
    {:noreply, {started, timings}}
  end

  def handle_cast({:suite_finished, _suite}, {started, timings}) do
    history =
      Map.new(timings, fn {file, seconds} ->
        digest = :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
        {file, %{digest: digest, seconds: seconds}}
      end)

    File.write!(System.fetch_env!("CI_TIMING_OUTPUT"), JSON.encode!(history))
    {:noreply, {started, timings}}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
