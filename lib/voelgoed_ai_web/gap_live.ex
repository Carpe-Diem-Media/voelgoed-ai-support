if Mix.env() == :test do
  defmodule VoelgoedAiWeb.GapLive do
    @moduledoc false
    use Phoenix.LiveView, layout: false, log: false

    import VoelgoedAiWeb.KnowledgeLive.Components

    alias VoelgoedAi.Knowledge.{GapReview, KnowledgeGap}
    alias VoelgoedAiWeb.StaffSession

    @actions %{
      "review" => :review,
      "defer" => :defer,
      "dismiss" => :dismiss,
      "address" => :address
    }

    @impl true
    def mount(_params, session, socket) do
      actor =
        if connected?(socket), do: get_connect_info(socket, :session), else: session

      actor = StaffSession.decode(actor)

      case GapReview.access(actor) do
        {:ok, :authorized} ->
          if connected?(socket) do
            delay = max(0, actor.expiry * 1_000 - System.system_time(:millisecond))
            Process.send_after(self(), :staff_gap_expired, delay)
          end

          {:ok,
           socket
           |> put_private(:gap_actor, actor)
           |> assign(notice: nil, queue: nil, connected: connected?(socket))}

        _ ->
          {:ok, deny(socket)}
      end
    end

    @impl true
    def handle_params(params, _, socket) do
      socket = put_private(socket, :gap_params, Map.take(params, ["before_id"]))
      {:noreply, load(socket)}
    end

    @impl true
    def handle_info(:staff_gap_expired, socket), do: {:noreply, deny(socket)}
    def handle_info(_, socket), do: {:noreply, socket}

    @impl true
    def handle_event("refresh", _, socket), do: {:noreply, load(assign(socket, :notice, nil))}

    def handle_event(event, params, socket) do
      with {:ok, :authorized} <- GapReview.access(socket.private[:gap_actor]),
           action when is_atom(action) and not is_nil(action) <- @actions[event] do
        args =
          params
          |> Map.take(["expected_version", "reason", "revision_id", "attested"])
          |> Map.put("id", params["gap_id"])

        socket =
          case run(KnowledgeGap, action, args, socket.private.gap_actor) do
            {:ok, %{id: id}} ->
              socket |> assign(:notice, nil) |> push_event("gap-reviewed", %{id: id})

            _ ->
              assign(
                socket,
                :notice,
                "The gap could not be updated. Check its current state and the selected revision."
              )
          end

        {:noreply, load(socket)}
      else
        nil -> {:noreply, socket}
        _ -> {:noreply, deny(socket)}
      end
    end

    defp load(socket) do
      actor = socket.private[:gap_actor]

      with {:ok, :authorized} <- GapReview.access(actor) do
        case run(KnowledgeGap, :list_gaps, socket.private.gap_params, actor) do
          {:ok, queue} ->
            assign(
              socket,
              :queue,
              Map.put(queue, :cursor, socket.private.gap_params["before_id"])
            )

          _ ->
            assign(socket, queue: nil, notice: "The queue could not load. Refresh to try again.")
        end
      else
        _ -> deny(socket)
      end
    end

    defp deny(socket) do
      socket
      |> put_private(:gap_actor, nil)
      |> assign(queue: nil, notice: nil)
      |> redirect(to: "/staff/knowledge/denied")
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.sheet title="Knowledge gaps">
        <:tools>
          <button type="button" phx-click="refresh" phx-disable-with="Refreshing...">Refresh</button>
        </:tools>
        <div id="gap-queue" phx-hook="StaffGapQueue">
          <p class="form-feedback" role="status">{@notice}</p>
          <p class="notice gap-offline" role="status">Reconnecting. Review actions are paused.</p>
          <noscript><p class="notice">Enable JavaScript to review gaps.</p></noscript>
          <p :if={@queue && @queue.rows == []} class="notice">
            No verified gaps in this queue.
          </p>
          <section :for={gap <- @queue && @queue.rows || []} class="variant" id={"gap-#{gap.id}"}>
            <h2 id={"gap-heading-#{gap.id}"} tabindex="-1">Rehearsal schedule</h2>
            <ul class="gap-summary" aria-label="Gap details">
              <li>{cause(gap.cause)}</li>
              <li>{language(gap.locale)}</li>
              <li>{label(gap.status)}</li>
            </ul>
            <p><time datetime={DateTime.to_iso8601(gap.inserted_at)}>{timestamp(gap.inserted_at)}</time></p>
            <p :if={gap.recurrence_of_id}>Recurrence of {gap.recurrence_of_id}</p>
            <p :if={gap.dismissal_reason}>{label(gap.dismissal_reason)}</p>
            <p :if={gap.resolved_revision_id}>Published revision {gap.resolved_revision_id}</p>
            <.review_form :if={gap.status == :open} gap={gap} connected={@connected} action="review" label="Start review" />
            <%= if gap.status == :in_review do %>
              <.review_form gap={gap} connected={@connected} action="defer" label="Defer" />
              <.review_form :if={@queue.can_dismiss} gap={gap} connected={@connected} action="dismiss" label="Dismiss">
                <label class="field">
                  Dismissal reason
                  <select name="reason" required>
                    <option value="">Select a reason</option>
                    <option :for={reason <- KnowledgeGap.dismissal_reasons()} value={reason}>
                      {label(reason)}
                    </option>
                  </select>
                </label>
              </.review_form>
              <.review_form :if={@queue.can_address} gap={gap} connected={@connected} action="address" label="Mark addressed">
                <label class="field">
                  Published revision ID
                  <input type="text" name="revision_id" required minlength="36" maxlength="36" />
                </label>
                <label class="check">
                  <input type="checkbox" name="attested" value="true" required />
                  I verified that this revision addresses the gap.
                </label>
              </.review_form>
            <% end %>
          </section>
          <nav :if={@queue && (@queue.before_id || @queue.cursor)} class="pagination" aria-label="Pages">
            <a :if={@queue.cursor} href="/staff/gaps">Newest gaps</a>
            <a :if={@queue.before_id} href={"/staff/gaps?before_id=#{@queue.before_id}"}>Older gaps</a>
          </nav>
        </div>
      </.sheet>
      """
    end

    attr(:gap, :map, required: true)
    attr(:connected, :boolean, required: true)
    attr(:action, :string, required: true)
    attr(:label, :string, required: true)
    slot(:inner_block)

    defp review_form(assigns) do
      ~H"""
      <form
        class="editorial-form"
        id={"#{@action}-#{@gap.id}"}
        phx-submit={@action}
        phx-hook="StaffForm"
        method="post"
      >
        <fieldset disabled={!@connected}>
          <input type="hidden" name="gap_id" value={@gap.id} />
          <input type="hidden" name="expected_version" value={@gap.review_version} />
          {render_slot(@inner_block)}
          <button type="submit" phx-disable-with="Saving...">{@label}</button>
        </fieldset>
      </form>
      """
    end

    defp language("en-ZA"), do: "English"
    defp language("af-ZA"), do: "Afrikaans"

    defp cause(:missing), do: "Approved source missing"
    defp cause(:insufficient), do: "Requested language missing"
    defp cause(:conflicting), do: "Approved facts conflict"
  end
end
