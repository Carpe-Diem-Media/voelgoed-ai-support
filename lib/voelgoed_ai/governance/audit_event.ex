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
    :request_publish,
    :retry_publication,
    :revoke,
    :request_reindex,
    :archive
  ]
  @publication_events [
    :activate,
    :supersede,
    :expire,
    :switch_index,
    :rollback_index,
    :fail_publication,
    :fail_reindex
  ]
  @publication_reasons [:index_ready, :replaced, :deadline, :evaluated, :stale_request]
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
  @gap_events [:gap_reviewed, :gap_deferred, :gap_dismissed, :gap_addressed]
  @gap_reasons [:duplicate_issue, :out_of_scope, :no_change_needed]
  @support_events [:request_handoff, :return_to_bot, :close_session, :abandon_delivery]
  @system_events [:delivery_unknown, :missed_deadline, :handoff_failed]
  @system_target_kinds [:inbound_event, :support_run, :outbound_delivery]
  @system_reason_sql Enum.map_join(ReasonCode.values(), ",", &"'#{&1}'")
  @financial_events [
    :close_unknown_inference,
    :reset_embedding_inhibit,
    :reset_generation_inhibit
  ]
  @inhibit_events [:trip_generation_inhibit, :trip_embedding_inhibit]
  @operational_fields [
    inhibited: [type: :boolean],
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
          :publishing,
          :publish_failed,
          :withdrawn,
          :revoked,
          :expired,
          :open,
          :addressed,
          :dismissed
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
    response_policy: [
      type: :atom,
      constraints: [one_of: [:fixed_reply, :handoff, :shadow_decision]]
    ],
    config_hash: [type: :string, constraints: [max_length: 64]],
    config_hash_version: [type: :integer, constraints: [min: 1, max: 2]],
    collection_id: [type: :uuid],
    content_hash: [type: :string, constraints: [max_length: 64]],
    index_generation: [type: :integer, constraints: [min: 1]],
    index_epoch: [type: :integer, constraints: [min: 1]],
    collection_epoch: [type: :integer, constraints: [min: 0]],
    deadline_us: [type: :integer, constraints: [min: 1]],
    content_profile_id: [type: :string, constraints: [max_length: 128]],
    version: [type: :integer, constraints: [min: 1]],
    edit_version: [type: :integer, constraints: [min: 1]],
    installation_ref: [type: :string, constraints: [max_length: 64]],
    external_account_id: [type: :integer, constraints: [min: 1]],
    external_inbox_id: [type: :integer, constraints: [min: 1]],
    handoff_team_id: [type: :integer, constraints: [min: 1]],
    operating_mode: [type: :atom, constraints: [one_of: [:shadow, :assisted, :automatic]]],
    mode: [type: :atom, constraints: [one_of: [:disabled, :fake, :shadow_test]]]
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
      reference(:inhibit_attempt, on_delete: :restrict, on_update: :restrict)
      reference(:settlement_target, on_delete: :restrict, on_update: :restrict)
      reference(:target, on_delete: :restrict, on_update: :restrict)
      reference(:knowledge_gap_target, on_delete: :restrict, on_update: :restrict)
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

    custom_indexes do
      index([:correlation_id],
        name: "audit_events_inhibit_occurrence",
        unique: true,
        where: "event IN ('trip_generation_inhibit','trip_embedding_inhibit')"
      )
    end

    check_constraints do
      check_constraint(:event, "audit_events_inhibit_shape",
        check: """
        (event IN ('trip_generation_inhibit','trip_embedding_inhibit') AND inhibit_attempt_id IS NOT NULL
          AND inhibit_reset_eligible IS NOT NULL
          AND (NOT inhibit_reset_eligible OR inhibit_quote IS NOT NULL))
        OR (event NOT IN ('trip_generation_inhibit','trip_embedding_inhibit')
          AND inhibit_attempt_id IS NULL AND inhibit_quote IS NULL AND inhibit_reset_eligible IS NULL)
        """
      )

      check_constraint(:actor_kind, "audit_events_actor_reference",
        check: """
        (actor_kind = 'bootstrap' AND actor_staff_id IS NULL AND operator_ref = 'staff-bootstrap' AND operator_ref IS NOT NULL)
        OR (actor_kind = 'staff' AND actor_staff_id IS NOT NULL AND operator_ref IS NULL)
        OR (actor_kind IN ('support_worker','embedding_worker','publisher') AND actor_staff_id IS NULL AND operator_ref IS NULL)
        """
      )

      check_constraint(:target_kind, "audit_events_exact_target",
        check: """
          num_nonnulls(settlement_target_id, target_id, assistant_target_id, revision_target_id, binding_target_id, control_target_id, session_target_id, delivery_target_id, event_target_id, run_target_id, knowledge_collection_target_id, article_target_id, article_revision_target_id, knowledge_gap_target_id) = 1
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
              AND event IN ('enable_automation','disable_automation','reset_embedding_inhibit','reset_generation_inhibit','trip_generation_inhibit','trip_embedding_inhibit'))
            OR (target_kind = 'usage_settlement' AND settlement_target_id IS NOT NULL
              AND event = 'close_unknown_inference' AND reason_code = 'local_admin')
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
                OR (event IN ('request_publish','retry_publication','request_reindex','request_index_rollback') AND reason_code = 'source_verified')
                OR (event = 'revoke' AND reason_code = 'obsolete')
                OR (event IN ('fail_publication','fail_reindex') AND reason_code IN ('deadline','stale_request','transport_unknown','invalid_vector','admission_denied'))
                OR (event IN ('activate','switch_index') AND reason_code = 'index_ready')
                OR (event = 'supersede' AND reason_code = 'replaced')
                OR (event = 'expire' AND reason_code = 'deadline')
                OR (event = 'rollback_index' AND reason_code = 'evaluated')
                OR (event = 'archive' AND reason_code = 'obsolete')))
            OR (target_kind = 'knowledge_gap' AND knowledge_gap_target_id IS NOT NULL
              AND ((event = 'gap_dismissed' AND reason_code IN ('duplicate_issue','out_of_scope','no_change_needed'))
                OR (event IN ('gap_reviewed','gap_deferred','gap_addressed') AND reason_code = 'local_admin')))
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
            AND event NOT IN ('gap_reviewed','gap_deferred','gap_dismissed','gap_addressed','delivery_unknown','missed_deadline','handoff_failed','fail_publication','fail_reindex','expire','switch_index','rollback_index','trip_generation_inhibit','trip_embedding_inhibit')
            AND (target_kind <> 'knowledge_revision' OR event NOT IN ('activate','supersede'))
            AND ((target_kind IN ('support_session', 'outbound_delivery') AND reason_code = 'local_operator')
              OR (target_kind IN ('knowledge_collection','knowledge_article','knowledge_revision'))
              OR (target_kind NOT IN ('staff_user','support_session','outbound_delivery','knowledge_collection','knowledge_article','knowledge_revision') AND reason_code = 'local_admin')))
          OR (actor_kind = 'staff' AND target_kind = 'knowledge_gap'
            AND before_state IS NULL AND after_state IS NULL
            AND (CASE event
              WHEN 'gap_reviewed' THEN operational_before->>'status' = 'open' AND operational_after->>'status' = 'in_review'
              WHEN 'gap_deferred' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'open'
              WHEN 'gap_dismissed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'dismissed'
              WHEN 'gap_addressed' THEN operational_before->>'status' = 'in_review' AND operational_after->>'status' = 'addressed'
              ELSE false END) IS TRUE)
          OR (actor_kind = 'embedding_worker' AND target_kind = 'knowledge_revision'
            AND event IN ('fail_publication','fail_reindex') AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NOT NULL AND operational_after IS NOT NULL)
          OR (actor_kind = 'publisher' AND target_kind = 'knowledge_revision'
            AND before_state IS NULL AND after_state IS NULL AND
            (CASE event
              WHEN 'activate' THEN operational_before->>'status' = 'publishing' AND operational_after->>'status' = 'published'
              WHEN 'supersede' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'superseded'
              WHEN 'expire' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'expired'
              WHEN 'switch_index' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              WHEN 'rollback_index' THEN operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              WHEN 'fail_publication' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'publishing' AND operational_after->>'status' = 'publish_failed'
              WHEN 'fail_reindex' THEN reason_code IN ('deadline','stale_request')
                AND operational_before->>'status' = 'published' AND operational_after->>'status' = 'published'
              ELSE false END) IS TRUE)
          OR (target_kind = 'automation_control' AND before_state IS NULL AND after_state IS NULL
            AND operational_before IS NULL AND operational_after IS NULL
            AND reason_code IN ('over_reserve','amount_overflow')
            AND ((actor_kind = 'support_worker' AND event = 'trip_generation_inhibit')
              OR (actor_kind = 'embedding_worker' AND event = 'trip_embedding_inhibit')))
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
      constraints: [one_of: [:staff, :bootstrap, :support_worker, :embedding_worker, :publisher]]
    )

    attribute(:operator_ref, :string, constraints: [match: ~r/\Astaff-bootstrap\z/])

    attribute(:target_kind, :atom,
      allow_nil?: false,
      default: :staff_user,
      constraints: [
        one_of: [
          :staff_user,
          :usage_settlement,
          :support_session,
          :knowledge_gap | @system_target_kinds ++ @target_kinds ++ @knowledge_targets
        ]
      ]
    )

    attribute(:event, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :request_index_rollback
          | @publication_events ++
              @staff_events ++
              @operational_events ++
              @support_events ++
              @system_events ++
              @knowledge_events ++ @financial_events ++ @inhibit_events ++ @gap_events
        ]
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
          ] ++
            ReasonCode.values() ++
            @knowledge_reasons ++
            @gap_reasons ++
            @publication_reasons ++
            [
              :stale_request,
              :transport_unknown,
              :invalid_vector,
              :admission_denied,
              :amount_overflow,
              :over_reserve
            ]
      ]
    )

    attribute(:before_state, :map, constraints: [fields: @state_fields])
    attribute(:after_state, :map, constraints: [fields: @state_fields])
    attribute(:operational_before, :map, constraints: [fields: @operational_fields])
    attribute(:operational_after, :map, constraints: [fields: @operational_fields])
    attribute(:inhibit_quote, :map)
    attribute(:inhibit_reset_eligible, :boolean)
    attribute(:correlation_id, :uuid, allow_nil?: false)
    attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:inhibit_attempt, VoelgoedAi.Intelligence.InferenceRun)
    belongs_to(:settlement_target, VoelgoedAi.Governance.UsageLedger)
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
    belongs_to(:knowledge_gap_target, VoelgoedAi.Knowledge.KnowledgeGap)
    belongs_to(:actor_staff, StaffUser)
  end

  identities do
    identity(:settlement_audit, [:settlement_target_id])
  end

  actions do
    create :append_gap_review do
      description("Append the scoped staff decision in the gap review transaction.")
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :knowledge_gap_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(attribute_equals(:actor_kind, :staff))
      validate(attribute_equals(:target_kind, :knowledge_gap))
      validate(attribute_in(:event, @gap_events))
    end

    create :append_inhibit_trip do
      description("Record the attempt and its admitted quote for one inhibit occurrence.")
      transaction?(false)

      accept([
        :actor_kind,
        :target_kind,
        :control_target_id,
        :inhibit_attempt_id,
        :inhibit_quote,
        :inhibit_reset_eligible,
        :event,
        :reason_code,
        :correlation_id,
        :occurred_at
      ])

      validate(attribute_in(:event, @inhibit_events))
    end

    read :inhibit_trip do
      argument(:control_id, :uuid, allow_nil?: false)
      argument(:occurrence, :uuid, allow_nil?: false)
      argument(:event, :atom, allow_nil?: false, constraints: [one_of: @inhibit_events])

      filter(
        expr(
          control_target_id == ^arg(:control_id) and correlation_id == ^arg(:occurrence) and
            event == ^arg(:event)
        )
      )
    end

    create :append_financial do
      description("Write the TEST financial decision in the same transaction as its disposition.")
      transaction?(false)

      accept([
        :actor_kind,
        :actor_staff_id,
        :target_kind,
        :settlement_target_id,
        :control_target_id,
        :event,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id,
        :occurred_at
      ])

      validate(attribute_equals(:actor_kind, :staff))
      validate(attribute_equals(:reason_code, :local_admin))
      validate(attribute_in(:event, @financial_events))
      validate(present([:operational_before, :operational_after]))
    end

    read :financial_closure do
      argument(:settlement_id, :uuid, allow_nil?: false)

      filter(
        expr(settlement_target_id == ^arg(:settlement_id) and event == :close_unknown_inference)
      )
    end

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

    create :append_publication_failure do
      transaction?(false)

      accept([
        :article_revision_target_id,
        :event,
        :actor_kind,
        :target_kind,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(attribute_in(:event, [:fail_publication, :fail_reindex]))
      validate(attribute_equals(:actor_kind, :embedding_worker))
    end

    create :append_publication_transition do
      transaction?(false)

      accept([
        :article_revision_target_id,
        :event,
        :actor_kind,
        :target_kind,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(attribute_equals(:actor_kind, :publisher))
      validate(attribute_equals(:target_kind, :knowledge_revision))
      validate(attribute_in(:event, @publication_events))
      validate(attribute_in(:reason_code, @publication_reasons))
    end

    create :append_rollback_request do
      transaction?(false)

      accept([
        :article_revision_target_id,
        :actor_staff_id,
        :event,
        :actor_kind,
        :target_kind,
        :reason_code,
        :operational_before,
        :operational_after,
        :correlation_id
      ])

      validate(attribute_equals(:actor_kind, :staff))
      validate(attribute_equals(:target_kind, :knowledge_revision))
      validate(attribute_equals(:event, :request_index_rollback))
      validate(attribute_equals(:reason_code, :source_verified))
      validate(present([:operational_before, :operational_after]))
    end

    read :rollback_request do
      argument(:id, :uuid, allow_nil?: false)

      filter(
        expr(
          id == ^arg(:id) and event == :request_index_rollback and
            actor_kind == :staff and target_kind == :knowledge_revision
        )
      )
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

      prepare(build(sort: [occurred_at: :desc, id: :desc], limit: 100))
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
    policy action(:append_gap_review) do
      authorize_if(Storage)
    end

    policy action([:append_financial, :financial_closure, :append_inhibit_trip, :inhibit_trip]) do
      authorize_if(Storage)
    end

    policy action([
             :append_publication_failure,
             :append_publication_transition,
             :append_rollback_request,
             :rollback_request
           ]) do
      authorize_if(Storage)
    end

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
