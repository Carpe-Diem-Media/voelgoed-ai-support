defmodule VoelgoedAi.Support.ChatwootAdapter do
  @moduledoc """
  Qualified Chatwoot operations in the local support workflow. All callbacks
  receive the remaining request budget in milliseconds. Only the delivery
  worker invokes write callbacks.
  """

  defmodule Destination do
    @moduledoc "Server-derived qualification for one Chatwoot conversation."
    @enforce_keys [:installation, :account, :inbox, :conversation]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            installation: String.t(),
            account: pos_integer(),
            inbox: pos_integer(),
            conversation: pos_integer()
          }
  end

  defmodule Observation do
    @moduledoc "Bounded conversation status, assignment and reply qualification."
    @enforce_keys [:destination, :status, :assignee, :contact, :can_reply]
    defstruct @enforce_keys ++ [:team]

    @type t :: %__MODULE__{
            destination: Destination.t(),
            status: :pending | :open | :resolved,
            assignee: :bot | :human | :unassigned,
            contact: pos_integer(),
            can_reply: boolean(),
            team: pos_integer() | nil
          }
  end

  defmodule Message do
    @moduledoc "One public message fact in verified history order."
    @enforce_keys [:id, :sender, :visibility]
    defstruct @enforce_keys ++ [:operation]

    @type t :: %__MODULE__{
            id: pos_integer(),
            sender: :contact | :bot | :human,
            visibility: :public | :private,
            operation: String.t() | nil
          }
  end

  defmodule History do
    @moduledoc "A bounded public-message projection qualified to one conversation."
    @enforce_keys [:destination, :messages]
    defstruct @enforce_keys
    @type t :: %__MODULE__{destination: Destination.t(), messages: [Message.t()]}
  end

  @doc false
  def in_scope?(row) do
    keys = [:installation_ref, :external_account_id, :external_inbox_id]

    case fixture() do
      %{} = configured -> Map.take(configured, keys) == Map.take(row, keys)
      _ -> false
    end
  end

  @type read_failure :: :scope_denied | :unavailable | :deadline | :rate_limited
  @type write_failure :: {:not_issued, :scope_denied | :unavailable | :deadline} | :uncertain

  @callback conversation(term(), Destination.t(), pos_integer()) ::
              {:ok, Observation.t()} | {:error, read_failure()}
  @callback history(term(), Destination.t(), pos_integer(), pos_integer()) ::
              {:ok, History.t()} | {:error, read_failure()}
  @callback reply(term(), Destination.t(), String.t(), String.t(), pos_integer()) ::
              {:ok, Destination.t(), pos_integer()} | {:error, write_failure()}
  @callback open_for_handoff(term(), Destination.t(), String.t(), pos_integer()) ::
              :ok | {:error, write_failure()}

  @doc false
  def now do
    case fixture() do
      %{clock: clock} -> clock.()
      _ -> DateTime.utc_now()
    end
  end

  @doc false
  def destination(row) do
    %Destination{
      installation: row.installation_ref,
      account: row.external_account_id,
      inbox: row.external_inbox_id,
      conversation: row.conversation_id
    }
  end

  @doc false
  def call(operation, destination, args, deadline) do
    budget = min(500, DateTime.diff(deadline, now(), :millisecond))

    with true <- budget > 0 and not VoelgoedAi.Repo.in_transaction?(),
         %{adapter: {module, context}} <- fixture() do
      apply(module, operation, [context, destination] ++ args ++ [budget])
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc false
  def observe(session, deadline) do
    destination = destination(session)

    case call(:conversation, destination, [], deadline) do
      {:ok, %Observation{destination: ^destination, contact: contact} = observation}
      when contact == session.contact_id ->
        {:ok, observation}

      {:error, _} = error ->
        error

      _ ->
        {:error, :scope_denied}
    end
  end

  @doc false
  def history(session, deadline) do
    limit = fixture()[:history_limit]

    if is_integer(limit) and limit > 0 do
      destination = destination(session)

      case call(:history, destination, [limit], deadline) do
        {:ok, %History{destination: ^destination, messages: messages}}
        when is_list(messages) and length(messages) <= limit ->
          if Enum.all?(messages, &public_message?/1),
            do: {:ok, messages},
            else: {:error, :scope_denied}

        {:error, _} = error ->
          error

        _ ->
          {:error, :scope_denied}
      end
    else
      {:error, :unavailable}
    end
  end

  defp public_message?(%Message{visibility: :public, id: id, sender: sender}),
    do:
      is_integer(id) and id in 1..9_223_372_036_854_775_807 and sender in [:contact, :bot, :human]

  defp public_message?(_), do: false

  @doc false
  if Mix.env() == :test do
    def fixture do
      if Application.get_env(:voelgoed_ai, :chatwoot_adapter, :disabled) == :fixture do
        Application.get_env(:voelgoed_ai, :support_fixture)
      end
    end
  else
    def fixture, do: nil
  end
end
