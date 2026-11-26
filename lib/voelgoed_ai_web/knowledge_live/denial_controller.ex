defmodule VoelgoedAiWeb.KnowledgeLive.DenialController do
  @moduledoc false
  use Phoenix.Controller, formats: []

  def show(conn, params), do: VoelgoedAiWeb.StaffSession.deny_knowledge(conn, params)
end
