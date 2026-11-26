defmodule VoelgoedAiWeb.KnowledgeLive.Import do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.{Components, Forms}
  alias VoelgoedAi.Knowledge.{Article, KnowledgeCollection}
  alias VoelgoedAiWeb.KnowledgeLive.Auth

  @file_limit 262_144
  @upload_error "Choose one JSON file of at most 262,144 bytes."
  @import_error "The document could not be imported. Check the file and preview it again."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     allow_upload(socket, :document,
       accept: [".json", "application/json"],
       auto_upload: true,
       max_entries: 1,
       max_file_size: @file_limit,
       progress: &upload_progress/3
     )}
  end

  @impl true
  def handle_params(params, _, socket),
    do: {:noreply, socket |> clear_document() |> Auth.load(params)}

  def read_page(:show, %{"collection_id" => id}, actor) do
    case run(KnowledgeCollection, :read_collection, %{id: id}, actor) do
      {:ok, %{action_hints: %{import: true}} = collection} -> {:ok, %{collection: collection}}
      _ -> {:error, :denied}
    end
  end

  def read_page(:show, _, _actor), do: {:error, :denied}

  @impl true
  def handle_event("upload_changed", _params, socket),
    do: {:noreply, clear_document(socket)}

  def handle_event("cancel_import", _, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.document.entries, socket, fn entry, acc ->
        cancel_upload(acc, :document, entry.ref)
      end)

    {:noreply, clear_document(socket)}
  end

  def handle_event("preview_import", params, socket) do
    with true <- submitted?(params, socket),
         {[_entry], []} <- uploaded_entries(socket, :document),
         false <- upload_error?(socket.assigns.uploads.document),
         [{:ok, bytes}] <- consume_uploaded_entries(socket, :document, &read_upload/2) do
      {:noreply, socket |> clear_document() |> preview(bytes, nil)}
    else
      _ -> {:noreply, socket |> clear_document() |> assign(:notice, @upload_error)}
    end
  end

  def handle_event("preview_revision", %{"article_id" => id} = params, socket) do
    collection_id = socket.assigns.page.collection.id

    with true <- submitted?(params, socket),
         %{document: bytes} when is_binary(bytes) <- socket.private[:import_document],
         {:ok, %{collection_id: ^collection_id, status: :active}} <-
           run(Article, :read_article, %{id: id}, Auth.actor(socket)) do
      {:noreply, preview(socket, bytes, id)}
    else
      _ -> {:noreply, socket |> clear_document() |> assign(:notice, @import_error)}
    end
  end

  def handle_event("apply_import", params, socket) do
    with true <- submitted?(params, socket) and confirmed?(params),
         %{articles: [_ | _]} <- socket.assigns.preview,
         %{document: _, new_revision_for: _} = args <- socket.private[:import_document] do
      result = run(KnowledgeCollection, :apply_import, args, Auth.actor(socket))
      socket = clear_document(socket)

      case result do
        {:ok, %{articles: articles}} ->
          {:noreply, assign(socket, import_result: articles, notice: "Draft import complete.")}

        _ ->
          {:noreply, assign(socket, :notice, @import_error)}
      end
    else
      _ ->
        {:noreply,
         socket |> clear_document() |> assign(:notice, "Preview a file before applying it.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp upload_progress(:document, _entry, socket), do: {:noreply, Auth.recheck(socket)}

  defp preview(socket, bytes, selection) do
    args = %{id: socket.assigns.page.collection.id, document: bytes, new_revision_for: selection}

    socket =
      assign(socket, form_token: Auth.token(), preview: nil, import_result: nil, notice: nil)

    case run(KnowledgeCollection, :preview_import, args, Auth.actor(socket)) do
      {:ok, %{articles: _} = preview} ->
        socket |> put_private(:import_document, args) |> assign(:preview, preview)

      {:error, error} ->
        if explicit_revision_required?(error) and is_nil(selection) do
          socket |> put_private(:import_document, args) |> assign(:preview, :select_article)
        else
          socket |> clear_document() |> assign(:notice, @import_error)
        end
    end
  end

  defp explicit_revision_required?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &explicit_revision_required?/1)

  defp explicit_revision_required?(%{error: "explicit_revision_required"}), do: true
  defp explicit_revision_required?(%{message: "explicit_revision_required"}), do: true
  defp explicit_revision_required?("explicit_revision_required"), do: true
  defp explicit_revision_required?(_), do: false

  defp read_upload(%{path: path}, _) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) in 1..@file_limit -> {:ok, {:ok, bytes}}
      _ -> {:ok, :invalid_file}
    end
  end

  defp clear_document(socket) do
    socket
    |> put_private(:import_document, nil)
    |> assign(preview: nil, import_result: nil, notice: nil)
  end

  defp upload_error?(upload) do
    upload_errors(upload) != [] or Enum.any?(upload.entries, &(upload_errors(upload, &1) != []))
  end

  @impl true
  def render(%{status: :ready} = assigns) do
    assigns = assign(assigns, :upload_error, @upload_error)

    ~H"""
    <.sheet title="Import drafts" back={"/staff/knowledge/collections/#{@page.collection.id}"} back_text={@page.collection.name}>
      <.feedback id="import-feedback" notice={@notice} />
      <.staff_form id="import-upload" event="preview_import" change="upload_changed" token={@form_token} connected={@connected}>
        <label for={@uploads.document.ref} class="field">Portable JSON file</label>
        <.live_file_input upload={@uploads.document} aria-describedby="upload-limit" />
        <p id="upload-limit">One JSON file, up to 262,144 bytes.</p>
        <p :if={upload_error?(@uploads.document)} role="alert">{@upload_error}</p>
        <p :for={entry <- @uploads.document.entries} :if={entry.valid? and !entry.done?} role="status">
          Uploading {entry.progress}%
        </p>
        <button type="submit" phx-disable-with="Preparing preview…">Preview file</button>
      </.staff_form>

      <.staff_form :if={@preview == :select_article} id="import-existing" event="preview_revision" token={@form_token} connected={@connected}>
        <label class="field" for="import-article-id">Existing article ID</label>
        <p id="import-article-hint">Open the matching article in this collection and copy its ID from the address. Previewing again confirms the match.</p>
        <input id="import-article-id" name="article_id" required aria-describedby="import-article-hint" />
        <button type="submit" phx-disable-with="Preparing preview…">Preview new revision</button>
      </.staff_form>

      <section :if={is_map(@preview)} aria-labelledby="preview-heading">
        <h2 id="preview-heading" class="section-heading">Import preview</h2>
        <.outcomes rows={@preview.articles} />
        <.decision id="apply-import" event="apply_import" title="Apply draft import" token={@form_token} connected={@connected} />
      </section>

      <.staff_form :if={@preview || @uploads.document.entries != []} id="cancel-import" event="cancel_import" token={@form_token} connected={@connected}>
        <button type="submit">Cancel import</button>
      </.staff_form>

      <section :if={@import_result} aria-labelledby="result-heading">
        <h2 id="result-heading" class="section-heading">Import result</h2>
        <.outcomes rows={@import_result} />
      </section>
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading import…</p>|

  defp outcomes(assigns) do
    ~H"""
    <table aria-label="Draft import outcomes">
      <thead><tr><th scope="col">Article reference</th><th scope="col">Outcome</th></tr></thead>
      <tbody>
        <tr :for={row <- @rows}>
          <th scope="row">{row.article_ref}</th>
          <td>{outcome(row.outcome)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp outcome(:create), do: "New article and draft"
  defp outcome(:existing), do: "Matching draft"
  defp outcome(:new_revision), do: "New draft revision"
end
