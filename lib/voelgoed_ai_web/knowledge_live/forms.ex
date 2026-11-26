defmodule VoelgoedAiWeb.KnowledgeLive.Forms do
  @moduledoc false
  use Phoenix.Component
  import VoelgoedAiWeb.KnowledgeLive.Components, only: [label: 1]

  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:change, :string, default: nil)
  attr(:token, :string, required: true)
  attr(:connected, :boolean, required: true)
  slot(:inner_block, required: true)

  def staff_form(assigns) do
    ~H"""
    <form id={@id} class="editorial-form" phx-submit={@event} phx-change={@change} phx-hook="StaffForm">
      <fieldset class="form-body" disabled={!@connected}>
        <input type="hidden" name="form_token" value={@token} />
        {render_slot(@inner_block)}
      </fieldset>
    </form>
    """
  end

  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:title, :string, required: true)
  attr(:token, :string, required: true)
  attr(:connected, :boolean, required: true)
  attr(:reasons, :list, default: [])
  attr(:approval, :boolean, default: false)
  attr(:disabled, :boolean, default: false)

  def decision(assigns) do
    ~H"""
    <.staff_form id={@id} event={@event} token={@token} connected={@connected}>
      <label :if={@reasons != []} class="field" for={@id <> "-reason"}>
        Reason for {String.downcase(@title)}
        <select id={@id <> "-reason"} name="reason" required>
          <option value="">Choose a reason</option>
          <option :for={reason <- @reasons} value={reason}>{label(reason)}</option>
        </select>
      </label>
      <label class="check">
        <input type="checkbox" name={if @approval, do: "source_verified", else: "confirm"} value="true" required />
        {if @approval, do: "I verified this revision against its sources", else: "Confirm: " <> @title}
      </label>
      <button type="submit" phx-disable-with="Submitting…" disabled={@disabled}>{@title}</button>
    </.staff_form>
    """
  end

  attr(:id, :string, required: true)
  attr(:notice, :string, default: nil)
  attr(:errors, :map, default: %{})

  def feedback(assigns) do
    ~H"""
    <div id={@id} class="form-feedback" aria-live="polite">
      <p :if={@notice} role="status">{@notice}</p>
      <div :if={@errors != %{}} class="error-summary" role="alert" tabindex="-1" data-error-summary>
        <h2>Check these fields</h2>
        <ul>
          <li :for={{id, error} <- Enum.sort(@errors)}><a href={"##{id}"}>{error}</a></li>
        </ul>
      </div>
    </div>
    """
  end

  def confirmed?(%{"confirm" => "true"}), do: true
  def confirmed?(_), do: false

  def submitted?(%{"form_token" => token}, %{assigns: %{form_token: token}})
      when is_binary(token), do: true

  def submitted?(_, _), do: false
end
