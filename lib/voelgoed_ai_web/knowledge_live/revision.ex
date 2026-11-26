defmodule VoelgoedAiWeb.KnowledgeLive.Revision do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components
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

  @impl true
  def render(%{status: :ready, page: page} = assigns) do
    assigns = assign(assigns, :revision, page.revision)

    ~H"""
    <.sheet title={"Revision #{@revision.revision_number}"} back={"/staff/knowledge/articles/#{@page.article.id}"} back_text={@page.article.slug}>
      <:tools>
        <button type="button" phx-click="refresh" phx-disable-with="Refreshing…">Refresh status</button>
      </:tools>
      <dl class="metadata" aria-live="polite">
        <div><dt>Review state</dt><dd>{label(@revision.status)}</dd></div>
        <div><dt>Current revision</dt><dd>{if @page.article.current_revision_id == @revision.id, do: "Yes", else: "No"}</dd></div>
        <div><dt>Last updated</dt><dd>{timestamp(@revision.updated_at)}</dd></div>
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
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading revision…</p>|
end
