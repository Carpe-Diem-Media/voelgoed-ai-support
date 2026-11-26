defmodule VoelgoedAiWeb.KnowledgeLive.Index do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components
  alias VoelgoedAi.Knowledge.{Article, KnowledgeCollection}
  alias VoelgoedAiWeb.KnowledgeLive.Auth

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Auth.load(socket, params)}

  def read_page(:index, params, actor) do
    with {:ok, list} <- run(KnowledgeCollection, :list_collections, cursor(params), actor) do
      {:ok, %{list: list, cursor: params["after_id"]}}
    end
  end

  def read_page(:collection, %{"id" => id} = params, actor) do
    with {:ok, collection} <- run(KnowledgeCollection, :read_collection, %{id: id}, actor) do
      list = run(Article, :list_articles, Map.put(cursor(params), "collection_id", id), actor)
      {:ok, %{collection: collection, articles: list, cursor: params["after_id"]}}
    end
  end

  @impl true
  def render(%{status: :ready, live_action: :index} = assigns) do
    ~H"""
    <.sheet title="Knowledge collections">
      <p :if={@page.list.items == []} class="notice">No collections are available to you.</p>
      <table :if={@page.list.items != []} class="collections" aria-label="Knowledge collections">
        <thead>
          <tr><th scope="col">Collection</th><th scope="col">Audience</th><th scope="col">State</th></tr>
        </thead>
        <tbody>
          <tr :for={row <- @page.list.items}>
            <th scope="row"><a href={"/staff/knowledge/collections/#{row.id}"}>{row.name}</a></th>
            <td>{label(row.audience)}</td>
            <td>{label(row.status)}</td>
          </tr>
        </tbody>
      </table>
      <.pagination page={@page.list} path="/staff/knowledge" cursor={@page.cursor} />
    </.sheet>
    """
  end

  def render(%{status: :ready, live_action: :collection} = assigns) do
    ~H"""
    <.sheet title={@page.collection.name} back="/staff/knowledge" back_text="Collections">
      <dl class="metadata">
        <div><dt>Audience</dt><dd>{label(@page.collection.audience)}</dd></div>
        <div><dt>State</dt><dd>{label(@page.collection.status)}</dd></div>
      </dl>
      <.articles result={@page.articles} path={"/staff/knowledge/collections/#{@page.collection.id}"} cursor={@page.cursor} />
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading collections…</p>|

  defp articles(%{result: {:ok, page}} = assigns) do
    assigns = assign(assigns, :articles, page)

    ~H"""
    <h2 class="section-heading">Articles</h2>
    <p :if={@articles.items == []} class="notice">This page has no articles.</p>
    <table :if={@articles.items != []} aria-label="Articles">
      <thead><tr><th scope="col">Article</th><th scope="col">State</th></tr></thead>
      <tbody>
        <tr :for={row <- @articles.items}>
          <th scope="row"><a href={"/staff/knowledge/articles/#{row.id}"}>{row.slug}</a></th>
          <td>{label(row.status)}</td>
        </tr>
      </tbody>
    </table>
    <.pagination page={@articles} path={@path} cursor={@cursor} />
    """
  end

  defp articles(assigns) do
    ~H"""
    <p class="notice">Articles are unavailable. <a href={@path}>Reload collection</a></p>
    """
  end
end
