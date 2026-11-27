defmodule VoelgoedAiWeb.StaffLiveSocket do
  @moduledoc "Admits staff WebSockets only with a current CSRF-checked cookie on the staff origin."
  use Phoenix.LiveView.Socket

  alias VoelgoedAiWeb.StaffSession

  def connect(_params, socket, info),
    do: connect_for(socket, info, &StaffSession.knowledge_access/1)

  @doc false
  def connect_for(socket, %{uri: uri, session: cookie}, access) do
    with true <- StaffSession.knowledge_origin?(uri),
         {:ok, :authorized} <- access.(StaffSession.decode(cookie)) do
      # Channel.Server merges these over the channel defaults. Upload joins
      # carry a signed token and can carry arbitrary client parameters.
      {:ok,
       %{socket | private: Map.merge(socket.private, %{log_join: false, log_handle_in: false})}}
    else
      _ -> :error
    end
  end

  def connect_for(_socket, _info, _access), do: :error
end
