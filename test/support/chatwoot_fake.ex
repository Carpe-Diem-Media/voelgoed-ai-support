defmodule VoelgoedAi.ChatwootFake do
  @moduledoc false

  @behaviour VoelgoedAi.Support.ChatwootAdapter
  alias VoelgoedAi.Repo
  alias VoelgoedAi.Support.ChatwootAdapter.{History, Message, Observation}

  def child_spec(state), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [state]}}

  def start_link(state), do: Agent.start_link(fn -> state end)

  @impl true
  def conversation(agent, destination, budget) do
    false = Repo.in_transaction?()

    {observation, barrier} =
      Agent.get_and_update(agent, &{{&1.observation, &1.read_barrier}, %{&1 | read_barrier: nil}})

    if barrier do
      send(barrier, {:chatwoot_read, self()})

      receive do
        :resume_chatwoot_read -> qualify(observation, destination)
      after
        budget -> {:error, :deadline}
      end
    else
      qualify(observation, destination)
    end
  end

  defp qualify(%Observation{destination: destination} = observation, destination),
    do: {:ok, observation}

  defp qualify(_, _), do: {:error, :scope_denied}

  @impl true
  def history(agent, destination, limit, _budget) do
    false = Repo.in_transaction?()

    Agent.get(agent, fn state ->
      with {:ok, _} <- qualify(state.observation, destination) do
        {:ok, %History{destination: destination, messages: Enum.take(state.history, -limit)}}
      end
    end)
  end

  @impl true
  def reply(agent, destination, text, operation, budget) do
    false = Repo.in_transaction?()

    {reply, barrier} =
      Agent.get_and_update(agent, fn state ->
        state = %{state | writes: [{:reply, destination, text, operation} | state.writes]}
        {response, updated} = simulate_reply(state, destination, operation)
        {{response, Map.get(state, :write_barrier)}, Map.delete(updated, :write_barrier)}
      end)

    if barrier do
      send(barrier, {:chatwoot_write, self()})

      receive do
        :resume_chatwoot_write -> reply
      after
        budget -> {:error, :uncertain}
      end
    else
      reply
    end
  end

  defp simulate_reply(%{write_mode: :unissued} = state, _, _),
    do: {{:error, {:not_issued, :unavailable}}, state}

  defp simulate_reply(%{write_mode: :timeout} = state, _, _),
    do: {{:error, :uncertain}, state}

  defp simulate_reply(state, destination, operation) do
    id = System.unique_integer([:positive])
    message = %Message{id: id, sender: :bot, operation: operation}

    outcome =
      if state.write_mode == :commit_then_timeout,
        do: {:error, :uncertain},
        else: {:ok, destination, id}

    {outcome, %{state | history: state.history ++ [message]}}
  end

  @impl true
  def open_for_handoff(agent, destination, operation, _budget) do
    false = Repo.in_transaction?()

    Agent.get_and_update(agent, fn state ->
      state = %{state | writes: [{:handoff, destination, operation} | state.writes]}
      observation = %{state.observation | status: :open, assignee: :unassigned}
      {:ok, %{state | observation: observation}}
    end)
  end
end
