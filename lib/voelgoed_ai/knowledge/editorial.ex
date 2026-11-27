defmodule VoelgoedAi.Knowledge.Editorial do
  @moduledoc """
  Runs editorial actions after rechecking current staff authority. Writes take
  the control lock before collection, article and revision locks. A failed
  audit rolls back the corresponding transition. Approval cannot publish or
  queue work.
  """

  use Ash.Resource.Actions.Implementation
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Accounts.StaffAccess.Session
  alias VoelgoedAi.Governance.AuditEvent

  alias VoelgoedAi.Knowledge.{
    Article,
    ArticleEmbedding,
    ArticleRevision,
    Content,
    KnowledgeCollection,
    Portable,
    Publication,
    Storage
  }

  alias VoelgoedAi.Intelligence.{Embedding, EmbeddingProfile}
  alias VoelgoedAi.Knowledge.Workers.{IndexArticle, RecoverIndexing}
  alias VoelgoedAi.Support.Configuration

  @editor :knowledge_editor
  @reviewer :knowledge_reviewer
  @read_actions [
    :read_collection,
    :read_article,
    :read_revision,
    :knowledge_history,
    :list_collections,
    :list_articles,
    :list_revisions
  ]
  @collection_admin [:create, :enable, :disable, :retire]
  @editor_actions [:create_draft, :edit_draft, :submit_review, :preview_import, :apply_import]
  @reviewer_actions [
    :request_changes,
    :approve,
    :archive,
    :export_articles,
    :request_publish,
    :retry_publication,
    :request_reindex,
    :request_index_rollback,
    :revoke
  ]

  @impl Ash.Policy.Check
  def describe(_opts),
    do: "a staff session whose current collection authority is checked by the action"

  @impl Ash.Policy.SimpleCheck
  def match?(%Session{}, %{subject: %Ash.ActionInput{}}, _opts), do: true
  def match?(_, _, _), do: false

  @impl Ash.Resource.Actions.Implementation
  def run(input, _opts, %{actor: session}) do
    action = input.action.name

    StaffAccess.with_current(session, required_role(action), fn staff ->
      with {:ok, _} <- Configuration.lock_control() do
        execute(input.resource, action, input.arguments, staff)
      end
    end)
    |> result()
  end

  defp required_role(action) when action in @collection_admin, do: :admin
  defp required_role(action) when action in @editor_actions, do: @editor
  defp required_role(action) when action in @reviewer_actions, do: @reviewer
  defp required_role(action) when action in [:withdraw | @read_actions], do: nil

  defp execute(KnowledgeCollection, :create, args, staff) do
    with {:ok, row} <- insert(KnowledgeCollection, args, :create, staff),
         do: {:ok, collection_view(row)}
  end

  defp execute(KnowledgeCollection, :list_collections, args, staff) do
    cond do
      :admin in staff.roles ->
        page(KnowledgeCollection, args, [], &collection_view/1)

      Enum.any?([@editor, @reviewer], &(&1 in staff.roles)) ->
        ids = for {id, _} <- fixture_scope(), editorial_scope?(id, staff), do: id
        page(KnowledgeCollection, args, [id: [in: ids]], &collection_view/1)

      true ->
        {:error, :denied}
    end
  end

  defp execute(KnowledgeCollection, action, %{id: id} = args, staff) do
    with {:ok, collection} <- get(KnowledgeCollection, id, :for_update),
         :ok <- authorize_collection(collection, staff, action) do
      collection_action(collection, action, args, staff)
    end
  end

  defp execute(Article, :create_draft, %{collection_id: id} = args, staff) do
    with {:ok, collection} <- get(KnowledgeCollection, id, :for_update),
         :ok <- authorize_collection(collection, staff, :create_draft),
         :ok <- active(collection),
         {:ok, content} <- Content.parse(args.content),
         {:ok, article} <- create_article(collection, args.article_ref, args.slug, staff),
         {:ok, revision} <- create_revision(article, content, staff) do
      {:ok, %{article: article_view(article), revision: revision_view(revision)}}
    end
  end

  defp execute(Article, :list_articles, %{collection_id: id} = args, staff) do
    with {:ok, collection} <- get(KnowledgeCollection, id, :for_update),
         :ok <- authorize_collection(collection, staff, :list_articles) do
      page(Article, args, [collection_id: id], &article_view/1)
    end
  end

  defp execute(Article, action, %{id: id} = args, staff) do
    with {:ok, collection, article} <- lock_article(id, staff, action) do
      article_action(collection, article, action, args, staff)
    end
  end

  defp execute(ArticleRevision, :create_draft, args, staff) do
    with {:ok, collection, article} <- lock_article(args.article_id, staff, :create_draft),
         :ok <- active(collection),
         :ok <- active(article),
         {:ok, content} <- Content.parse(args.content),
         {:ok, row} <- create_revision(article, content, staff) do
      {:ok, revision_view(row)}
    end
  end

  defp execute(ArticleRevision, :list_revisions, %{article_id: id} = args, staff) do
    with {:ok, _collection, article} <- lock_article(id, staff, :list_revisions) do
      page(ArticleRevision, args, [article_id: article.id], &revision_summary/1, [
        :id,
        :article_id,
        :revision_number,
        :status,
        :updated_at
      ])
    end
  end

  defp execute(ArticleRevision, action, %{id: id} = args, staff) do
    with {:ok, candidate} <- get(ArticleRevision, id),
         {:ok, collection, article} <- lock_article(candidate.article_id, staff, action),
         {:ok, %{article_id: article_id} = row} <- get(ArticleRevision, id, :for_update),
         true <- article_id == article.id do
      revision_action(collection, article, row, action, args, staff)
    else
      false -> {:error, :denied}
      error -> error
    end
  end

  defp execute(AuditEvent, :knowledge_history, %{target_kind: kind, id: id} = args, staff) do
    with :ok <- history_scope(kind, id, staff),
         {:ok, rows} <- read(AuditEvent, :knowledge_rows, args) do
      {:ok,
       Enum.map(
         rows,
         &Map.take(&1, [
           :id,
           :event,
           :reason_code,
           :actor_staff_id,
           :target_kind,
           :correlation_id,
           :occurred_at,
           :operational_before,
           :operational_after
         ])
       )}
    end
  end

  defp history_scope(:knowledge_collection, id, staff) do
    with {:ok, collection} <- get(KnowledgeCollection, id, :for_update),
         do: authorize_collection(collection, staff, :read_collection)
  end

  defp history_scope(:knowledge_article, id, staff) do
    with {:ok, _, _} <- lock_article(id, staff, :knowledge_history), do: :ok
  end

  defp history_scope(:knowledge_revision, id, staff) do
    with {:ok, row} <- get(ArticleRevision, id),
         do: history_scope(:knowledge_article, row.article_id, staff)
  end

  defp collection_action(collection, :read_collection, _args, staff),
    do:
      {:ok,
       Map.put(collection_view(collection), :action_hints, %{
         manage: :admin in staff.roles,
         create_draft: collection.status == :active and scoped?(collection.id, staff, @editor),
         import: collection.status == :active and scoped?(collection.id, staff, @editor),
         export: collection.status == :active and scoped?(collection.id, staff, @reviewer)
       })}

  defp collection_action(collection, action, args, staff)
       when action in [:preview_import, :apply_import, :export_articles] do
    with :ok <- active(collection), do: transfer(collection, action, args, staff)
  end

  defp collection_action(row, action, _args, staff) do
    with {:ok, status} <- collection_state(row.status, action),
         {:ok, result} <-
           change(row, %{status: status, security_epoch: row.security_epoch + 1}, action, staff) do
      {:ok, collection_view(result)}
    end
  end

  defp collection_state(:disabled, :enable), do: {:ok, :active}
  defp collection_state(:active, :disable), do: {:ok, :disabled}
  defp collection_state(:disabled, :retire), do: {:ok, :retired}
  defp collection_state(_, _), do: {:error, :invalid_transition}

  defp article_action(collection, article, :read_article, _args, staff) do
    {:ok,
     Map.put(article_view(article), :action_hints, %{
       create_draft:
         collection.status == :active and article.status == :active and
           scoped?(collection.id, staff, @editor),
       archive: article.status == :active and scoped?(collection.id, staff, @reviewer)
     })}
  end

  defp article_action(_collection, article, :archive, args, staff) do
    with :ok <- active(article),
         {:ok, revisions} <-
           read(ArticleRevision, :approved_revisions, %{article_id: article.id}, :for_update),
         :ok <- revoke_approved(revisions, staff),
         {:ok, archived} <-
           change(
             article,
             %{status: :archived, current_revision_id: nil, archived_at: DateTime.utc_now()},
             :archive,
             staff,
             args.reason
           ) do
      {:ok, article_view(archived)}
    end
  end

  defp revoke_approved(revisions, staff) do
    # Lock all revision rows first, then all affected embedding rows by ID,
    # even when the embedding UUIDs belong to different generations.
    with :ok <- invalidate_publication_rows(revisions) do
      Enum.reduce_while(revisions, :ok, fn row, :ok ->
        case change(
               row,
               Map.put(Publication.terminal_index(), :status, :revoked),
               :archive,
               staff,
               :obsolete
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp revision_action(collection, article, row, :read_revision, _args, staff) do
    with {:ok, active_index} <- index_rows(row.id, row.active_index_generation),
         {:ok, pending_index} <- index_rows(row.id, pending_generation(row)) do
      self_approval? = contributor?(row, staff)

      view =
        row
        |> revision_view()
        |> Map.drop([:created_by_id, :approved_by_id, :publication_requested_by_id])
        |> Map.merge(%{
          updated_at: row.updated_at,
          self_approval_required: self_approval?,
          index_status: locale_status(row, active_index, pending_index)
        })
        |> Map.merge(revision_controls(collection, article, row, staff))

      {:ok, view}
    end
  end

  defp revision_action(collection, article, row, action, args, staff)
       when action in [:request_publish, :retry_publication] do
    expected_status = if action == :request_publish, do: :approved, else: :publish_failed

    with :ok <- active(collection),
         :ok <- active(article),
         :ok <- same_snapshot(row, args),
         :ok <- review_snapshot(row),
         true <-
           row.status == expected_status and collection.audience == :public and
             row.content["sensitive"] != true and row.content["response_mode"] != "escalate_only",
         true <- args.expected_current_revision_id == article.current_revision_id,
         {:ok, deadline} <- Embedding.publication_deadline(row.content),
         {:ok, requested} <-
           change(
             row,
             %{
               status: :publishing,
               publication_requested_by_id: staff.id,
               publication_generation: row.publication_generation + 1,
               publication_collection_epoch: collection.security_epoch,
               expected_current_revision_id: article.current_revision_id,
               publication_deadline_at: deadline,
               publication_profile_id: EmbeddingProfile.id(),
               publication_reason: nil
             },
             action,
             staff,
             :source_verified
           ),
         {:ok, _} <-
           traverse(row.content["localized_content"], &queue_variant(requested, &1["locale"])) do
      {:ok, revision_view(requested)}
    else
      false -> {:error, :invalid_publication_request}
      error -> error
    end
  end

  defp revision_action(collection, article, row, :request_reindex, args, staff) do
    with :ok <- current_index(collection, article, row, args),
         {:ok, deadline} <- Embedding.publication_deadline(row.content),
         {:ok, requested} <-
           change(
             row,
             %{
               reindex_base_generation: row.active_index_generation,
               publication_requested_by_id: staff.id,
               publication_generation: row.publication_generation + 1,
               publication_collection_epoch: collection.security_epoch,
               expected_current_revision_id: row.id,
               publication_deadline_at: deadline,
               publication_profile_id: row.active_index_profile_id,
               publication_reason: nil
             },
             :request_reindex,
             staff,
             :source_verified
           ),
         {:ok, _} <-
           traverse(row.content["localized_content"], &queue_variant(requested, &1["locale"])) do
      {:ok, revision_view(requested)}
    end
  end

  defp revision_action(collection, article, row, :request_index_rollback, args, staff),
    do: request_index_rollback(collection, article, row, args, staff)

  defp revision_action(_collection, article, row, :revoke, args, staff) do
    with :ok <- active(article),
         :ok <- same_snapshot(row, args),
         true <- row.status in [:approved, :publishing, :publish_failed, :published],
         :ok <- invalidate_publication_rows([row]),
         {:ok, revoked} <-
           change(
             row,
             Map.put(Publication.terminal_index(), :status, :revoked),
             :revoke,
             staff,
             args.reason
           ),
         :ok <- clear_pointer(article, row) do
      {:ok, revision_view(revoked)}
    else
      false -> {:error, :invalid_transition}
      error -> error
    end
  end

  defp revision_action(collection, article, row, action, args, staff) do
    with :ok <- active(collection),
         :ok <- active(article),
         :ok <- same_snapshot(row, args),
         {:ok, attrs, reason} <- revision_transition(row, action, args, staff),
         {:ok, result} <- change(row, attrs, action, staff, reason) do
      {:ok, revision_view(result)}
    end
  end

  # These hints control affordances. The actions repeat their own guards under lock.
  defp revision_controls(collection, article, row, staff) do
    active? = collection.status == :active and article.status == :active
    editor? = scoped?(collection.id, staff, @editor)
    reviewer? = scoped?(collection.id, staff, @reviewer)
    draft_editor? = active? and editor? and row.status == :draft
    intact? = active? and row.status in [:draft, :in_review] and snapshot_intact?(row)
    can_edit? = draft_editor? and intact?
    reviewable? = Content.reviewable?(row.content)

    public? =
      collection.audience == :public and row.content["sensitive"] != true and
        row.content["response_mode"] != "escalate_only"

    index_args = %{
      expected_generation: row.active_index_generation,
      expected_index_epoch: row.index_epoch,
      expected_hash: row.content_hash
    }

    current_index? =
      reviewer? and row.status == :published and
        current_index(collection, article, row, index_args) == :ok

    publication_candidate? =
      active? and reviewer? and public? and row.status in [:approved, :publish_failed]

    deadline =
      if publication_candidate? or current_index?, do: Embedding.publication_deadline(row.content)

    can_publish? = match?({:ok, _}, deadline)

    %{
      action_hints: %{
        edit_draft: can_edit?,
        submit_review: can_edit? and reviewable?,
        withdraw: intact? and (editor? or reviewer?),
        request_changes: active? and reviewer? and row.status == :in_review,
        approve:
          active? and reviewer? and row.status == :in_review and row.content["sensitive"] != true,
        request_publish: publication_candidate? and row.status == :approved and can_publish?,
        retry_publication:
          publication_candidate? and row.status == :publish_failed and can_publish?,
        request_reindex: current_index? and can_publish?,
        # Rollback reuses a retained index without requesting embeddings.
        request_index_rollback:
          current_index? and Publication.rollback_available() == :ok and
            is_integer(row.retained_index_generation),
        revoke:
          article.status == :active and reviewer? and
            row.status in [:approved, :publishing, :publish_failed, :published]
      },
      review_blocker: if(draft_editor? and not reviewable?, do: :missing_source),
      publication_blocker:
        if(publication_candidate?, do: publication_blocker(deadline, row.content))
    }
  end

  # The deadline decides eligibility. Dates only explain a refusal to the reviewer.
  defp publication_blocker({:error, :stale_request}, content) do
    now = Embedding.now()

    cond do
      content_date_order(content["effective_from"], now) == :gt -> :not_yet_effective
      content_date_order(content["expires_at"], now) in [:lt, :eq] -> :expired
      true -> :unavailable
    end
  end

  defp publication_blocker({:error, _}, _), do: :unavailable
  defp publication_blocker({:ok, _}, _), do: nil

  defp content_date_order(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> DateTime.compare(date, now)
      {:error, _} -> nil
    end
  end

  defp content_date_order(_, _), do: nil

  defp current_index(collection, article, row, args) do
    with :ok <- active(collection),
         :ok <- active(article),
         true <-
           collection.audience == :public and row.status == :published and
             article.current_revision_id == row.id and not Publication.pending?(row) and
             row.active_index_profile_id == EmbeddingProfile.id() and
             row.active_index_generation == args.expected_generation and
             row.index_epoch == args.expected_index_epoch and
             row.content_hash == args.expected_hash,
         {:ok, _} <- Publication.approved_content(row, Embedding.now()) do
      :ok
    else
      false -> {:error, :stale_index}
      error -> error
    end
  end

  if Mix.env() == :test do
    defp append_rollback_request(collection, row, staff, now, expires) do
      deadline = DateTime.add(now, 60, :second)

      deadline =
        if not is_nil(expires) and DateTime.before?(expires, deadline),
          do: expires,
          else: deadline

      before = %{
        status: :published,
        index_generation: row.active_index_generation,
        index_epoch: row.index_epoch,
        content_hash: row.content_hash
      }

      attrs = %{
        actor_kind: :staff,
        actor_staff_id: staff.id,
        article_revision_target_id: row.id,
        target_kind: :knowledge_revision,
        event: :request_index_rollback,
        reason_code: :source_verified,
        correlation_id: Ash.UUIDv7.generate(),
        operational_before: before,
        operational_after:
          Map.merge(before, %{
            index_generation: row.retained_index_generation,
            collection_epoch: collection.security_epoch,
            content_profile_id: row.active_index_profile_id,
            deadline_us: DateTime.to_unix(deadline, :microsecond)
          })
      }

      storage(
        AuditEvent,
        :append_rollback_request,
        &Ash.create(AuditEvent, attrs, action: :append_rollback_request, actor: &1)
      )
    end
  end

  defp clear_pointer(%{current_revision_id: id} = article, %{id: id}) do
    with {:ok, _} <-
           storage(
             Article,
             :change_row,
             &Ash.update(article, %{current_revision_id: nil}, action: :change_row, actor: &1)
           ),
         do: :ok
  end

  defp clear_pointer(_, _), do: :ok

  defp queue_variant(revision, locale) do
    attrs = %{
      revision_id: revision.id,
      locale: locale,
      profile_id: revision.publication_profile_id,
      content_hash: revision.content_hash,
      generation: revision.publication_generation,
      deadline_at: revision.publication_deadline_at
    }

    with {:ok, row} <-
           storage(
             ArticleEmbedding,
             :insert_row,
             &Ash.create(ArticleEmbedding, attrs, action: :insert_row, actor: &1)
           ),
         {:ok, _} <- Oban.insert(IndexArticle.new(%{embedding_id: row.id})),
         {:ok, _} <-
           Oban.insert(
             RecoverIndexing.new(%{embedding_id: row.id}, scheduled_at: row.deadline_at)
           ) do
      {:ok, row}
    end
  end

  defp invalidate_publication_rows(revisions) do
    with {:ok, rows} <-
           read(
             ArticleEmbedding,
             :revision_rows,
             %{revision_ids: Enum.map(revisions, & &1.id)},
             :for_update
           ),
         {:ok, _} <- traverse(rows, &invalidate_variant/1) do
      :ok
    end
  end

  defp invalidate_variant(%{state: :invalidated} = row), do: {:ok, row}

  defp invalidate_variant(row) do
    storage(
      ArticleEmbedding,
      :change_row,
      &Ash.update(row, %{state: :invalidated, vector: nil, error_code: :stale_request},
        action: :change_row,
        actor: &1
      )
    )
  end

  defp same_snapshot(row, args) do
    if row.edit_version == args.expected_version and row.content_hash == args.expected_hash and
         snapshot_intact?(row),
       do: :ok,
       else: {:error, :stale_snapshot}
  end

  defp snapshot_intact?(row), do: row.content_hash == Content.hash(row.content)

  defp revision_transition(%{status: :draft} = row, :edit_draft, args, staff) do
    with {:ok, content} <- Content.parse(args.content) do
      {:ok,
       %{
         content: content,
         content_hash: Content.hash(content),
         edit_version: row.edit_version + 1,
         contributor_ids: record_contributor(row, staff)
       }, :local_editor}
    end
  end

  defp revision_transition(%{status: :draft} = row, :submit_review, _args, staff) do
    if Content.reviewable?(row.content) do
      {:ok,
       %{
         status: :in_review,
         review_hash: row.content_hash,
         edit_version: row.edit_version + 1,
         contributor_ids: record_contributor(row, staff)
       }, :local_editor}
    else
      {:error, :missing_source}
    end
  end

  defp revision_transition(%{status: :in_review} = row, :request_changes, args, _staff) do
    with :ok <- review_snapshot(row) do
      {:ok, %{status: :draft, review_hash: nil, edit_version: row.edit_version + 1}, args.reason}
    end
  end

  defp revision_transition(%{status: :in_review} = row, :approve, args, staff) do
    self? = contributor?(row, staff)

    with :ok <- review_snapshot(row),
         true <-
           Content.reviewable?(row.content) and args.source_verified and
             args.self_approval == self?,
         false <- row.content["sensitive"] == true do
      reason = if self?, do: :self_approval_attested, else: :source_verified

      {:ok, %{status: :approved, approved_by_id: staff.id, approved_at: DateTime.utc_now()},
       reason}
    else
      _ -> {:error, :approval_denied}
    end
  end

  defp revision_transition(%{status: status}, :withdraw, args, _staff)
       when status in [:draft, :in_review],
       do: {:ok, %{status: :withdrawn, review_hash: nil}, args.reason}

  defp revision_transition(_, _, _, _), do: {:error, :invalid_transition}

  # The revision stays locked through the transition and its audit write.
  defp contributor?(row, staff), do: staff.id in row.contributor_ids

  defp record_contributor(row, staff), do: Enum.uniq([staff.id | row.contributor_ids])

  defp review_snapshot(%{review_hash: hash, content_hash: hash}) when is_binary(hash), do: :ok
  defp review_snapshot(_), do: {:error, :stale_snapshot}

  defp active(%{status: :active}), do: :ok
  defp active(_), do: {:error, :inactive_scope}

  defp authorize_collection(_row, %{roles: roles}, action) when action in @collection_admin do
    permit(:admin in roles)
  end

  defp authorize_collection(row, staff, action) do
    roles =
      case required_role(action) do
        nil -> [@editor, @reviewer]
        role -> [role]
      end

    permit(
      (action == :read_collection and :admin in staff.roles) or
        Enum.any?(roles, &scoped?(row.id, staff, &1))
    )
  end

  defp editorial_scope?(id, staff),
    do: scoped?(id, staff, @editor) or scoped?(id, staff, @reviewer)

  defp scoped?(id, staff, role) do
    key = if role == @editor, do: :editors, else: :reviewers
    role in staff.roles and staff.id in List.wrap(get_in(fixture_scope(), [id, key]))
  end

  defp permit(true), do: :ok
  defp permit(false), do: {:error, :denied}

  # Membership is fixture-only until the owner approves a production mapping.
  if Mix.env() == :test do
    defp fixture_scope, do: Application.get_env(:voelgoed_ai, :knowledge_fixture_scope, %{})
  else
    defp fixture_scope, do: %{}
  end

  defp lock_article(id, staff, action) do
    with {:ok, candidate} <- get(Article, id),
         {:ok, collection} <- get(KnowledgeCollection, candidate.collection_id, :for_update),
         :ok <- authorize_collection(collection, staff, action),
         {:ok, %{collection_id: collection_id} = article} <- get(Article, id, :for_update),
         true <- collection_id == collection.id do
      {:ok, collection, article}
    else
      false -> {:error, :denied}
      error -> error
    end
  end

  defp create_article(collection, ref, slug, staff) do
    if Content.identifier?(ref) do
      insert(
        Article,
        %{collection_id: collection.id, article_ref: ref, slug: slug, owner_id: staff.id},
        :create_draft,
        staff,
        :local_editor
      )
    else
      {:error, :invalid_article_ref}
    end
  end

  defp create_revision(article, content, staff) do
    with {:ok, latest} <- one(ArticleRevision, :latest_revision, %{article_id: article.id}) do
      number = if latest, do: latest.revision_number + 1, else: 1

      attrs = %{
        article_id: article.id,
        created_by_id: staff.id,
        contributor_ids: [staff.id],
        revision_number: number,
        content: content,
        content_hash: Content.hash(content),
        content_hash_version: Content.version()
      }

      insert(ArticleRevision, attrs, :create_draft, staff, :local_editor)
    end
  end

  defp transfer(collection, :export_articles, %{article_ids: ids}, _staff) do
    with {:ok, articles} <- export_selection(collection.id, ids),
         true <- length(articles) <= Portable.max_articles(),
         {:ok, entries} <- traverse(articles, &export_entry/1),
         {:ok, document} <- Portable.encode(collection.slug, entries) do
      {:ok, %{document: document}}
    else
      false -> {:error, :export_limit}
      error -> error
    end
  end

  defp transfer(collection, action, args, staff) do
    with {:ok, entries} <- Portable.decode(args.document, collection.slug),
         selection = args[:new_revision_for],
         true <- is_nil(selection) or length(entries) == 1,
         {:ok, candidates} <- traverse(entries, &import_candidate(collection, &1)),
         {:ok, candidates} <- lock_candidates(candidates),
         {:ok, outcomes} <- traverse(candidates, &resolve_import(&1, selection)),
         {:ok, results} <- traverse(outcomes, &import_entry(action, collection, &1, staff)) do
      {:ok, %{articles: results}}
    else
      false -> {:error, :invalid_import_selection}
      error -> error
    end
  end

  defp export_selection(collection_id, []),
    do: read(Article, :for_export, %{collection_id: collection_id})

  defp export_selection(collection_id, ids) do
    with {:ok, rows} <-
           read(Article, :selected_for_export, %{collection_id: collection_id, ids: ids}),
         true <- length(rows) == length(ids) do
      {:ok, rows}
    else
      false -> {:error, :denied}
      error -> error
    end
  end

  if Mix.env() == :test do
    defp request_index_rollback(collection, article, row, args, staff) do
      now = Embedding.now()

      with :ok <- current_index(collection, article, row, args),
           true <- row.retained_index_generation == args.target_generation,
           {:ok, expires} <- Publication.approved_content(row, now),
           {:ok, request} <- append_rollback_request(collection, row, staff, now, expires),
           {:ok, _} <-
             Oban.insert(
               VoelgoedAi.Knowledge.Workers.FinalizePublication.new(%{
                 rollback_request_id: request.id
               })
             ) do
        {:ok, %{request_id: request.id}}
      else
        false -> {:error, :stale_index}
        error -> error
      end
    end
  else
    defp request_index_rollback(_, _, _, _, _), do: {:error, :rollback_disabled}
  end

  defp export_entry(article) do
    with {:ok, row} when is_struct(row, ArticleRevision) <-
           one(ArticleRevision, :latest_revision, %{article_id: article.id}),
         {:ok, content} <- Content.parse(row.content),
         true <- row.content_hash == Content.hash(content) do
      {:ok,
       %{
         "article_ref" => article.article_ref,
         "slug" => article.slug,
         "source_revision_number" => row.revision_number,
         "source_content_hash" => row.content_hash,
         "content" => content
       }}
    else
      _ -> {:error, :invalid_export_snapshot}
    end
  end

  defp import_candidate(collection, entry) do
    with {:ok, by_ref} <- one(Article, :by_ref, %{article_ref: entry["article_ref"]}),
         {:ok, by_slug} <-
           one(Article, :by_slug, %{collection_id: collection.id, slug: entry["slug"]}) do
      case {by_ref, by_slug} do
        {nil, nil} -> {:ok, {entry, nil}}
        {%{id: id, status: :active}, %{id: id}} -> {:ok, {entry, id}}
        _ -> {:error, :identity_collision}
      end
    end
  end

  defp lock_candidates(candidates) do
    ids = for {_entry, id} <- candidates, is_binary(id), do: id

    with {:ok, articles} <- traverse(Enum.sort(ids), &get(Article, &1, :for_update)) do
      by_id = Map.new(articles, &{&1.id, &1})
      {:ok, Enum.map(candidates, fn {entry, id} -> {entry, Map.get(by_id, id)} end)}
    end
  end

  defp resolve_import({entry, nil}, nil), do: {:ok, {:create, entry, nil}}

  defp resolve_import({entry, %{id: id, status: :active} = article}, selected) do
    with {:ok, latest} <- one(ArticleRevision, :latest_revision, %{article_id: id}) do
      hash = entry["source_content_hash"]

      case latest do
        %{status: :draft, content_hash: ^hash} ->
          {:ok, {:existing, entry, latest}}

        _ when id == selected ->
          {:ok, {:new_revision, entry, article}}

        _ ->
          {:error, :explicit_revision_required}
      end
    end
  end

  defp resolve_import(_, _), do: {:error, :invalid_import_selection}

  defp import_entry(:preview_import, _collection, {outcome, entry, _row}, _staff),
    do: {:ok, %{outcome: outcome, article_ref: entry["article_ref"]}}

  defp import_entry(:apply_import, collection, {:create, entry, _}, staff) do
    with {:ok, article} <- create_article(collection, entry["article_ref"], entry["slug"], staff),
         {:ok, row} <- create_revision(article, entry["content"], staff) do
      import_result(:create, entry, row)
    end
  end

  defp import_entry(:apply_import, _collection, {:new_revision, entry, article}, staff) do
    with {:ok, row} <- create_revision(article, entry["content"], staff),
         do: import_result(:new_revision, entry, row)
  end

  defp import_entry(:apply_import, _collection, {:existing, entry, row}, _staff),
    do: import_result(:existing, entry, row)

  defp import_result(outcome, entry, row),
    do: {:ok, %{outcome: outcome, article_ref: entry["article_ref"], revision_id: row.id}}

  defp traverse(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, found} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | found]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp page(resource, args, filters, project, fields \\ nil) do
    storage(resource, :editorial_page, fn actor ->
      query =
        resource
        |> Ash.Query.for_read(:editorial_page, %{}, actor: actor)
        |> Ash.Query.filter(^filters)
        |> Ash.Query.sort(:id)
        |> Ash.Query.limit(args.limit + 1)

      after_id = Map.get(args, :after_id)
      query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query
      query = if fields, do: Ash.Query.select(query, fields), else: query

      with {:ok, rows} <- Ash.read(query) do
        {items, extra} = Enum.split(rows, args.limit)
        next_after_id = if extra != [], do: List.last(items).id
        {:ok, %{items: Enum.map(items, project), next_after_id: next_after_id}}
      end
    end)
  end

  defp revision_summary(row),
    do: Map.take(row, [:id, :article_id, :revision_number, :status, :updated_at])

  defp pending_generation(row) do
    if Publication.pending?(row) or not is_nil(row.publication_reason),
      do: row.publication_generation
  end

  defp index_rows(_id, nil), do: {:ok, []}

  defp index_rows(id, generation) do
    storage(ArticleEmbedding, :generation_rows, fn actor ->
      ArticleEmbedding
      |> Ash.Query.for_read(:generation_rows, %{revision_id: id, generation: generation},
        actor: actor
      )
      |> Ash.Query.select([:locale, :state])
      |> Ash.read()
    end)
  end

  defp locale_status(row, active, pending) do
    present = Enum.map(row.content["localized_content"], & &1["locale"])

    Map.new(["af-ZA", "en-ZA"], fn locale ->
      status =
        if locale in present do
          %{
            active:
              if(Enum.any?(active, &(&1.locale == locale and &1.state == :ready)),
                do: :active,
                else: :not_indexed
              ),
            pending:
              pending_status(Enum.find(pending, &(&1.locale == locale)), row.publication_reason)
          }
        else
          %{active: :absent, pending: :absent}
        end

      {locale, status}
    end)
  end

  defp pending_status(%{state: :failed}, _reason), do: :failed
  defp pending_status(_row, reason) when not is_nil(reason), do: :failed
  defp pending_status(%{state: :ready}, _reason), do: :ready_to_activate
  defp pending_status(%{state: state}, _reason) when state in [:queued, :running], do: :pending
  defp pending_status(_, _), do: :not_indexed

  defp get(resource, id, lock \\ nil) do
    case one(resource, :storage_row, %{id: id}, lock) do
      {:ok, nil} -> {:error, :denied}
      result -> result
    end
  end

  defp one(resource, action, args, lock \\ nil) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      Ash.read_one(if lock, do: Ash.Query.lock(query, lock), else: query)
    end)
  end

  defp read(resource, action, args, lock \\ nil) do
    storage(resource, action, fn actor ->
      query = Ash.Query.for_read(resource, action, args, actor: actor)
      Ash.read(if lock, do: Ash.Query.lock(query, lock), else: query)
    end)
  end

  defp insert(resource, attrs, event, staff, reason \\ :local_admin) do
    with {:ok, row} <-
           storage(
             resource,
             :insert_row,
             &Ash.create(resource, attrs, action: :insert_row, actor: &1)
           ),
         {:ok, _} <- audit(nil, row, event, staff, reason) do
      {:ok, row}
    end
  end

  defp change(%resource{} = row, attrs, event, staff, reason \\ :local_admin) do
    with {:ok, updated} <-
           storage(resource, :change_row, &Ash.update(row, attrs, action: :change_row, actor: &1)),
         {:ok, _} <- audit(row, updated, event, staff, reason) do
      {:ok, updated}
    end
  end

  defp audit(before, row, event, staff, reason) do
    {kind, foreign_key} = audit_target(row)

    attrs = %{
      foreign_key => row.id,
      target_kind: kind,
      actor_kind: :staff,
      actor_staff_id: staff.id,
      event: event,
      reason_code: reason,
      correlation_id: Ash.UUIDv7.generate(),
      operational_before: audit_state(before),
      operational_after: audit_state(row)
    }

    storage(AuditEvent, :append_knowledge, fn actor ->
      Ash.create(AuditEvent, audit_attrs(attrs), action: :append_knowledge, actor: actor)
    end)
  end

  if Mix.env() == :test do
    defp audit_attrs(attrs) do
      if Process.get({__MODULE__, :reject_audit}) == attrs.event,
        do: Map.delete(attrs, :actor_staff_id),
        else: attrs
    end
  else
    defp audit_attrs(attrs), do: attrs
  end

  defp audit_target(row) when is_struct(row, KnowledgeCollection),
    do: {:knowledge_collection, :knowledge_collection_target_id}

  defp audit_target(row) when is_struct(row, Article),
    do: {:knowledge_article, :article_target_id}

  defp audit_target(row) when is_struct(row, ArticleRevision),
    do: {:knowledge_revision, :article_revision_target_id}

  defp audit_state(nil), do: nil

  defp audit_state(row),
    do: Map.take(row, [:status, :security_epoch, :revision_number, :edit_version, :content_hash])

  defp collection_view(row),
    do: Map.take(row, [:id, :slug, :name, :status, :audience, :security_epoch])

  defp article_view(row),
    do:
      Map.take(row, [
        :id,
        :article_ref,
        :slug,
        :status,
        :collection_id,
        :current_revision_id,
        :archived_at
      ])

  defp revision_view(row),
    do:
      Map.take(row, [
        :id,
        :article_id,
        :revision_number,
        :edit_version,
        :status,
        :content,
        :content_hash,
        :content_hash_version,
        :review_hash,
        :created_by_id,
        :approved_at,
        :approved_by_id,
        :publication_generation,
        :publication_requested_by_id,
        :publication_deadline_at,
        :publication_reason,
        :published_at,
        :active_index_generation,
        :active_index_profile_id,
        :index_epoch,
        :retained_index_generation,
        :reindex_base_generation
      ])

  # Like support configuration, only the owning transaction can mint a token.
  defp storage(resource, action, operation) do
    key = {__MODULE__, :storage}
    ref = make_ref()
    previous = Process.put(key, {ref, resource, action})

    try do
      operation.(%Storage{ref: ref})
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end

  defp result({:error, reason}) when is_atom(reason), do: {:error, Atom.to_string(reason)}
  defp result({:error, _}), do: {:error, "editorial storage failed"}
  defp result(success), do: success
end
