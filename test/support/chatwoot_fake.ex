defmodule VoelgoedAi.ChatwootFake do
  @moduledoc false

  @behaviour VoelgoedAi.Support.ChatwootAdapter
  alias VoelgoedAi.Repo

  alias VoelgoedAi.Support.ChatwootAdapter.{
    History,
    Message,
    Observation,
    TextHistory,
    TextMessage
  }

  def child_spec(state), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [state]}}

  def start_link(state), do: Agent.start_link(fn -> state end)

  @impl true
  def conversation(agent, destination, budget) do
    false = Repo.in_transaction?()

    {observation, barrier} =
      Agent.get_and_update(agent, fn state ->
        {barrier, state} = Map.pop(state, :read_barrier)
        result = Map.get(state, :conversation_result, state.observation)
        {{result, barrier}, Map.update(state, :conversation_reads, 1, &(&1 + 1))}
      end)

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

  defp qualify({:error, _} = error, _), do: error

  defp qualify(_, _), do: {:error, :scope_denied}

  @impl true
  def history(agent, destination, limit, _budget) do
    false = Repo.in_transaction?()

    {response, barrier} =
      Agent.get_and_update(agent, fn state ->
        {barrier, state} = Map.pop(state, :history_barrier)

        response =
          with {:ok, _} <- qualify(state.observation, destination) do
            {:ok,
             %History{
               destination: Map.get(state, :history_destination, destination),
               messages: Enum.take(state.history, -limit)
             }}
          end

        {{response, barrier}, state}
      end)

    if barrier do
      send(barrier, {:chatwoot_history, self()})

      receive do
        :resume_chatwoot_history -> response
      after
        500 -> {:error, :deadline}
      end
    else
      response
    end
  end

  @impl true
  def decision_history(agent, destination, limit, budget) do
    false = Repo.in_transaction?()

    {response, barrier} =
      Agent.get_and_update(agent, fn state ->
        {barrier, state} = Map.pop(state, :decision_history_barrier)

        response =
          with {:ok, observation} <- qualify(state.observation, destination) do
            messages =
              state.history
              |> Enum.take(-limit)
              |> Enum.map(&text_message(&1, observation.contact, state))

            {:ok,
             %TextHistory{
               destination: Map.get(state, :text_destination, destination),
               contact: Map.get(state, :text_contact, observation.contact),
               messages: messages
             }}
          end

        {{response, barrier}, Map.update(state, :decision_reads, 1, &(&1 + 1))}
      end)

    if barrier do
      send(barrier, {:decision_history, self()})

      receive do
        :resume_decision_history -> response
      after
        budget -> {:error, :deadline}
      end
    else
      response
    end
  end

  defp text_message(message, contact, state) do
    base = %TextMessage{
      id: message.id,
      sender: message.sender,
      contact_id: if(message.sender == :contact, do: contact),
      visibility: message.visibility,
      edited?: false,
      attachments?: false,
      text: "Synthetic input"
    }

    struct!(base, get_in(state, [:decision_messages, message.id]) || %{})
  end

  @impl true
  def reply(agent, destination, text, operation, budget) do
    false = Repo.in_transaction?()

    before_commit =
      Agent.get_and_update(agent, fn state ->
        state = %{state | writes: [{:reply, destination, text, operation} | state.writes]}
        Map.pop(state, :before_commit_barrier)
      end)

    with :ok <- wait_at(before_commit, :chatwoot_before_commit, budget) do
      {reply, barrier} =
        Agent.get_and_update(agent, fn state ->
          {response, updated} = simulate_reply(state, destination, operation)
          {{response, Map.get(state, :write_barrier)}, Map.delete(updated, :write_barrier)}
        end)

      with :ok <- wait_at(barrier, :chatwoot_write, budget), do: reply
    end
  end

  defp wait_at(nil, _, _), do: :ok

  defp wait_at(barrier, signal, budget) do
    send(barrier, {signal, self()})

    receive do
      :resume_chatwoot_write -> :ok
    after
      budget -> {:error, :uncertain}
    end
  end

  defp simulate_reply(%{write_mode: :unissued} = state, _, _),
    do: {{:error, {:not_issued, :unavailable}}, state}

  defp simulate_reply(%{write_mode: :timeout} = state, _, _),
    do: {{:error, :uncertain}, state}

  defp simulate_reply(%{write_mode: mode} = state, destination, _)
       when mode in [:reset, :server_error, :redirect, :forbidden, :malformed_success] do
    response =
      if mode == :malformed_success, do: {:ok, destination, nil}, else: {:error, mode}

    {response, state}
  end

  defp simulate_reply(state, destination, operation) do
    id = System.unique_integer([:positive])
    message = %Message{id: id, sender: :bot, visibility: :public, operation: operation}

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
      {:ok, %{state | observation: Map.get(state, :handoff_observation, observation)}}
    end)
  end
end
