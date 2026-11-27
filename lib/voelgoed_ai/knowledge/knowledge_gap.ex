defmodule VoelgoedAi.Knowledge.KnowledgeGap do
  @moduledoc """
  One qualified FAQ occurrence from a completed shadow run. Review uses an
  expected version. Addressed and dismissed occurrences remain terminal.
  """

  use Ash.Resource,
    domain: VoelgoedAi.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Knowledge.{GapReview, Storage}

  @causes [:missing, :insufficient, :conflicting]
  @states [:open, :in_review, :dismissed, :addressed]
  @dismissals [:duplicate_issue, :out_of_scope, :no_change_needed]

  def dismissal_reasons, do: @dismissals

  postgres do
    table("knowledge_gaps")
    repo(VoelgoedAi.Repo)

    references do
      reference(:assistant, on_delete: :restrict)
      reference(:assistant_revision, on_delete: :restrict)
      reference(:binding, on_delete: :restrict)
      reference(:collection, on_delete: :restrict)
      reference(:support_run, on_delete: :restrict)
      reference(:recurrence_of, on_delete: :restrict)
      reference(:first_source, on_delete: :restrict)
      reference(:second_source, on_delete: :restrict)
      reference(:resolved_revision, on_delete: :restrict)
    end

    custom_indexes do
      index([:binding_id, :inserted_at, :id], name: "knowledge_gaps_queue")
    end

    check_constraints do
      check_constraint(:cause, "knowledge_gaps_evidence",
        check: """
        (cause = 'missing' AND first_source_id IS NULL AND second_source_id IS NULL)
        OR (cause = 'insufficient' AND first_source_id IS NOT NULL AND second_source_id IS NULL)
        OR (cause = 'conflicting' AND first_source_id IS NOT NULL AND second_source_id IS NOT NULL
            AND first_source_id <> second_source_id)
        """
      )

      check_constraint(:status, "knowledge_gaps_review",
        check: """
        review_version >= 1 AND recurrence_of_id IS DISTINCT FROM id
        AND ((status IN ('open','in_review') AND dismissal_reason IS NULL AND resolved_revision_id IS NULL)
          OR (status = 'dismissed' AND dismissal_reason IS NOT NULL AND resolved_revision_id IS NULL)
          OR (status = 'addressed' AND dismissal_reason IS NULL AND resolved_revision_id IS NOT NULL))
        AND (dismissal_reason IS NULL OR dismissal_reason IN ('duplicate_issue','out_of_scope','no_change_needed'))
        """
      )

      check_constraint(:locale, "knowledge_gaps_locale", check: "locale IN ('en-ZA','af-ZA')")
    end
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:topic, :string, allow_nil?: false)
    attribute(:locale, :string, allow_nil?: false)
    attribute(:applicability, :string, allow_nil?: false)
    attribute(:cause, :atom, allow_nil?: false, constraints: [one_of: @causes])
    attribute(:status, :atom, allow_nil?: false, default: :open, constraints: [one_of: @states])
    attribute(:review_version, :integer, allow_nil?: false, default: 1, constraints: [min: 1])
    attribute(:dismissal_reason, :atom, constraints: [one_of: @dismissals])
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:assistant, VoelgoedAi.Intelligence.Assistant, allow_nil?: false)
    belongs_to(:assistant_revision, VoelgoedAi.Intelligence.AssistantRevision, allow_nil?: false)
    belongs_to(:binding, VoelgoedAi.Support.InboxBinding, allow_nil?: false)
    belongs_to(:collection, VoelgoedAi.Knowledge.KnowledgeCollection, allow_nil?: false)
    belongs_to(:support_run, VoelgoedAi.Support.SupportRun, allow_nil?: false)
    belongs_to(:recurrence_of, __MODULE__)
    belongs_to(:first_source, VoelgoedAi.Knowledge.ArticleRevision)
    belongs_to(:second_source, VoelgoedAi.Knowledge.ArticleRevision)
    belongs_to(:resolved_revision, VoelgoedAi.Knowledge.ArticleRevision)
  end

  identities do
    identity(:one_per_run, [:support_run_id])
  end

  actions do
    read :scoped_rows do
      description("Read occurrences only within the owning transaction.")
    end

    create :register do
      transaction?(false)

      accept([
        :assistant_id,
        :assistant_revision_id,
        :binding_id,
        :collection_id,
        :support_run_id,
        :topic,
        :locale,
        :applicability,
        :cause,
        :first_source_id,
        :second_source_id,
        :recurrence_of_id
      ])
    end

    update :change_review do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :review_version, :dismissal_reason, :resolved_revision_id])
    end

    action :list_gaps, :map do
      argument(:before_id, :uuid)
      run(GapReview)
    end

    for action <- [:review, :defer, :dismiss, :address] do
      action action, :map do
        argument(:id, :uuid, allow_nil?: false)
        argument(:expected_version, :integer, allow_nil?: false, constraints: [min: 1])

        if action == :dismiss do
          argument(:reason, :atom, allow_nil?: false, constraints: [one_of: @dismissals])
        end

        if action == :address do
          argument(:revision_id, :uuid, allow_nil?: false)
          argument(:attested, :boolean, allow_nil?: false)
        end

        run(GapReview)
      end
    end
  end

  policies do
    policy action([:scoped_rows, :register, :change_review]) do
      authorize_if(Storage)
    end

    policy action([:list_gaps, :review, :defer, :dismiss, :address]) do
      authorize_if(GapReview)
    end
  end
end
