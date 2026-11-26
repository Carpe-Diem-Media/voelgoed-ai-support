defmodule VoelgoedAiWeb.KnowledgeLive.Auth do
  @moduledoc "Checks the current staff session and scoped target on each LiveView event."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias VoelgoedAiWeb.StaffSession

  def on_mount(:default, _params, session, socket) do
    # Connected views must use the transport cookie, never the signed page session.
    connected = connected?(socket)
    cookie = if connected, do: get_connect_info(socket, :session), else: session
    actor = StaffSession.decode(cookie)

    case StaffSession.knowledge_access(actor) do
      {:ok, :authorized} ->
        if connected do
          delay = max(0, actor.expiry * 1_000 - System.system_time(:millisecond))
          Process.send_after(self(), :staff_knowledge_expired, delay)
        end

        {:cont,
         socket
         |> put_private(:staff_actor, actor)
         |> assign(
           page: nil,
           status: :loading,
           connected: connected,
           form_token: nil,
           form_data: %{},
           form_errors: %{},
           notice: nil,
           grant: nil,
           import_result: nil,
           preview: nil
         )
         |> attach_hook(:staff_event_access, :handle_event, &authorize_event/3)
         |> attach_hook(:staff_expiry, :handle_info, &handle_expiry/2)}

      {:error, _} ->
        {:halt, deny(socket)}
    end
  end

  def load(socket, params) do
    case read(socket, params) do
      {:ok, page} ->
        socket
        |> put_private(:staff_route, params)
        |> assign(page: page, status: :ready, form_token: token())

      {:error, _} ->
        deny(socket)
    end
  end

  def reload(socket), do: load(socket, socket.private.staff_route)
  def actor(socket), do: socket.private.staff_actor
  def token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp read(socket, params),
    do: socket.view.read_page(socket.assigns.live_action, params, actor(socket))

  def recheck(socket) do
    with {:ok, :authorized} <- StaffSession.knowledge_access(actor(socket)),
         {:ok, _} <- read(socket, socket.private.staff_route) do
      # Authorize against current state without replacing the version, pointer
      # or generation the editor actually saw. The action verifies that snapshot.
      socket
    else
      _ -> deny(socket)
    end
  end

  defp authorize_event(event, _payload, socket) do
    case recheck(socket) do
      %{assigns: %{status: :denied}} = denied -> {:halt, denied}
      ready when event == "refresh" -> {:halt, reload(ready)}
      ready -> {:cont, ready}
    end
  end

  defp handle_expiry(:staff_knowledge_expired, socket), do: {:halt, deny(socket)}
  # LiveView otherwise logs unhandled messages with inspect/1 at debug.
  defp handle_expiry(_, socket), do: {:halt, socket}

  defp deny(socket) do
    socket
    |> put_private(:staff_actor, nil)
    |> put_private(:staff_route, nil)
    |> put_private(:import_document, nil)
    |> assign(
      page: nil,
      status: :denied,
      form_token: nil,
      form_data: %{},
      form_errors: %{},
      notice: nil,
      grant: nil,
      import_result: nil,
      preview: nil
    )
    |> redirect(to: "/staff/knowledge/denied")
  end
end
