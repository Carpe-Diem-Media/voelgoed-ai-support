defmodule VoelgoedAiWeb.OperationsLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false, log: false

  import VoelgoedAiWeb.KnowledgeLive.Components

  alias VoelgoedAi.Governance.AutomationControl
  alias VoelgoedAi.Support
  alias VoelgoedAi.Support.{Configuration, Operations, RunProcessing}
  alias VoelgoedAiWeb.StaffSession

  @denied "/staff/knowledge/denied"

  @impl true
  def mount(_, session, socket) do
    session = if connected?(socket), do: get_connect_info(socket, :session), else: session
    staff = StaffSession.decode(session)

    if Operations.access(staff) == {:ok, :authorized} do
      if connected?(socket) do
        Process.send_after(
          self(),
          :staff_expired,
          max(0, staff.expiry * 1_000 - System.system_time(:millisecond))
        )
      end

      {:ok,
       socket
       |> put_private(:operations_staff, staff)
       |> assign(data: nil, notice: nil, draft: nil, connected: connected?(socket))}
    else
      {:ok, deny(socket)}
    end
  end

  @impl true
  def handle_params(params, _, socket) do
    socket = put_private(socket, :operations_detail, params["id"])
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event(event, params, socket) do
    with {:ok, :authorized} <- Operations.access(socket.private[:operations_staff]) do
      result = apply_event(event, params, socket)
      socket = load(socket)

      socket =
        if socket.redirected do
          socket
        else
          case result do
            {:ok, %{id: draft_id, text: _, expires_at: expiry} = draft}
            when socket.assigns.data.operator.detail.draft_id == draft_id ->
              delay =
                max(
                  0,
                  DateTime.diff(expiry, VoelgoedAi.Support.ChatwootAdapter.now(), :millisecond)
                )

              ref = make_ref()
              Process.send_after(self(), {:draft_expired, ref}, delay)
              socket |> put_private(:draft_expiry, ref) |> assign(:draft, draft)

            {:ok, _} ->
              assign(socket, :notice, "Operation recorded.")

            _ ->
              assign(
                socket,
                :notice,
                "This operation is unavailable. Refresh to check the current state."
              )
          end
        end

      {:noreply, socket}
    else
      _ -> {:noreply, deny(socket)}
    end
  end

  @impl true
  def handle_info(:staff_expired, socket), do: {:noreply, deny(socket)}

  def handle_info({:draft_expired, ref}, socket) do
    if socket.private[:draft_expiry] == ref,
      do: {:noreply, assign(socket, :draft, nil)},
      else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp apply_event("disable", _, socket),
    do: run(AutomationControl, :disable_automation, %{}, socket.private.operations_staff)

  defp apply_event(
         "enable",
         _,
         %{assigns: %{data: %{admin: %{configuration: %{binding_id: id}}}}} = socket
       ),
       do:
         run(
           AutomationControl,
           :enable_automation,
           %{binding_id: id},
           socket.private.operations_staff
         )

  defp apply_event("recover-circuit", %{"session" => id}, socket) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         do: Configuration.recover_circuit(socket.private.operations_staff, id)
  end

  defp apply_event(event, params, %{assigns: %{data: %{operator: %{detail: detail}}}} = socket)
       when is_map(detail) do
    staff = socket.private.operations_staff

    case {event, params} do
      {"local-handoff", _} ->
        Support.route_locally(staff, detail.session.id)

      {"review-draft", _} when is_binary(detail.draft_id) ->
        RunProcessing.review_draft(staff, detail.draft_id)

      {"readback", %{"id" => id}} ->
        if Enum.any?(detail.deliveries, &(&1.id == id and &1.state == :unknown)),
          do: Support.request_readback(staff, id),
          else: {:error, :unavailable}

      {"abandon", %{"delivery_id" => id, "acknowledge" => "true"}} ->
        if Enum.any?(detail.deliveries, &(&1.id == id and &1.state == :unknown)),
          do: Support.abandon_delivery(staff, id, :acknowledge_uncertainty),
          else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  defp apply_event(_, _, _), do: {:error, :denied}

  defp load(socket) do
    case Operations.snapshot(
           socket.private[:operations_staff],
           socket.private[:operations_detail]
         ) do
      {:ok, data} ->
        assign(socket, data: data, notice: nil, draft: nil)

      {:error, :denied} ->
        deny(socket)

      _ ->
        assign(socket,
          data: nil,
          notice: "The operations page could not load. Try Refresh.",
          draft: nil
        )
    end
  end

  defp deny(socket) do
    socket
    |> put_private(:operations_staff, nil)
    |> assign(data: nil, draft: nil, notice: nil)
    |> redirect(to: @denied)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.sheet title="Support operations">
      <:tools>
        <button type="button" phx-click="refresh" phx-disable-with="Refreshing…" disabled={!@connected}>Refresh</button>
      </:tools>
      <p class="form-feedback" role="status">{@notice}</p>
      <p class="notice operations-offline" role="status">Actions are paused while the connection opens.</p>
      <.admin :if={@data && @data.admin} data={@data.admin} connected={@connected} />
      <.operator :if={@data && @data.operator} data={@data.operator} draft={@draft} connected={@connected} />
    </.sheet>
    """
  end

  defp admin(assigns) do
    ~H"""
    <section class="variant">
      <h2>Automation</h2>
      <dl class="operations-facts">
        <dt>Effective state</dt><dd>{label(@data.status)}</dd>
        <dt>Local readiness</dt><dd>{if @data.readiness == :ok, do: "Ready", else: "Unavailable"}</dd>
        <%= if configuration = @data.configuration do %>
          <dt>Assistant</dt><dd>{label(configuration.assistant)}</dd>
          <dt>Inbox</dt><dd>{label(configuration.binding)}</dd>
          <dt>Mode</dt><dd>{label(configuration.mode)}</dd>
          <dt>Chatwoot circuit</dt><dd>{label(configuration.circuit)}</dd>
        <% end %>
      </dl>
      <p :if={!@data.configuration}>Qualified inbox configuration is unavailable.</p>
      <p class="actions">
        <button type="button" phx-click="disable" phx-disable-with="Disabling…" disabled={!@connected}>Disable automation</button>
        <button :if={@data.status == :disabled && @data.configuration} type="button" phx-click="enable"
          data-confirm="Enable automation for fresh eligible work?" phx-disable-with="Enabling…" disabled={!@connected}>
          Enable automation
        </button>
      </p>
      <form :if={@data.configuration && @data.configuration.circuit != :closed} phx-submit="recover-circuit">
        <fieldset disabled={!@connected}>
          <legend>Check circuit recovery</legend>
          <label class="field">Qualified session reference
            <input name="session" required minlength="36" maxlength="36" />
          </label>
          <button phx-disable-with="Checking…">Check recovery</button>
        </fieldset>
      </form>
    </section>
    <section class="variant">
      <h2>Spend</h2>
      <%= case @data.spend do %>
        <% {:ok, spend} -> %>
          <p>Values in nano-USD.</p>
          <dl class="operations-facts">
            <dt>Settled today</dt><dd>{spend.day}</dd>
            <dt>Settled this month</dt><dd>{spend.month}</dd>
            <dt>Reserved or unknown</dt><dd>{spend.outstanding}</dd>
            <dt>Generation day cap</dt><dd>{caps(spend.generation_caps, :day_cap)}</dd>
            <dt>Generation month cap</dt><dd>{caps(spend.generation_caps, :month_cap)}</dd>
            <dt>Embedding day cap</dt><dd>{caps(spend.embedding_caps, :day_cap)}</dd>
            <dt>Embedding month cap</dt><dd>{caps(spend.embedding_caps, :month_cap)}</dd>
          </dl>
        <% _ -> %>
          <p>Accounting totals are unavailable.</p>
      <% end %>
    </section>
    <section class="variant">
      <h2>Recent configuration activity</h2>
      <p :if={@data.audit == []}>No recorded changes.</p>
      <ul :if={@data.audit != []} class="operations-list">
        <li :for={row <- @data.audit}>{label(row.event)} <span>{timestamp(row.occurred_at)}</span></li>
      </ul>
    </section>
    """
  end

  defp operator(assigns) do
    ~H"""
    <section class="variant">
      <h2>Support queue</h2>
      <p>Send replies and resolve conversations in Chatwoot.</p>
      <p :if={!@data.available}>The qualified support inbox is unavailable.</p>
      <p :if={@data.available && @data.rows == []}>No sessions need review.</p>
      <ul :if={@data.rows != []} class="operations-list">
        <li :for={[id, state, reason, updated, unknown] <- @data.rows}>
          <.link patch={"/staff/operations/#{id}"}>{id}</.link>
          <p>{display(state)}</p>
          <p :if={unknown}>Unresolved delivery</p>
          <p :if={reason}>{display(reason)}</p>
          <time>{timestamp(updated)}</time>
        </li>
      </ul>
    </section>
    <p :if={@data.detail_denied} class="notice" role="status">Session details are unavailable.</p>
    <section :if={detail = @data.detail} id="session-detail" class="variant">
      <h2>Session detail</h2>
      <p>{label(detail.session.state)}</p>
      <p :if={detail.session.reason_code}>{label(detail.session.reason_code)}</p>
      <button :if={detail.session.state == :bot_active} type="button" phx-click="local-handoff"
        phx-disable-with="Recording…" disabled={!@connected}>Route to staff locally</button>
      <h3>Deliveries</h3>
      <p :if={detail.deliveries == []}>No delivery intents.</p>
      <ul :if={detail.deliveries != []} class="operations-list">
        <li :for={delivery <- detail.deliveries}>
          <p>{label(delivery.purpose)}: {label(delivery.state)}</p>
          <p :if={delivery.reason_code || delivery.uncertainty_reason}>{label(delivery.reason_code || delivery.uncertainty_reason)}</p>
          <p>Attempts {delivery.attempt_count}</p>
          <button :if={delivery.state == :unknown} type="button" phx-click="readback" phx-value-id={delivery.id}
            phx-disable-with="Checking…" disabled={!@connected}>Check Chatwoot for evidence</button>
          <details :if={delivery.state == :unknown}>
            <summary>Abandon unresolved delivery</summary>
            <form phx-submit="abandon">
              <fieldset disabled={!@connected}>
                <input type="hidden" name="delivery_id" value={delivery.id} />
                <label class="check"><input type="checkbox" name="acknowledge" value="true" required />
                  I acknowledge that the delivery outcome may remain unknown.
                </label>
                <button phx-disable-with="Recording…">Record abandonment</button>
              </fieldset>
            </form>
          </details>
        </li>
      </ul>
      <h3>Assisted draft</h3>
      <p :if={!detail.draft_id}>No current assisted draft is available.</p>
      <button :if={detail.draft_id} type="button" phx-click="review-draft" phx-disable-with="Checking…"
        disabled={!@connected}>Review current draft</button>
      <div :if={@draft} class="notice">
        <p lang={@draft.locale}>{@draft.text}</p>
        <ul aria-label="Evidence revisions"><li :for={ref <- @draft.evidence}>{ref}</li></ul>
      </div>
      <h3>Recent session activity</h3>
      <p :if={detail.audit == []}>No recorded activity.</p>
      <ul :if={detail.audit != []} class="operations-list">
        <li :for={[event, _reason, at] <- detail.audit}>{display(event)} <span>{timestamp(at)}</span></li>
      </ul>
    </section>
    <section class="variant">
      <h2>Attention history</h2>
      <p :if={@data.alerts == []}>No local alerts.</p>
      <ul :if={@data.alerts != []} class="operations-list">
        <li :for={[kind, at] <- @data.alerts}>{display(kind)} <span>{timestamp(at)}</span></li>
      </ul>
    </section>
    """
  end

  defp caps(nil, _), do: "Unavailable"
  defp caps(caps, key), do: Map.fetch!(caps, key)

  defp display(value), do: value |> String.replace("_", " ") |> String.capitalize()
end
