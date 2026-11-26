defmodule VoelgoedAiWeb.KnowledgeLive.Revision do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components
  import VoelgoedAiWeb.KnowledgeLive.Forms
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision}
  alias VoelgoedAiWeb.KnowledgeLive.Auth

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Auth.load(socket, params)}

  def read_page(:show, %{"id" => id, "revision_id" => revision_id}, actor) do
    with {:ok, article} <- run(Article, :read_article, %{id: id}, actor),
         {:ok, %{article_id: ^id} = revision} <-
           run(ArticleRevision, :read_revision, %{id: revision_id}, actor) do
      {:ok, %{article: article, revision: revision}}
    else
      _ -> {:error, :denied}
    end
  end

  @decisions [
    {:submit_review, "Submit for review", []},
    {:withdraw, "Withdraw revision", [:withdrawn_by_staff]},
    {:request_changes, "Request changes", [:source_correction, :content_correction]},
    {:approve, "Approve revision", []},
    {:request_publish, "Request publication", []},
    {:retry_publication, "Retry publication", []},
    {:request_reindex, "Request reindex", []},
    {:request_index_rollback, "Request index rollback", []},
    {:revoke, "Revoke revision", [:obsolete]}
  ]

  @impl true
  def handle_event(event, params, socket) do
    case Enum.find(@decisions, fn {action, _, _} -> Atom.to_string(action) == event end) do
      {action, _, reasons} -> {:noreply, decide(socket, action, reasons, params)}
      nil -> {:noreply, socket}
    end
  end

  defp decide(socket, action, reasons, params) do
    page = socket.assigns.page
    row = page.revision

    with true <- submitted?(params, socket),
         true <- row.action_hints[action],
         {:ok, confirmation} <- confirmation(action, reasons, params),
         args = Map.merge(snapshot(page, action), confirmation),
         {:ok, _} <- run(ArticleRevision, action, args, Auth.actor(socket)) do
      socket |> Auth.reload() |> assign(:notice, "Revision updated.")
    else
      _ ->
        assign(
          socket,
          :notice,
          "The action could not be completed. Reload to confirm the current revision."
        )
    end
  end

  # The web workflow only accepts independent verification. The action computes
  # contributor status against all contributors under the revision lock.
  defp confirmation(:approve, [], %{"source_verified" => "true"}),
    do: {:ok, %{source_verified: true, self_approval: false}}

  defp confirmation(:approve, _, _), do: :error

  defp confirmation(_, reasons, params) do
    reason = Enum.find(reasons, &(Atom.to_string(&1) == params["reason"]))

    if confirmed?(params) and (reasons == [] or reason),
      do: {:ok, if(reason, do: %{reason: reason}, else: %{})},
      else: :error
  end

  defp snapshot(%{revision: row}, action)
       when action in [:request_reindex, :request_index_rollback] do
    args = %{
      id: row.id,
      expected_hash: row.content_hash,
      expected_generation: row.active_index_generation,
      expected_index_epoch: row.index_epoch
    }

    if action == :request_index_rollback,
      do: Map.put(args, :target_generation, row.retained_index_generation),
      else: args
  end

  defp snapshot(%{article: article, revision: row}, action) do
    args = %{id: row.id, expected_hash: row.content_hash, expected_version: row.edit_version}

    if action in [:request_publish, :retry_publication],
      do: Map.put(args, :expected_current_revision_id, article.current_revision_id),
      else: args
  end

  defp show_decision?(row, :approve),
    do: row.action_hints.approve and not row.self_approval_required

  defp show_decision?(row, action), do: row.action_hints[action]

  defp content_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> timestamp(datetime)
      _ -> timestamp(nil)
    end
  end

  defp decision_id(action), do: action |> Atom.to_string() |> String.replace("_", "-")

  @impl true
  def render(%{status: :ready, page: page} = assigns) do
    assigns = assign(assigns, revision: page.revision, decisions: @decisions)

    ~H"""
    <.sheet title={"Revision #{@revision.revision_number}"} back={"/staff/knowledge/articles/#{@page.article.id}"} back_text={@page.article.slug}>
      <:tools>
        <button type="button" phx-click="refresh" phx-disable-with="Refreshing…">Refresh status</button>
      </:tools>
      <.feedback id="revision-feedback" notice={@notice} />
      <dl class="metadata" aria-live="polite">
        <div><dt>Review state</dt><dd>{label(@revision.status)}</dd></div>
        <div><dt>Current revision</dt><dd>{if @page.article.current_revision_id == @revision.id, do: "Yes", else: "No"}</dd></div>
        <div><dt>Last updated</dt><dd>{timestamp(@revision.updated_at)}</dd></div>
        <div><dt>Effective from</dt><dd>{content_date(@revision.content["effective_from"])}</dd></div>
        <div :if={@revision.content["expires_at"]}><dt>Expires</dt><dd>{content_date(@revision.content["expires_at"])}</dd></div>
        <div :if={@revision.approved_at}><dt>Approved</dt><dd>{timestamp(@revision.approved_at)}</dd></div>
        <div :if={@revision.published_at}><dt>Published</dt><dd>{timestamp(@revision.published_at)}</dd></div>
        <div :if={@revision.publication_reason}><dt>Index issue</dt><dd>{label(@revision.publication_reason)}</dd></div>
      </dl>
      <h2 class="section-heading">Language indexing</h2>
      <table aria-label="Language indexing" aria-live="polite">
        <thead><tr><th scope="col">Locale</th><th scope="col">Active index</th><th scope="col">Pending index</th></tr></thead>
        <tbody>
          <tr :for={locale <- ["af-ZA", "en-ZA"]}>
            <th scope="row">{locale}</th>
            <td>{index_state(@revision.index_status[locale].active)}</td>
            <td>{index_state(@revision.index_status[locale].pending)}</td>
          </tr>
        </tbody>
      </table>
      <section :for={variant <- @revision.content["localized_content"]} class="variant" lang={variant["locale"]}>
        <p class="locale">{variant["locale"]}</p>
        <h2>{variant["title"]}</h2>
        <p class="answer">{variant["approved_answer"]}</p>
        <ol :if={variant["steps"] not in [nil, []]}>
          <li :for={step <- variant["steps"]}>{step}</li>
        </ol>
      </section>
      <section :if={Enum.any?(@decisions, fn {action, _, _} -> show_decision?(@revision, action) end) or @revision.action_hints.edit_draft} aria-labelledby="revision-actions">
        <h2 id="revision-actions" class="section-heading">Editorial actions</h2>
        <div :if={@revision.action_hints.edit_draft} class="form-links">
          <a href={"/staff/knowledge/articles/#{@page.article.id}/revisions/#{@revision.id}/edit"}>Edit draft</a>
        </div>
        <.decision :for={{action, title, reasons} <- @decisions}
          :if={show_decision?(@revision, action)}
          id={decision_id(action)} event={Atom.to_string(action)} title={title}
          reasons={reasons} approval={action == :approve} token={@form_token} connected={@connected} />
      </section>
      <p :if={@revision.action_hints.approve and @revision.self_approval_required} class="notice">
        A reviewer who did not contribute to this revision must approve it here.
      </p>
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading revision…</p>|
end
