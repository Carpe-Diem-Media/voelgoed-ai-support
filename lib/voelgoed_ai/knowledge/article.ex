defmodule VoelgoedAi.Knowledge.Article do
  @moduledoc "Stable article identity. Archival is terminal and preserves editorial history."

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.{Editorial, Storage}

  postgres do
    table("articles")
    repo(VoelgoedAi.Repo)

    references do
      reference(:collection, on_delete: :restrict, on_update: :restrict)
      reference(:owner, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:status, "articles_editorial_lifecycle",
        check:
          "(status = 'active' AND archived_at IS NULL) OR (status = 'archived' AND archived_at IS NOT NULL AND current_revision_id IS NULL)"
      )
    end

    custom_statements do
      statement :article_current_revision do
        after_tables(["articles", "article_revisions"])

        up(
          "ALTER TABLE articles ADD CONSTRAINT articles_current_revision_fkey FOREIGN KEY (id, current_revision_id) REFERENCES article_revisions (article_id, id) ON DELETE RESTRICT ON UPDATE RESTRICT"
        )

        down("ALTER TABLE articles DROP CONSTRAINT articles_current_revision_fkey")
      end
    end
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:article_ref, :string, allow_nil?: false, constraints: [max_length: 80])

    attribute(:slug, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/]
    )

    attribute(:current_revision_id, :uuid)

    attribute(:status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :archived]]
    )

    attribute(:archived_at, :utc_datetime_usec)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:collection, VoelgoedAi.Knowledge.KnowledgeCollection, allow_nil?: false)
    belongs_to(:owner, VoelgoedAi.Accounts.StaffUser, allow_nil?: false)
  end

  identities do
    identity(:article_ref, [:article_ref])
    identity(:collection_slug, [:collection_id, :slug])
  end

  actions do
    action :create_draft, :map do
      argument(:collection_id, :uuid, allow_nil?: false)
      argument(:article_ref, :string, constraints: [max_length: 80], allow_nil?: false)

      argument(:slug, :string,
        constraints: [match: ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/],
        allow_nil?: false
      )

      argument(:content, :map, allow_nil?: false)
      run(Editorial)
    end

    action :archive, :map do
      argument(:id, :uuid, allow_nil?: false)
      argument(:reason, :atom, constraints: [one_of: [:obsolete]], allow_nil?: false)
      run(Editorial)
    end

    action :list_articles, :map do
      description(
        "List permitted articles in ascending ID order. Pass the returned cursor to continue."
      )

      argument(:collection_id, :uuid, allow_nil?: false)
      argument(:after_id, :uuid)
      argument(:limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 50])
      run(Editorial)
    end

    action :read_article, :map do
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    read(:editorial_page)

    read :storage_row do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
    end

    read :by_ref do
      argument(:article_ref, :string, allow_nil?: false)
      filter(expr(article_ref == ^arg(:article_ref)))
    end

    read :by_slug do
      argument(:collection_id, :uuid, allow_nil?: false)
      argument(:slug, :string, allow_nil?: false)
      filter(expr(collection_id == ^arg(:collection_id) and slug == ^arg(:slug)))
    end

    read :for_export do
      argument(:collection_id, :uuid, allow_nil?: false)
      filter(expr(collection_id == ^arg(:collection_id) and status == :active))
      prepare(build(sort: [:article_ref], limit: 11))
    end

    read :selected_for_export do
      argument(:collection_id, :uuid, allow_nil?: false)

      argument(:ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 10]
      )

      filter(
        expr(collection_id == ^arg(:collection_id) and status == :active and id in ^arg(:ids))
      )

      prepare(build(sort: [:article_ref], limit: 10))
    end

    create :insert_row do
      transaction?(false)
      accept([:article_ref, :slug, :collection_id, :owner_id])
    end

    update :change_row do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :archived_at, :current_revision_id])
    end
  end

  policies do
    policy action([:create_draft, :archive, :read_article, :list_articles]) do
      authorize_if(Editorial)
    end

    policy action([
             :insert_row,
             :change_row,
             :by_ref,
             :by_slug,
             :for_export,
             :selected_for_export
           ]) do
      authorize_if(Storage)
    end

    policy action(:editorial_page) do
      authorize_if(Storage)
    end

    policy action(:storage_row) do
      authorize_if(Storage)
    end
  end
end
