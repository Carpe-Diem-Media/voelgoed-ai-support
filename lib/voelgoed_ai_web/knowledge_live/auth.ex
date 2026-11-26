defmodule VoelgoedAiWeb.KnowledgeLive.Auth do
  @moduledoc "Checks staff identity at mount and reloads the authorized target for each event."
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias VoelgoedAiWeb.StaffSession

  def on_mount(:default, _params, session, socket) do
    # Connected views must use the transport cookie, never the signed page session.
    cookie = if connected?(socket), do: get_connect_info(socket, :session), else: session
    actor = StaffSession.decode(cookie)

    case StaffSession.knowledge_access(actor) do
      {:ok, :authorized} ->
        if connected?(socket) do
          delay = max(0, actor.expiry * 1_000 - System.system_time(:millisecond))
          Process.send_after(self(), :staff_knowledge_expired, delay)
        end

        {:cont,
         socket
         |> put_private(:staff_actor, actor)
         |> assign(page: nil, status: :loading)
         |> attach_hook(:staff_event_access, :handle_event, &authorize_event/3)
         |> attach_hook(:staff_expiry, :handle_info, &handle_expiry/2)}

      {:error, _} ->
        {:halt, deny(socket)}
    end
  end

  def load(socket, params) do
    actor = socket.private.staff_actor

    case socket.view.read_page(socket.assigns.live_action, params, actor) do
      {:ok, page} ->
        socket |> put_private(:staff_route, params) |> assign(page: page, status: :ready)

      {:error, _} ->
        deny(socket)
    end
  end

  defp authorize_event(_event, _payload, socket) do
    # C1 is read-only. Reload the stored target and ignore all event payloads.
    case StaffSession.knowledge_access(socket.private.staff_actor) do
      {:ok, :authorized} -> {:halt, load(socket, socket.private.staff_route)}
      {:error, _} -> {:halt, deny(socket)}
    end
  end

  defp handle_expiry(:staff_knowledge_expired, socket), do: {:halt, deny(socket)}
  defp handle_expiry(_, socket), do: {:cont, socket}

  defp deny(socket) do
    socket
    |> put_private(:staff_actor, nil)
    |> put_private(:staff_route, nil)
    |> assign(page: nil, status: :denied)
    |> redirect(to: "/staff/knowledge/denied")
  end
end
