defmodule VoelgoedAi.CITimingFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_options), do: {:ok, {%{}, %{}, []}}

  @impl true
  def handle_cast({:module_started, module}, {started, timings, results}) do
    key = {module.name, module.parameters}
    {:noreply, {Map.put(started, key, System.monotonic_time(:microsecond)), timings, results}}
  end

  def handle_cast({:module_finished, module}, {started, timings, results}) do
    {start, started} = Map.pop!(started, {module.name, module.parameters})
    elapsed = max(1, System.monotonic_time(:microsecond) - start) / 1_000_000
    timings = Map.update(timings, Path.relative_to_cwd(module.file), elapsed, &(&1 + elapsed))
    {:noreply, {started, timings, results}}
  end

  def handle_cast({:test_finished, test}, {started, timings, results}) do
    result = %{
      file: Path.relative_to_cwd(test.tags.file),
      module: inspect(test.module),
      case: Atom.to_string(test.name),
      state: if(is_nil(test.state), do: :passed, else: elem(test.state, 0))
    }

    {:noreply, {started, timings, [result | results]}}
  end

  def handle_cast({:suite_finished, _suite}, {_started, timings, results} = state) do
    if path = System.get_env("CI_TIMING_OUTPUT") do
      history =
        Map.new(timings, fn {file, seconds} ->
          digest = :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
          {file, %{digest: digest, seconds: seconds}}
        end)

      File.write!(path, JSON.encode!(history))
    end

    if path = System.get_env("CI_TEST_RESULTS_OUTPUT") do
      File.write!(path, JSON.encode!(Enum.reverse(results)))
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
