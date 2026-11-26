defmodule VoelgoedAiWeb.StaffLiveSocket do
  @moduledoc "Admits staff WebSockets only with a current CSRF-checked cookie on the staff origin."
  use Phoenix.LiveView.Socket

  alias VoelgoedAiWeb.StaffSession

  def connect(_params, socket, %{uri: uri, session: cookie}) do
    with true <- StaffSession.knowledge_origin?(uri),
         {:ok, :authorized} <- cookie |> StaffSession.decode() |> StaffSession.knowledge_access() do
      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _info), do: :error
end
