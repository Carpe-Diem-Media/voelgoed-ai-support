if Mix.env() == :test do
  defmodule VoelgoedAiWeb.GapLiveSocket do
    @moduledoc "Checks scoped gap access on the staff origin without granting editorial access."
    use Phoenix.LiveView.Socket

    alias VoelgoedAi.Knowledge.GapReview
    alias VoelgoedAiWeb.StaffLiveSocket

    def connect(_params, socket, info),
      do: StaffLiveSocket.connect_for(socket, info, &GapReview.access/1)
  end
end
