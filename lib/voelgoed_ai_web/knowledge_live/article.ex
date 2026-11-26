defmodule VoelgoedAiWeb.KnowledgeLive.Article do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision}
  alias VoelgoedAiWeb.KnowledgeLive.Auth

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Auth.load(socket, params)}

  def read_page(:show, %{"id" => id} = params, actor) do
    with {:ok, article} <- run(Article, :read_article, %{id: id}, actor),
         {:ok, list} <-
           run(ArticleRevision, :list_revisions, Map.put(cursor(params), "article_id", id), actor) do
      {:ok, %{article: article, list: list, cursor: params["after_id"]}}
    end
  end

  @impl true
  def render(%{status: :ready} = assigns) do
    ~H"""
    <.sheet title={@page.article.slug} back={"/staff/knowledge/collections/#{@page.article.collection_id}"} back_text="Collection">
      <dl class="metadata">
        <div><dt>Reference</dt><dd>{@page.article.article_ref}</dd></div>
        <div><dt>State</dt><dd>{label(@page.article.status)}</dd></div>
        <div>
          <dt>Current revision</dt>
          <dd>
            <a :if={@page.article.current_revision_id} href={revision_path(@page.article.id, @page.article.current_revision_id)}>Open current revision</a>
            <span :if={!@page.article.current_revision_id}>None published</span>
          </dd>
        </div>
      </dl>
      <h2 class="section-heading">Revisions</h2>
      <p :if={@page.list.items == []} class="notice">This page has no revisions.</p>
      <table :if={@page.list.items != []} class="revisions" aria-label="Revisions">
        <thead><tr><th scope="col">Revision</th><th scope="col">Review state</th><th scope="col">Updated</th></tr></thead>
        <tbody>
          <tr :for={row <- @page.list.items}>
            <th scope="row"><a href={revision_path(@page.article.id, row.id)}>Revision {row.revision_number}</a></th>
            <td>{label(row.status)}</td>
            <td>{timestamp(row.updated_at)}</td>
          </tr>
        </tbody>
      </table>
      <.pagination page={@page.list} path={"/staff/knowledge/articles/#{@page.article.id}"} cursor={@page.cursor} />
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading article…</p>|

  defp revision_path(article_id, revision_id),
    do: "/staff/knowledge/articles/#{article_id}/revisions/#{revision_id}"
end
