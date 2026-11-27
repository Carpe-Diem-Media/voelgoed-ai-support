defmodule VoelgoedAi.Support.DecisionContext do
  @moduledoc """
  Bounded text for one qualified turn. The projection and its commitment stay
  in memory. Only RunInput and receipt references identify messages in storage.
  """

  alias VoelgoedAi.Support.ChatwootAdapter.TextMessage

  @max_prior 6
  @prior_chars 4_000
  @message_chars 3_000
  @current_chars 6_000
  @max_serialized_bytes 16_384
  @max_current 5
  @max_history 15

  @enforce_keys [:prior, :current, :commitment]
  defstruct @enforce_keys

  @type message :: %{role: :contact | :bot | :human, text: String.t()}
  @type t :: %__MODULE__{prior: [message()], current: [message()], commitment: binary()}

  @doc "Project a verified ordered history with the current turn as its suffix."
  @spec project(term(), [pos_integer()], pos_integer()) ::
          {:ok, t()} | {:error, :history_changed | :scope_denied}
  def project(messages, current_ids, contact)
      when is_list(messages) and length(messages) <= @max_history and is_list(current_ids) and
             length(current_ids) in 1..@max_current and is_integer(contact) and contact > 0 do
    with :ok <- check_contact_scope(messages, contact),
         true <- Enum.all?(messages, &qualified?(&1, contact)),
         true <- unique_ids?(messages),
         {earlier, current} <- Enum.split(messages, -length(current_ids)),
         true <- Enum.sort(Enum.map(current, & &1.id)) == Enum.sort(current_ids),
         true <- Enum.all?(current, &(&1.sender == :contact and size(&1) <= @message_chars)),
         true <- Enum.sum(Enum.map(current, &size/1)) <= @current_chars,
         prior <- recent(earlier),
         {:ok, bytes} <- Jason.encode(%{prior: public(prior), current: public(current)}),
         true <- byte_size(bytes) <= @max_serialized_bytes do
      identity = Enum.map(prior ++ current, &{&1.id, &1.sender})
      commitment = :crypto.hash(:sha256, [bytes, :erlang.term_to_binary(identity)])

      {:ok, %__MODULE__{prior: public(prior), current: public(current), commitment: commitment}}
    else
      {:error, :scope_denied} = denial -> denial
      _ -> {:error, :history_changed}
    end
  end

  def project(_, _, _), do: {:error, :history_changed}

  # Keep a definite contact denial distinct from an edit, missing input or
  # other history drift. An observation outage cannot qualify local triage.
  defp check_contact_scope(messages, contact) do
    if Enum.any?(messages, fn
         %TextMessage{sender: :contact, contact_id: id} -> id != contact
         _ -> false
       end),
       do: {:error, :scope_denied},
       else: :ok
  end

  defp qualified?(
         %TextMessage{visibility: :public, edited?: false, attachments?: false} = row,
         contact
       ) do
    is_integer(row.id) and row.id in 1..9_223_372_036_854_775_807 and
      valid_sender?(row, contact) and is_binary(row.text) and
      byte_size(row.text) <= @prior_chars * 4 and
      String.valid?(row.text) and String.trim(row.text) != ""
  end

  defp qualified?(_, _), do: false

  defp valid_sender?(%{sender: :contact, contact_id: contact}, contact), do: true

  defp valid_sender?(%{sender: sender, contact_id: nil}, _) when sender in [:human, :bot],
    do: true

  defp valid_sender?(_, _), do: false

  defp unique_ids?(messages) do
    ids = Enum.map(messages, & &1.id)
    Enum.uniq(ids) == ids
  end

  defp recent(earlier) do
    earlier
    |> Enum.take(-@max_prior)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn message, {chosen, chars} ->
      total = chars + size(message)

      if total <= @prior_chars,
        do: {:cont, {[message | chosen], total}},
        else: {:halt, {chosen, chars}}
    end)
    |> elem(0)
  end

  defp size(message), do: String.length(message.text)
  defp public(messages), do: Enum.map(messages, &%{role: &1.sender, text: &1.text})
end
