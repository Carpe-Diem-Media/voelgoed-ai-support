defmodule VoelgoedAiWeb.KnowledgeLive.Index do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components
  import VoelgoedAiWeb.KnowledgeLive.Forms
  alias VoelgoedAi.Accounts.StaffAccess
  alias VoelgoedAi.Intelligence.AssistantRevision
  alias VoelgoedAi.Knowledge.{Article, KnowledgeCollection}
  alias VoelgoedAiWeb.KnowledgeLive.Auth

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Auth.load(socket, params)}

  def read_page(:index, params, actor) do
    with {:ok, list} <- run(KnowledgeCollection, :list_collections, cursor(params), actor) do
      admin? = StaffAccess.with_current(actor, :admin, fn _ -> {:ok, true} end) == {:ok, true}
      {:ok, %{list: list, cursor: params["after_id"], admin?: admin?}}
    end
  end

  def read_page(:collection, %{"id" => id} = params, actor) do
    with {:ok, collection} <- run(KnowledgeCollection, :read_collection, %{id: id}, actor) do
      list = run(Article, :list_articles, Map.put(cursor(params), "collection_id", id), actor)
      {:ok, %{collection: collection, articles: list, cursor: params["after_id"]}}
    end
  end

  @collection_changes [{"enable", :enable}, {"disable", :disable}, {"retire", :retire}]
  @grant_changes [
    {"grant_collection", :grant_collection},
    {"remove_collection", :remove_collection}
  ]

  @impl true
  def handle_event("create_collection", params, %{assigns: %{live_action: :index}} = socket) do
    fields = Map.take(params, ["name", "slug", "audience"])

    with true <- submitted?(params, socket) and socket.assigns.page.admin?,
         {:ok, row} <- run(KnowledgeCollection, :create, fields, Auth.actor(socket)) do
      {:noreply, redirect(socket, to: "/staff/knowledge/collections/#{row.id}")}
    else
      _ ->
        {:noreply,
         assign(socket,
           form_data: fields,
           notice: "Check the collection name, slug and audience."
         )}
    end
  end

  def handle_event(
        "find_assistant_draft",
        params,
        %{assigns: %{live_action: :collection}} = socket
      ) do
    collection = socket.assigns.page.collection

    with true <- submitted?(params, socket) and collection.action_hints.manage,
         {:ok, %{status: :draft} = draft} <-
           run(
             AssistantRevision,
             :read_configuration,
             %{id: params["draft_id"]},
             Auth.actor(socket)
           ) do
      {:noreply, assign(socket, grant: draft, form_token: Auth.token(), notice: nil)}
    else
      _ ->
        {:noreply,
         assign(socket,
           grant: nil,
           form_token: Auth.token(),
           notice: "That assistant draft is unavailable."
         )}
    end
  end

  def handle_event(event, params, %{assigns: %{live_action: :collection}} = socket) do
    collection = socket.assigns.page.collection

    with true <-
           submitted?(params, socket) and confirmed?(params) and collection.action_hints.manage,
         {:ok, _} <- change_collection(event, collection, socket) do
      {:noreply, socket |> Auth.reload() |> assign(grant: nil, notice: "Collection updated.")}
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :notice,
           "The collection could not be updated. Reload to confirm its current state."
         )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp change_collection(event, collection, socket) do
    case List.keyfind(@collection_changes, event, 0) do
      {_, action} ->
        if action in collection_actions(collection.status) do
          run(KnowledgeCollection, action, %{id: collection.id}, Auth.actor(socket))
        end

      nil ->
        with {_, action} <- List.keyfind(@grant_changes, event, 0),
             %{id: id} <- socket.assigns.grant do
          run(
            AssistantRevision,
            action,
            %{id: id, collection_id: collection.id},
            Auth.actor(socket)
          )
        end
    end
  end

  defp collection_actions(:disabled), do: [:enable, :retire]
  defp collection_actions(:active), do: [:disable]
  defp collection_actions(_), do: []

  @impl true
  def render(%{status: :ready, live_action: :index} = assigns) do
    ~H"""
    <.sheet title="Knowledge collections">
      <.feedback id="collection-create-feedback" notice={@notice} />
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
      <.staff_form :if={@page.admin?} id="collection-create" event="create_collection" token={@form_token} connected={@connected}>
        <h2>Create collection</h2>
        <label class="field" for="collection-name">Name
          <input id="collection-name" name="name" value={@form_data["name"]} maxlength="120" required />
        </label>
        <label class="field" for="collection-slug">Slug
          <input id="collection-slug" name="slug" value={@form_data["slug"]} maxlength="64" required />
        </label>
        <label class="field" for="collection-audience">Audience
          <select id="collection-audience" name="audience" required>
            <option value="">Choose an audience</option>
            <option value="public" selected={@form_data["audience"] == "public"}>Public</option>
            <option value="internal" selected={@form_data["audience"] == "internal"}>Internal</option>
          </select>
        </label>
        <button type="submit" phx-disable-with="Creating…">Create collection</button>
      </.staff_form>
    </.sheet>
    """
  end

  def render(%{status: :ready, live_action: :collection} = assigns) do
    ~H"""
    <.sheet title={@page.collection.name} back="/staff/knowledge" back_text="Collections">
      <.feedback id="collection-feedback" notice={@notice} />
      <dl class="metadata">
        <div><dt>Audience</dt><dd>{label(@page.collection.audience)}</dd></div>
        <div><dt>State</dt><dd>{label(@page.collection.status)}</dd></div>
      </dl>
      <.articles result={@page.articles} path={"/staff/knowledge/collections/#{@page.collection.id}"} cursor={@page.cursor} />
      <div :if={@page.collection.action_hints.create_draft} class="form-links">
        <a href={"/staff/knowledge/collections/#{@page.collection.id}/articles/new"}>New article</a>
        <a href={"/staff/knowledge/import?collection_id=#{@page.collection.id}"}>Import drafts</a>
      </div>
      <.export :if={@page.collection.action_hints.export} collection={@page.collection} result={@page.articles} connected={@connected} />
      <section :if={@page.collection.action_hints.manage} aria-labelledby="collection-manage">
        <h2 id="collection-manage" class="section-heading">Manage collection</h2>
        <.decision :for={action <- collection_actions(@page.collection.status)}
          id={"collection-#{action}"} event={Atom.to_string(action)} title={"#{label(action)} collection"}
          token={@form_token} connected={@connected} />
        <p :if={@page.collection.status == :retired} class="notice">This collection has been retired.</p>
        <.staff_form id="grant-lookup" event="find_assistant_draft" token={@form_token} connected={@connected}>
          <label class="field" for="assistant-draft-id">Assistant draft ID
            <input id="assistant-draft-id" name="draft_id" maxlength="36" required />
          </label>
          <button type="submit" phx-disable-with="Finding…">Find assistant draft</button>
        </.staff_form>
        <p :if={@grant} class="notice">Assistant revision {@grant.revision_number} ({@grant.id})</p>
        <.decision :if={@grant && @page.collection.status == :active} id="grant-collection"
          event="grant_collection" title="Grant collection to this draft" token={@form_token} connected={@connected} />
        <.decision :if={@grant} id="remove-collection" event="remove_collection"
          title="Remove collection from this draft" token={@form_token} connected={@connected} />
      </section>
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading collections…</p>|

  defp export(%{result: {:ok, page}} = assigns) do
    assigns = assign(assigns, :selectable, Enum.filter(page.items, &(&1.status == :active)))

    ~H"""
    <section aria-labelledby="export-heading">
      <h2 id="export-heading" class="section-heading">Export articles</h2>
      <p :if={@selectable == []} class="notice">There are no active articles to export on this page.</p>
      <form :if={@selectable != []} id="export-articles" class="editorial-form" phx-hook="StaffForm"
        action={"/staff/knowledge/collections/#{@collection.id}/export"} method="post">
        <fieldset disabled={!@connected} aria-describedby="export-limit">
          <legend>Choose articles</legend>
          <p id="export-limit">Select 1 to 10 articles on this page. The latest portable content can include drafts.</p>
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label :for={row <- @selectable} class="check">
            <input type="checkbox" name="article_ids[]" value={row.id} />
            {row.slug}
          </label>
          <button type="submit">Download JSON</button>
        </fieldset>
      </form>
    </section>
    """
  end

  defp export(assigns), do: ~H""

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
