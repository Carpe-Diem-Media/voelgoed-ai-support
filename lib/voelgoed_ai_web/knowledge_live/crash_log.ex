defmodule VoelgoedAiWeb.KnowledgeLive.CrashLog do
  @moduledoc false

  alias VoelgoedAiWeb.{Endpoint, GapLive, GapLiveSocket, StaffLiveSocket}

  @filter :vgas_staff_knowledge_crash_log
  @staff_sockets [StaffLiveSocket, GapLiveSocket]
  @staff_pools Enum.map(@staff_sockets, &Module.concat(Endpoint, &1))
  @view_prefix "Elixir.VoelgoedAiWeb.KnowledgeLive."
  @staff_http {__MODULE__, :staff_http}

  # OTP prepends primary filters. Install before starting the endpoint so raw
  # reports are replaced before Elixir's translator and every logger handler.
  def install, do: :logger.add_primary_filter(@filter, {&__MODULE__.filter/2, nil})
  def uninstall, do: :logger.remove_primary_filter(@filter)

  # Successful requests clear the marker here. On failure Phoenix's outer
  # error renderer still needs it when it logs without conn metadata.
  def with_staff_http(fun) do
    Process.put(@staff_http, true)
    result = fun.()
    clear_staff_http()
    result
  end

  def clear_staff_http, do: Process.delete(@staff_http)

  def filter(event, _) do
    redact(event)
  catch
    # OTP removes a primary filter if it fails. Fall back to the request or
    # emitting process identity without reading the malformed report again.
    _, _ ->
      if staff_http_event?(event) or staff_process?(),
        do: replace(event, "Staff crash report redacted"),
        else: :ignore
  end

  # Elixir's Logger prefixes Bandit's domain with :elixir.
  defp redact(
         %{meta: %{domain: [:elixir, :bandit], conn: %Plug.Conn{path_info: ["staff" | _]}}} =
           event
       ),
       do: replace(event, "Staff HTTP request crashed")

  defp redact(%{meta: %{mfa: {Phoenix.Logger, :phoenix_error_rendered, 4}}}) do
    # Phoenix wraps Endpoint.call/2 at compile time. On failure the marker
    # must survive until that outer wrapper emits this event.
    if Process.get(@staff_http), do: :stop, else: :ignore
  end

  defp redact(%{msg: {:report, %{label: {:gen_server, :terminate}} = report}} = event) do
    redact_process_report(event, report[:process_label], Process.get(:"$ancestors", []))
  end

  defp redact(%{msg: {:report, %{label: {:proc_lib, :crash}, report: [own, _]}}} = event) do
    redact_process_report(event, own[:process_label], own[:ancestors])
  end

  defp redact(%{msg: {:report, %{label: {:supervisor, kind}}}} = event)
       when kind in [:child_terminated, :shutdown_error, :start_error] do
    # The child may already be gone. Each Phoenix socket handler owns a
    # separate pool, and its partition supervisors retain the pool ancestor.
    if staff_pool?(Process.get(:"$ancestors", [])) do
      replace(event, "Staff knowledge channel supervisor reported an abnormal child exit")
    else
      :ignore
    end
  end

  defp redact(%{meta: %{mfa: {Phoenix.Channel.Server, :join, 4}}} = event) do
    # A crash during join can also be formatted by Phoenix in the transport
    # process. Phoenix.Socket.__init__/1 labels that process before joins.
    case :proc_lib.get_label(self()) do
      {Phoenix.Socket, socket, _} when socket in @staff_sockets ->
        replace(event, "Staff knowledge channel join crashed")

      _ ->
        :ignore
    end
  end

  defp redact(_event), do: :ignore

  defp redact_process_report(event, {Phoenix.LiveView, view, _}, ancestors)
       when is_atom(view) do
    if staff_view?(view) do
      replace(event, "Staff knowledge LiveView crashed (#{inspect(view)})")
    else
      redact_pool_report(event, ancestors)
    end
  end

  defp redact_process_report(event, {Phoenix.Socket, socket, _}, _ancestors)
       when socket in @staff_sockets,
       do: replace(event, "Staff knowledge socket crashed")

  defp redact_process_report(event, _label, ancestors), do: redact_pool_report(event, ancestors)

  # A crash before LiveView labels a verified mount, or in its upload channel,
  # can still carry the join message and connect_info.
  defp redact_pool_report(event, ancestors) do
    if staff_pool?(ancestors),
      do: replace(event, "Staff knowledge channel crashed"),
      else: :ignore
  end

  defp staff_http_event?(%{meta: %{conn: %Plug.Conn{path_info: ["staff" | _]}}}), do: true
  defp staff_http_event?(_), do: false

  defp staff_process? do
    Process.get(@staff_http, false) or staff_pool?(Process.get(:"$ancestors", [])) or
      case :proc_lib.get_label(self()) do
        {Phoenix.Socket, socket, _} when socket in @staff_sockets -> true
        {Phoenix.LiveView, view, _} when is_atom(view) -> staff_view?(view)
        _ -> false
      end
  end

  defp staff_view?(GapLive), do: true
  defp staff_view?(view), do: String.starts_with?(Atom.to_string(view), @view_prefix)

  defp staff_pool?([pool | _]) when pool in @staff_pools, do: true
  defp staff_pool?([_ | ancestors]), do: staff_pool?(ancestors)
  defp staff_pool?(_), do: false

  defp replace(event, message) do
    # Drop the reason, stack, last message, state, and any report/Logger
    # metadata that can contain the same data. Retain OTP log bookkeeping only.
    meta =
      case event do
        %{meta: meta} when is_map(meta) -> Map.take(meta, [:time, :pid, :gl])
        _ -> %{}
      end

    Map.merge(event, %{msg: {:string, message}, meta: meta})
  end
end
