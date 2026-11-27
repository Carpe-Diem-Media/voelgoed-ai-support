defmodule VoelgoedAi.Intelligence do
  @moduledoc "Authorized assistant configuration."
  use Ash.Domain

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Intelligence.SupportProposal)
    resource(VoelgoedAi.Intelligence.InferenceRun)
    resource(VoelgoedAi.Intelligence.Assistant)
    resource(VoelgoedAi.Intelligence.AssistantRevision)
    resource(VoelgoedAi.Intelligence.AssistantKnowledgeGrant)
  end
end
