defmodule VoelgoedAi.Support do
  @moduledoc "Authorized support inbox configuration."
  use Ash.Domain

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Support.InboxBinding)
    resource(VoelgoedAi.Support.SupportSession)
    resource(VoelgoedAi.Support.InboundEvent)
    resource(VoelgoedAi.Support.SupportRun)
    resource(VoelgoedAi.Support.OutboundDelivery)
    resource(VoelgoedAi.Support.RunInput)
  end
end
