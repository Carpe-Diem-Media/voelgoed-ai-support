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
    resource(VoelgoedAi.Knowledge.KnowledgeGap)

    resource VoelgoedAi.Knowledge.ArticleRevision do
      define(:search_published, args: [:query])
      define(:validate_evidence, args: [:citations, :used_links])
    end
  end
end
