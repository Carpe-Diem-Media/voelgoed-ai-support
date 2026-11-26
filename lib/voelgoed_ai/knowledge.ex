defmodule VoelgoedAi.Knowledge do
  @moduledoc "Editorial authority for source-verified support articles."
  use Ash.Domain

  authorization do
    authorize(:always)
  end

  resources do
    resource(VoelgoedAi.Knowledge.ArticleEmbedding)
    resource(VoelgoedAi.Knowledge.KnowledgeCollection)
    resource(VoelgoedAi.Knowledge.Article)
    resource(VoelgoedAi.Knowledge.ArticleRevision)
  end
end
