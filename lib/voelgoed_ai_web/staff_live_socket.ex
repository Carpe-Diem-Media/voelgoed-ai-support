defmodule VoelgoedAiWeb.StaffLiveSocket do
  @moduledoc "Admits staff WebSockets only with a current CSRF-checked cookie on the staff origin."
  use Phoenix.LiveView.Socket

  alias VoelgoedAiWeb.StaffSession

  def connect(_params, socket, %{uri: uri, session: cookie}) do
    with true <- StaffSession.knowledge_origin?(uri),
         {:ok, :authorized} <- cookie |> StaffSession.decode() |> StaffSession.knowledge_access() do
      # Channel.Server merges these over the channel defaults. Upload joins
      # carry a signed token and can carry arbitrary client parameters.
      {:ok,
       %{socket | private: Map.merge(socket.private, %{log_join: false, log_handle_in: false})}}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _info), do: :error
end
