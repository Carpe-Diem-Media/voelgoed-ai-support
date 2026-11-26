defmodule VoelgoedAi.Governance.AuditEvent do
  @moduledoc "An immutable staff security, configuration or support workflow fact with local references."

  use Ash.Resource,
    domain: VoelgoedAi.Governance,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias VoelgoedAi.Accounts.{StaffAccess, StaffUser}
  alias VoelgoedAi.Accounts.StaffAccess.Scope

  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Editorial, KnowledgeCollection, Storage}
  alias VoelgoedAi.Support.{ActionScope, Configuration, ReasonCode, SystemAudit, WorkStore}

  @staff_events [
    :provisioned,
    :activated,
    :signed_in,
    :roles_changed,
    :disabled,
    :reactivated,
    :retired
  ]
  @operational_events [
    :create,
    :activate,
    :disable,
    :retire,
    :switch_revision,
    :create_draft,
    :edit_draft,
    :publish,
    :supersede,
    :discard,
    :enable,
    :rebind,
    :change_mode,
    :enable_automation,
    :disable_automation,
    :grant_collection,
    :remove_collection
  ]
  @target_kinds [:assistant, :assistant_revision, :inbox_binding, :automation_control]
  @knowledge_targets [:knowledge_collection, :knowledge_article, :knowledge_revision]
  @knowledge_events [
    :create,
    :enable,
    :disable,
    :retire,
    :create_draft,
    :edit_draft,
    :submit_review,
    :request_changes,
    :approve,
    :withdraw,
    :archive
  ]
  @knowledge_reasons [
    :local_admin,
    :local_editor,
    :source_correction,
    :content_correction,
    :source_verified,
    :self_approval_attested,
    :withdrawn_by_staff,
    :obsolete
  ]
  @support_events [:request_handoff, :return_to_bot, :close_session, :abandon_delivery]
  @system_events [:delivery_unknown, :missed_deadline, :handoff_failed]
  @system_target_kinds [:inbound_event, :support_run, :outbound_delivery]
  @system_reason_sql Enum.map_join(ReasonCode.values(), ",", &"'#{&1}'")
  @operational_fields [
    ownership_epoch: [type: :integer, constraints: [min: 0]],
    status: [
      type: :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :active,
          :disabled,
          :enabled,
          :retired,
          :draft,
          :published,
          :superseded,
          :discarded,
          :unverified,
          :bot_active,
          :handoff_pending,
          :human_active,
          :closed,
          :unknown,
          :abandoned,
          :archived,
          :in_review,
          :approved,
          :withdrawn,
          :revoked
        ]
      ]
    ],
    security_epoch: [type: :integer, constraints: [min: 0]],
    slug: [type: :string, constraints: [max_length: 64]],
    display_name: [type: :string, constraints: [max_length: 120]],
    kind: [type: :atom, constraints: [one_of: [:customer_support]]],
    audience: [type: :atom, constraints: [one_of: [:public, :internal]]],
    active_revision_id: [type: :uuid],
    assistant_id: [type: :uuid],
    revision_number: [type: :integer, constraints: [min: 1]],
    workflow_version: [type: :string, constraints: [max_length: 64]],
    template_version: [type: :string, constraints: [max_length: 64]],
    locale: [type: :atom, constraints: [one_of: [:af, :en]]],
    response_policy: [type: :atom, constraints: [one_of: [:fixed_reply, :handoff]]],
    config_hash: [type: :string, constraints: [max_length: 64]],
    config_hash_version: [type: :integer, constraints: [min: 1, max: 2]],
    collection_id: [type: :uuid],
    content_hash: [type: :string, constraints: [max_length: 64]],
    edit_version: [type: :integer, constraints: [min: 1]],
    installation_ref: [type: :string, constraints: [max_length: 64]],
    external_account_id: [type: :integer, constraints: [min: 1]],
    external_inbox_id: [type: :integer, constraints: [min: 1]],
    handoff_team_id: [type: :integer, constraints: [min: 1]],
    operating_mode: [type: :atom, constraints: [one_of: [:shadow, :assisted, :automatic]]],
    mode: [type: :atom, constraints: [one_of: [:disabled, :fake]]]
  ]

  @state_fields [
    status: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:invited, :active, :disabled, :retired]]
    ],
    roles: [
      type: {:array, :atom},
      allow_nil?: false,
      constraints: [max_length: 4, items: [one_of: StaffAccess.roles()]]
    ],
    session_generation: [type: :integer, allow_nil?: false, constraints: [min: 0]]
  ]

  postgres do
    table("audit_events")
    repo(VoelgoedAi.Repo)

    references do
      reference(:target, on_delete: :restrict, on_update: :restrict)
      reference(:actor_staff, on_delete: :restrict, on_update: :restrict)
      reference(:assistant_target, on_delete: :restrict, on_update: :restrict)
      reference(:revision_target, on_delete: :restrict, on_update: :restrict)
      reference(:binding_target, on_delete: :restrict, on_update: :restrict)
      reference(:control_target, on_delete: :restrict, on_update: :restrict)
      reference(:session_target, on_delete: :restrict, on_update: :restrict)
      reference(:event_target, on_delete: :restrict, on_update: :restrict)
      reference(:knowledge_collection_target, on_delete: :restrict, on_update: :restrict)
      reference(:article_target, on_delete: :restrict, on_update: :restrict)
      reference(:article_revision_target, on_delete: :restrict, on_update: :restrict)
      reference(:run_target, on_delete: :restrict, on_update: :restrict)
      reference(:delivery_target, on_delete: :restrict, on_update: :restrict)
    end

    check_constraints do
      check_constraint(:actor_kind, "audit_events_actor_reference",
        check: """
        (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
        OR (actor_kind = 'support_worker' AND actor_staff_id IS NULL AND operator_ref IS NULL)
        """
      )

      check_constraint(:target_kind, "audit_events_exact_target",
        check: """
          num_nonnulls(target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id) = 1
          AND (
            (target_kind = 'staff_user' AND target_id IS NOT NULL
              AND event IN ('provisioned','activated','signed_in','roles_changed','disabled','reactivated','retired')
              AND reason_code IN ('allowlisted','verified_oidc','local_admin','approved_reprovision'))
            OR (target_kind = 'assistant' AND assistant_target_id IS NOT NULL
              AND event IN ('create','activate','disable','retire','switch_revision'))
            OR (target_kind = 'assistant_revision' AND revision_target_id IS NOT NULL
              AND event IN ('create_draft','edit_draft','publish','supersede','discard','grant_collection','remove_collection'))
            OR (target_kind = 'inbox_binding' AND binding_target_id IS NOT NULL
              AND event IN ('create_draft','enable','disable','rebind','change_mode','retire'))
            OR (target_kind = 'automation_control' AND control_target_id IS NOT NULL
              AND event IN ('enable_automation','disable_automation'))
            OR (target_kind = 'knowledge_collection' AND knowledge_collection_target_id IS NOT NULL
              AND event IN ('create','enable','disable','retire') AND reason_code = 'local_admin')
            OR (target_kind = 'knowledge_article' AND article_target_id IS NOT NULL
              AND ((event = 'create_draft' AND reason_code = 'local_editor')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'knowledge_revision' AND article_revision_target_id IS NOT NULL
              AND ((event IN ('create_draft','edit_draft','submit_review') AND reason_code = 'local_editor')
                OR (event = 'request_changes' AND reason_code IN ('source_correction','content_correction'))
                OR (event = 'approve' AND reason_code IN ('source_verified','self_approval_attested'))
                OR (event = 'withdraw' AND reason_code = 'withdrawn_by_staff')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'support_session' AND session_target_id IS NOT NULL
              AND event IN ('request_handoff','return_to_bot','close_session'))
            OR (target_kind = 'outbound_delivery' AND delivery_target_id IS NOT NULL
              AND event IN ('abandon_delivery','delivery_unknown','handoff_failed'))
            OR (target_kind = 'inbound_event' AND event_target_id IS NOT NULL AND event = 'missed_deadline')
            OR (target_kind = 'support_run' AND run_target_id IS NOT NULL AND event = 'missed_deadline')
          )
        """
      )

      check_constraint(:target_kind, "audit_events_state_shape",
        check: """
          (target_kind = 'staff_user' AND actor_kind IN ('staff','bootstrap') AND after_state IS NOT NULL
            AND operational_before IS NULL AND operational_after IS NULL)
          OR (actor_kind = 'staff' AND before_state IS NULL AND after_state IS NULL AND operational_after IS NOT NULL
            AND event NOT IN ('delivery_unknown','missed_deadline','handoff_failed')
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (actor_kind = 'support_worker' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND ((event = 'delivery_unknown' AND reason_code IN (#{@system_reason_sql}))
              OR (event = 'missed_deadline' AND reason_code = 'deadline')
              OR (event = 'handoff_failed' AND reason_code IN ('deadline','read_exhausted','no_effect'))))
        """
      )
    end
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:actor_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:staff, :bootstrap, :support_worker]]
    )

    attribute(:operator_ref, :string, constraints: [match: ~r/\Astaff-bootstrap\z/])

    attribute(:target_kind, :atom,
      allow_nil?: false,
      default: :staff_user,
      constraints: [
        one_of: [
          :staff_user,
          :support_session | @system_target_kinds ++ @target_kinds ++ @knowledge_targets
        ]
      ]
    )

    attribute(:event, :atom,
      allow_nil?: false,
      constraints: [
        one_of:
          @staff_events ++
            @operational_events ++ @support_events ++ @system_events ++ @knowledge_events
      ]
    )

    attribute(:reason_code, :atom,
      allow_nil?: false,
      constraints: [
        one_of:
          [
            :allowlisted,
            :verified_oidc,
            :local_admin,
            :approved_reprovision,
            :local_operator
          ] ++ ReasonCode.values() ++ @knowledge_reasons
      ]
    )

    attribute(:before_state, :map, constraints: [fields: @state_fields])
    attribute(:after_state, :map, constraints: [fields: @state_fields])
    attribute(:operational_before, :map, constraints: [fields: @operational_fields])
    attribute(:operational_after, :map, constraints: [fields: @operational_fields])
    attribute(:correlation_id, :uuid, allow_nil?: false)
    attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:target, StaffUser)
    belongs_to(:assistant_target, VoelgoedAi.Intelligence.Assistant)
    belongs_to(:revision_target, VoelgoedAi.Intelligence.AssistantRevision)
    belongs_to(:binding_target, VoelgoedAi.Support.InboxBinding)
    belongs_to(:control_target, VoelgoedAi.Governance.AutomationControl)
    belongs_to(:session_target, VoelgoedAi.Support.SupportSession)
    belongs_to(:event_target, VoelgoedAi.Support.InboundEvent)
    belongs_to(:run_target, VoelgoedAi.Support.SupportRun)
    belongs_to(:delivery_target, VoelgoedAi.Support.OutboundDelivery)
    belongs_to(:knowledge_collection_target, KnowledgeCollection)
    belongs_to(:article_target, Article)
    belongs_to(:article_revision_target, ArticleRevision)
    belongs_to(:actor_staff, StaffUser)
  end

  actions do
    create :append do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :operator_ref,
        :target_id,
        :event,
        :reason_code,
        :before_state,
        :after_state,
        :correlation_id
      ])

      validate(present([:target_id, :after_state]))
      validate(attribute_in(:event, @staff_events))
    end

    create :append_operational do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :assistant_target_id,
        :revision_target_id,
        :binding_target_id,
        :control_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(present([:actor_staff_id, :operational_after]))
      validate(attribute_in(:target_kind, @target_kinds))
      validate(attribute_in(:event, @operational_events))
    end

    create :append_knowledge do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :knowledge_collection_target_id,
        :article_target_id,
        :article_revision_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(present([:actor_staff_id, :operational_after]))
      validate(attribute_equals(:actor_kind, :staff))
      validate(attribute_in(:target_kind, @knowledge_targets))
      validate(attribute_in(:event, @knowledge_events))
      validate(attribute_in(:reason_code, @knowledge_reasons))
    end

    action :knowledge_history, {:array, :map} do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @knowledge_targets])
      argument(:id, :uuid, allow_nil?: false)
      run(Editorial)
    end

    read :knowledge_rows do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @knowledge_targets])
      argument(:id, :uuid, allow_nil?: false)

      filter(
        expr(
          target_kind == ^arg(:target_kind) and
            (knowledge_collection_target_id == ^arg(:id) or article_target_id == ^arg(:id) or
               article_revision_target_id == ^arg(:id))
        )
      )

      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end

    create :append_support_operator do
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :session_target_id,
        :delivery_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(present([:actor_staff_id, :operational_before, :operational_after]))
      validate(attribute_in(:event, @support_events))
      validate(attribute_equals(:reason_code, :local_operator))
    end

    create :append_system do
      description("Append a typed support workflow fact inside its transition transaction.")
      transaction?(false)

      accept([
        :actor_kind,
        :target_kind,
        :event_target_id,
        :run_target_id,
        :delivery_target_id,
        :event,
        :reason_code,
        :correlation_id
      ])

      validate(attribute_equals(:actor_kind, :support_worker))
      validate(attribute_in(:target_kind, @system_target_kinds))
      validate(attribute_in(:event, @system_events))
      validate(attribute_in(:reason_code, ReasonCode.values()))
    end

    action :system_history, {:array, :map} do
      description("Return bounded system workflow history for one authorized internal target.")

      argument(:target_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: @system_target_kinds]
      )

      argument(:id, :uuid, allow_nil?: false)
      run(SystemAudit)
    end

    read :system_rows do
      argument(:target_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: @system_target_kinds]
      )

      argument(:id, :uuid, allow_nil?: false)

      filter(
        expr(
          actor_kind == :support_worker and target_kind == ^arg(:target_kind) and
            (event_target_id == ^arg(:id) or run_target_id == ^arg(:id) or
               delivery_target_id == ^arg(:id))
        )
      )

      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end

    action :operational_history, {:array, :map} do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @target_kinds])
      argument(:id, :uuid, allow_nil?: false)
      run(Configuration)
    end

    read :operational_rows do
      argument(:target_kind, :atom, allow_nil?: false, constraints: [one_of: @target_kinds])
      argument(:id, :uuid, allow_nil?: false)

      filter(
        expr(
          target_kind == ^arg(:target_kind) and
            (assistant_target_id == ^arg(:id) or revision_target_id == ^arg(:id) or
               binding_target_id == ^arg(:id) or control_target_id == ^arg(:id))
        )
      )

      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end

    read :staff_security_history do
      argument(:target_id, :uuid, allow_nil?: false)
      filter(expr(target_kind == :staff_user and target_id == ^arg(:target_id)))
      prepare(build(sort: [:occurred_at, :id], limit: 100))
    end
  end

  policies do
    policy action([:append_knowledge, :knowledge_rows]) do
      authorize_if(Storage)
    end

    policy action(:knowledge_history) do
      authorize_if(Editorial)
    end

    policy action([:append_support_operator, :append_system, :system_rows]) do
      authorize_if(WorkStore)
    end

    policy action(:system_history) do
      authorize_if(ActionScope)
    end

    policy action([:append_operational, :operational_rows]) do
      authorize_if(ActionScope.Storage)
    end

    policy action(:operational_history) do
      authorize_if(ActionScope.Admin)
      authorize_if(ActionScope)
    end

    policy action([:append, :staff_security_history]) do
      authorize_if(Scope)
    end
  end
end
