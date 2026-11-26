defmodule VoelgoedAi.Intelligence.AssistantKnowledgeGrant do
  @moduledoc """
  Collection membership of one assistant revision. Support configuration
  changes membership under the owning assistant lock while the revision is
  a draft. Publication freezes the set.
  """

  use Ash.Resource,
    domain: VoelgoedAi.Intelligence,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Support.ActionScope.Storage

  postgres do
    table("assistant_knowledge_grants")
    repo(VoelgoedAi.Repo)

    references do
      reference(:assistant_revision, on_delete: :restrict, on_update: :restrict)
      reference(:collection, on_delete: :restrict, on_update: :restrict)
    end
  end

  attributes do
    uuid_v7_primary_key(:id)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:assistant_revision, VoelgoedAi.Intelligence.AssistantRevision, allow_nil?: false)
    belongs_to(:collection, VoelgoedAi.Knowledge.KnowledgeCollection, allow_nil?: false)
  end

  identities do
    identity(:revision_collection, [:assistant_revision_id, :collection_id])
  end

  actions do
    read :for_revision do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(assistant_revision_id == ^arg(:id)))
      prepare(build(sort: [:collection_id], limit: 21))
    end

    create :create_grant do
      transaction?(false)
      accept([:assistant_revision_id, :collection_id])
    end

    destroy :remove_grant do
      transaction?(false)
      require_atomic?(false)
    end
  end

  policies do
    policy action([:for_revision, :create_grant, :remove_grant]) do
      authorize_if(Storage)
    end
  end
end
