defmodule VoelgoedAi.Support do
  @moduledoc "Authorized support inbox configuration."
  use Ash.Domain

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Support.InboxBinding)
  end
end
