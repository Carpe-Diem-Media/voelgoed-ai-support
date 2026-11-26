defmodule VoelgoedAiWeb.KnowledgeLive.Draft do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.{Components, Forms}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision, Content, KnowledgeCollection}
  alias VoelgoedAiWeb.KnowledgeLive.Auth
  alias VoelgoedAiWeb.KnowledgeLive.Revision

  @locales ["af-ZA", "en-ZA"]
  @scope ~w(brand product event service)
  @lists [
    {"alternative_questions", "Alternative questions"},
    {"steps", "Ordered steps"},
    {"escalation_conditions", "Escalation conditions"}
  ]
  @source_fields [
    {"kind", "Source kind"},
    {"ref", "Source reference"},
    {"version", "Source version"},
    {"date", "Source date"},
    {"public_link", "Public link"}
  ]
  @dates [
    {"effective_from", "Effective from"},
    {"expires_at", "Expires at"},
    {"review_due_at", "Review due"}
  ]

  @impl true
  def handle_params(params, _, socket) do
    socket = Auth.load(socket, params)

    if socket.assigns.status == :ready do
      content = get_in(socket.assigns.page, [:revision, :content]) || %{}
      {:noreply, assign(socket, form_data: form_data(content), form_errors: %{}, notice: nil)}
    else
      {:noreply, socket}
    end
  end

  def read_page(:new_article, %{"id" => id}, actor) do
    case run(KnowledgeCollection, :read_collection, %{id: id}, actor) do
      {:ok, %{action_hints: %{create_draft: true}} = collection} ->
        {:ok,
         %{
           collection: collection,
           back: "/staff/knowledge/collections/#{id}",
           title: "New article"
         }}

      _ ->
        {:error, :denied}
    end
  end

  def read_page(:new_revision, %{"id" => id}, actor) do
    case run(Article, :read_article, %{id: id}, actor) do
      {:ok, %{action_hints: %{create_draft: true}} = article} ->
        {:ok, %{article: article, back: "/staff/knowledge/articles/#{id}", title: "New revision"}}

      _ ->
        {:error, :denied}
    end
  end

  def read_page(:edit, %{"id" => id, "revision_id" => revision_id} = params, actor) do
    case Revision.read_page(:show, params, actor) do
      {:ok, %{revision: %{action_hints: %{edit_draft: true}}} = page} ->
        {:ok,
         Map.merge(page, %{
           back: "/staff/knowledge/articles/#{id}/revisions/#{revision_id}",
           title: "Edit draft"
         })}

      _ ->
        {:error, :denied}
    end
  end

  @impl true
  def handle_event(event, %{"draft" => data} = params, socket)
      when event in ["validate_draft", "save_draft"] and is_map(data) do
    if submitted?(params, socket) do
      # Echo only named fields. Never let route targets or snapshot inputs into the form data.
      keys = form_data(%{}) |> Map.keys()
      data = Map.new(keys, fn key -> {key, text(data[key])} end)
      original = get_in(socket.assigns.page, [:revision, :content]) || %{}
      errors = errors(socket.assigns.live_action, data, original)
      socket = assign(socket, form_data: data, form_errors: errors, notice: nil)

      if event == "save_draft" and errors == %{},
        do: {:noreply, save(socket, data)},
        else: {:noreply, socket}
    else
      {:noreply, assign(socket, :notice, "Reload before saving this draft.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp save(socket, data) do
    page = socket.assigns.page
    original = get_in(page, [:revision, :content]) || %{}
    content = content(data, original)

    result =
      case socket.assigns.live_action do
        :new_article ->
          run(
            Article,
            :create_draft,
            %{
              collection_id: page.collection.id,
              article_ref: data["article_ref"],
              slug: data["slug"],
              content: content
            },
            Auth.actor(socket)
          )

        :new_revision ->
          run(
            ArticleRevision,
            :create_draft,
            %{article_id: page.article.id, content: content},
            Auth.actor(socket)
          )

        :edit ->
          row = page.revision

          run(
            ArticleRevision,
            :edit_draft,
            %{
              id: row.id,
              expected_hash: row.content_hash,
              expected_version: row.edit_version,
              content: content
            },
            Auth.actor(socket)
          )
      end

    case result do
      {:ok, %{revision: row}} ->
        open_revision(socket, row)

      {:ok, row} ->
        open_revision(socket, row)

      _ ->
        assign(
          socket,
          :notice,
          "The draft could not be saved. Check its fields or reload for the current revision."
        )
    end
  end

  defp open_revision(socket, row),
    do: redirect(socket, to: "/staff/knowledge/articles/#{row.article_id}/revisions/#{row.id}")

  defp errors(action, data, original) do
    required = [{"effective_from", "Enter an effective date."}]

    required =
      if action == :new_article,
        do: [
          {"article_ref", "Enter the article reference."},
          {"slug", "Enter the article slug."} | required
        ],
        else: required

    required =
      if data["primary_locale"] in @locales,
        do: [
          {key(data["primary_locale"], "title"), "Enter the primary language title."} | required
        ],
        else: required

    errors = Map.new(Enum.filter(required, fn {field, _} -> String.trim(data[field]) == "" end))

    errors =
      Enum.reduce(@dates, errors, fn {field, _}, found ->
        if data[field] != "" and not match?({:ok, _, _}, DateTime.from_iso8601(data[field])),
          do: Map.put(found, field, "Use an ISO 8601 date with offset."),
          else: found
      end)

    if errors == %{} and not match?({:ok, _}, Content.parse(content(data, original))) do
      %{
        "draft-fields" => "Check the FAQ details."
      }
    else
      errors
    end
  end

  defp content(data, original) do
    variants =
      for locale <- @locales, data[key(locale, "title")] != "" do
        old = Enum.find(original["localized_content"] || [], %{}, &(&1["locale"] == locale))

        base = %{
          "locale" => locale,
          "title" => preserve(data[key(locale, "title")], old["title"])
        }

        base =
          optional(
            base,
            "approved_answer",
            preserve(data[key(locale, "approved_answer")], old["approved_answer"])
          )

        Enum.reduce(@lists, base, fn {field, _}, acc ->
          optional(acc, field, lines(data[key(locale, field)], old[field]))
        end)
      end

    sources =
      for n <- 1..8,
          Enum.any?(@source_fields, fn {field, _} -> data[key(n, field)] != "" end) do
        Map.new(@source_fields, fn {field, _} -> {field, data[key(n, field)]} end)
        |> Map.reject(fn {_, value} -> value == "" end)
      end

    base = %{
      "category" => "faq",
      "applicability" =>
        Map.new(@scope, &{&1, lines(data[&1], nil)}) |> Map.reject(fn {_, v} -> is_nil(v) end),
      "primary_locale" => data["primary_locale"],
      "localized_content" => variants,
      "source_references" => sources,
      "response_mode" => data["response_mode"],
      "effective_from" => data["effective_from"]
    }

    base
    |> optional("expires_at", data["expires_at"])
    |> optional("review_due_at", data["review_due_at"])
    |> flag("sensitive", data, original)
    |> flag("time_sensitive", data, original)
  end

  defp form_data(content) do
    fields =
      Map.merge(
        %{
          "article_ref" => "",
          "slug" => "",
          "response_mode" => "exact",
          "primary_locale" => "af-ZA"
        },
        Map.take(content, ~w(response_mode primary_locale))
      )

    dates = Map.new(@dates, fn {field, _} -> {field, text(content[field])} end)
    scope = Map.new(@scope, &{&1, joined(get_in(content, ["applicability", &1]))})
    flags = Map.new(~w(sensitive time_sensitive), &{&1, to_string(content[&1] == true)})

    translations =
      for locale <- @locales, into: %{} do
        old = Enum.find(content["localized_content"] || [], %{}, &(&1["locale"] == locale))
        {locale, old}
      end

    language =
      for {locale, old} <- translations,
          {field, value} <-
            [{"title", text(old["title"])}, {"approved_answer", text(old["approved_answer"])}] ++
              Enum.map(@lists, fn {field, _} -> {field, joined(old[field])} end),
          into: %{} do
        {key(locale, field), value}
      end

    sources =
      for n <- 1..8, {field, _} <- @source_fields, into: %{} do
        row = Enum.at(content["source_references"] || [], n - 1, %{})
        {key(n, field), text(row[field])}
      end

    Enum.reduce([dates, scope, flags, language, sources], fields, &Map.merge/2)
  end

  defp optional(map, _field, value) when value in ["", nil], do: map
  defp optional(map, field, value), do: Map.put(map, field, value)

  defp flag(map, field, data, old) do
    if data[field] == "true" or Map.has_key?(old, field),
      do: Map.put(map, field, data[field] == "true"),
      else: map
  end

  defp lines("", old), do: if(old == [], do: [], else: nil)

  defp lines(value, old) do
    if normalize(joined(old)) == normalize(value),
      do: old,
      else: String.split(normalize(value), "\n", trim: true)
  end

  defp preserve(value, old) when is_binary(old) do
    if normalize(old) == normalize(value), do: old, else: value
  end

  defp preserve(value, _), do: value
  defp normalize(value), do: String.replace(value, ["\r\n", "\r"], "\n")
  defp joined(list) when is_list(list), do: Enum.join(list, "\n")
  defp joined(_), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp key(group, field), do: "#{group}-#{field}"

  @impl true
  def render(%{status: :ready} = assigns) do
    assigns =
      assign(assigns,
        locales: @locales,
        lists: @lists,
        source_fields: @source_fields,
        dates: @dates,
        scope_fields: @scope
      )

    ~H"""
    <.sheet title={@page.title} back={@page.back} back_text="Cancel">
      <.feedback id="draft-feedback" notice={@notice} errors={@form_errors} />
      <.staff_form id="draft-form" event="save_draft" change="validate_draft" token={@form_token} connected={@connected}>
        <fieldset id="draft-fields" aria-describedby={if @form_errors["draft-fields"], do: "draft-fields-error"}>
          <legend>FAQ details</legend>
          <p :if={@form_errors["draft-fields"]} id="draft-fields-error">{@form_errors["draft-fields"]}</p>
          <.field :if={@live_action == :new_article} id="article_ref" label="Article reference (stable identifier)" required={true} data={@form_data} errors={@form_errors} />
          <.field :if={@live_action == :new_article} id="slug" label="Article slug" required={true} data={@form_data} errors={@form_errors} />
          <label class="field" for="primary_locale">Primary language
            <select id="primary_locale" name="draft[primary_locale]">
              <option :for={locale <- @locales} value={locale} selected={@form_data["primary_locale"] == locale}>{locale}</option>
            </select>
          </label>
          <label class="field" for="response_mode">Response mode
            <select id="response_mode" name="draft[response_mode]">
              <option :for={{value, name} <- [{"exact", "Exact answer"}, {"grounded", "Grounded answer"}, {"escalate_only", "Escalate only"}]}
                value={value} selected={@form_data["response_mode"] == value}>{name}</option>
            </select>
          </label>
          <.field :for={{id, label} <- @dates} id={id} label={label <> " (ISO 8601 with offset)"}
            required={id == "effective_from"} data={@form_data} errors={@form_errors} />
          <label :for={{id, label} <- [{"sensitive", "Sensitive content"}, {"time_sensitive", "Time-sensitive content"}]} class="check">
            <input type="checkbox" name={"draft[#{id}]"} value="true" checked={@form_data[id] == "true"} /> {label}
          </label>
        </fieldset>

        <fieldset>
          <legend>Applicability</legend>
          <p>Enter one identifier per line, up to eight per field.</p>
          <.field :for={id <- @scope_fields} id={id} label={String.capitalize(id)} multiline={true} data={@form_data} errors={@form_errors} />
        </fieldset>

        <fieldset :for={locale <- @locales}>
          <legend>{if locale == "af-ZA", do: "Afrikaans", else: "English"}</legend>
          <.field id={key(locale, "title")} label="Title" required={locale == @form_data["primary_locale"]} data={@form_data} errors={@form_errors} />
          <.field id={key(locale, "approved_answer")} label="Approved answer" multiline={true} data={@form_data} errors={@form_errors} />
          <.field :for={{field, label} <- @lists} id={key(locale, field)} label={label <> " (one per line)"} multiline={true} data={@form_data} errors={@form_errors} />
        </fieldset>

        <fieldset>
          <legend>Source references</legend>
          <p>Enter a kind and reference for each source. Review requires at least one source.</p>
          <details :for={n <- 1..8} open={n == 1 or @form_data[key(n, "ref")] != ""}>
            <summary>Source {n}</summary>
            <label class="field" for={key(n, "kind")}>Source kind
              <select id={key(n, "kind")} name={"draft[#{key(n, "kind")}]"} >
                <option value="">Choose a kind</option>
                <option :for={kind <- ~w(document sharepoint git website)} value={kind} selected={@form_data[key(n, "kind")] == kind}>{String.capitalize(kind)}</option>
              </select>
            </label>
            <.field :for={{field, label} <- tl(@source_fields)} id={key(n, field)} label={label} data={@form_data} errors={@form_errors} />
          </details>
        </fieldset>
        <button type="submit" phx-disable-with="Saving…">Save draft</button>
      </.staff_form>
    </.sheet>
    """
  end

  def render(assigns), do: ~H|<p class="notice">Loading draft…</p>|

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:data, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:required, :boolean, default: false)
  attr(:multiline, :boolean, default: false)

  defp field(assigns) do
    assigns = assign(assigns, :error, assigns.errors[assigns.id])

    ~H"""
    <div class="field">
      <label for={@id}>{@label}</label>
      <textarea :if={@multiline} id={@id} name={"draft[#{@id}]"} rows="3"
        aria-invalid={if @error, do: "true"} aria-describedby={if @error, do: @id <> "-error"}>{["\n", @data[@id]]}</textarea>
      <input :if={!@multiline} id={@id} name={"draft[#{@id}]"} value={@data[@id]} required={@required}
        aria-invalid={if @error, do: "true"} aria-describedby={if @error, do: @id <> "-error"} />
      <p :if={@error} id={@id <> "-error"}>{@error}</p>
    </div>
    """
  end
end
