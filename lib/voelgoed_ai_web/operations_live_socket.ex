defmodule VoelgoedAiWeb.OperationsLiveSocket do
  @moduledoc "Separately admits current operations roles to the staff WebSocket."
  use Phoenix.LiveView.Socket

  alias VoelgoedAi.Support.Operations
  alias VoelgoedAiWeb.StaffLiveSocket

  def connect(_params, socket, info),
    do: StaffLiveSocket.connect_for(socket, info, &Operations.access/1)
end
