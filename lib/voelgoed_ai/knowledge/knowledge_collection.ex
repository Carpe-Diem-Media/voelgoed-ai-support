defmodule VoelgoedAi.Knowledge.KnowledgeCollection do
  @moduledoc "An immutable audience and a revocable collection scope."

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.{Editorial, Storage}
  alias VoelgoedAi.Support.ActionScope

  postgres do
    table("knowledge_collections")
    repo(VoelgoedAi.Repo)

    check_constraints do
      check_constraint(:status, "knowledge_collections_lifecycle",
        check:
          "status IN ('disabled','active','retired') AND audience IN ('public','internal') AND security_epoch >= 0"
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:slug, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/]
    )

    attribute(:name, :string, allow_nil?: false, constraints: [max_length: 120])
    attribute(:audience, :atom, allow_nil?: false, constraints: [one_of: [:public, :internal]])

    attribute(:status, :atom,
      allow_nil?: false,
      default: :disabled,
      constraints: [one_of: [:disabled, :active, :retired]]
    )

    attribute(:security_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:slug, [:slug])
  end

  actions do
    action :create, :map do
      argument(:slug, :string,
        constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/],
        allow_nil?: false
      )

      argument(:name, :string, constraints: [max_length: 120], allow_nil?: false)
      argument(:audience, :atom, constraints: [one_of: [:public, :internal]], allow_nil?: false)
      run(Editorial)
    end

    action :enable, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    action :disable, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    action :retire, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    action :read_collection, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    action :export_articles, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:article_ids, {:array, :uuid},
        default: [],
        allow_nil?: false,
        constraints: [max_length: 10]
      )

      run(Editorial)
    end

    action :preview_import, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:document, :string,
        constraints: [max_length: 262_144, trim?: false],
        allow_nil?: false
      )

      argument(:new_revision_for, :uuid, allow_nil?: true)
      run(Editorial)
    end

    action :apply_import, :map do
      argument(:id, :uuid, allow_nil?: false)

      argument(:document, :string,
        constraints: [max_length: 262_144, trim?: false],
        allow_nil?: false
      )

      argument(:new_revision_for, :uuid, allow_nil?: true)
      run(Editorial)
    end

    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    create :insert_row do
      transaction?(false)
      accept([:slug, :name, :audience])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :security_epoch])
    end
  end

  policies do
    policy action([
             :create,
             :enable,
             :disable,
             :retire,
             :read_collection,
             :export_articles,
             :preview_import,
             :apply_import
           ]) do
      authorize_if(Editorial)
    end

    policy action([:insert_row, :change_row]) do
      authorize_if(Storage)
    end

    policy action(:storage_row) do
      authorize_if(Storage)
      authorize_if(ActionScope.Storage)
    end
  end
end
