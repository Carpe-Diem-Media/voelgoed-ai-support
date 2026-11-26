defmodule VoelgoedAiWeb.KnowledgeLive.Components do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Knowledge · Voelgoed staff</title>
        <link rel="stylesheet" href="/staff/assets/knowledge.css" />
        <script defer src="/staff/assets/phoenix/phoenix.min.js"></script>
        <script defer src="/staff/assets/live_view/phoenix_live_view.min.js"></script>
        <script defer src="/staff/assets/knowledge.js"></script>
      </head>
      <body>
        <a class="skip-link" href="#main">Skip to content</a>
        <header class="masthead">
          <nav aria-label="Staff">
            <a href="/staff/knowledge">Voelgoed Knowledge</a>
          </nav>
        </header>
        <main id="main" tabindex="-1">{@inner_content}</main>
      </body>
    </html>
    """
  end

  attr(:title, :string, required: true)
  attr(:back, :string, default: nil)
  attr(:back_text, :string, default: nil)
  slot(:tools)
  slot(:inner_block, required: true)

  def sheet(assigns) do
    ~H"""
    <nav :if={@back} class="trail" aria-label="Back">
      <a href={@back}>{@back_text}</a>
    </nav>
    <section class="sheet" aria-labelledby="page-heading">
      <header class="sheet-heading">
        <h1 id="page-heading">{@title}</h1>
        {render_slot(@tools)}
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr(:page, :map, required: true)
  attr(:path, :string, required: true)
  attr(:cursor, :string, default: nil)

  def pagination(assigns) do
    ~H"""
    <nav :if={@cursor || @page.next_after_id} class="pagination" aria-label="Pages">
      <a :if={@cursor} href={@path}>First page</a>
      <a :if={@page.next_after_id} href={@path <> "?after_id=" <> @page.next_after_id}>Next page</a>
    </nav>
    """
  end

  def run(resource, action, args, actor) do
    resource
    |> Ash.ActionInput.for_action(action, args, actor: actor)
    |> Ash.run_action()
  end

  def cursor(params), do: Map.take(params, ["after_id"])

  def label(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  def timestamp(nil), do: "—"
  def timestamp(value), do: Calendar.strftime(value, "%d %b %Y, %H:%M UTC")

  def index_state(:absent), do: "No approved text"
  def index_state(:not_indexed), do: "None"
  def index_state(:ready_to_activate), do: "Ready for activation"
  def index_state(state), do: label(state)
end
