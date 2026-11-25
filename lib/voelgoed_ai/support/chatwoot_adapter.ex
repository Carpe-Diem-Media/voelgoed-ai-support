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
    @enforce_keys [:id, :sender]
    defstruct @enforce_keys ++ [:operation]

    @type t :: %__MODULE__{
            id: pos_integer(),
            sender: :contact | :bot | :human,
            operation: String.t() | nil
          }
  end

  @type read_failure :: :scope_denied | :unavailable | :deadline | :rate_limited
  @type write_failure :: {:not_issued, :scope_denied | :unavailable | :deadline} | :uncertain

  @callback conversation(term(), Destination.t(), pos_integer()) ::
              {:ok, Observation.t()} | {:error, read_failure()}
  @callback history(term(), Destination.t(), pos_integer(), pos_integer()) ::
              {:ok, [Message.t()]} | {:error, read_failure()}
  @callback reply(term(), Destination.t(), String.t(), String.t(), pos_integer()) ::
              {:ok, Destination.t(), pos_integer()} | {:error, write_failure()}
  @callback open_for_handoff(term(), Destination.t(), String.t(), pos_integer()) ::
              :ok | {:error, write_failure()}

  @doc false
  if Mix.env() == :test do
    def fixture, do: Application.get_env(:voelgoed_ai, :support_fixture)
  else
    def fixture, do: nil
  end
end
