defmodule VoelgoedAiWeb.KnowledgeLive.CrashLog do
  @moduledoc false

  alias VoelgoedAiWeb.{Endpoint, StaffLiveSocket}

  @filter :vgas_staff_knowledge_crash_log
  @staff_pool Module.concat(Endpoint, StaffLiveSocket)
  @view_prefix "Elixir.VoelgoedAiWeb.KnowledgeLive."

  # OTP prepends primary filters. Install before starting the endpoint so raw
  # reports are replaced before Elixir's translator and every logger handler.
  def install, do: :logger.add_primary_filter(@filter, {&__MODULE__.filter/2, nil})
  def uninstall, do: :logger.remove_primary_filter(@filter)

  def filter(%{msg: {:report, %{label: {:gen_server, :terminate}} = report}} = event, _) do
    redact_process_report(event, report[:process_label], Process.get(:"$ancestors", []))
  end

  def filter(%{msg: {:report, %{label: {:proc_lib, :crash}, report: [own, _]}}} = event, _) do
    redact_process_report(event, own[:process_label], own[:ancestors])
  end

  def filter(%{msg: {:report, %{label: {:supervisor, kind}}}} = event, _)
      when kind in [:child_terminated, :shutdown_error, :start_error] do
    # The child may already be gone. Each Phoenix socket handler owns a
    # separate pool, and its partition supervisors retain the pool ancestor.
    if staff_pool?(Process.get(:"$ancestors", [])) do
      replace(event, "Staff knowledge channel supervisor reported an abnormal child exit")
    else
      :ignore
    end
  end

  def filter(%{meta: %{mfa: {Phoenix.Channel.Server, :join, 4}}} = event, _) do
    # A crash during join can also be formatted by Phoenix in the transport
    # process. Phoenix.Socket.__init__/1 labels that process before joins.
    case :proc_lib.get_label(self()) do
      {Phoenix.Socket, StaffLiveSocket, _} ->
        replace(event, "Staff knowledge channel join crashed")

      _ ->
        :ignore
    end
  end

  def filter(_event, _), do: :ignore

  defp redact_process_report(event, {Phoenix.LiveView, view, _}, ancestors)
       when is_atom(view) do
    if String.starts_with?(Atom.to_string(view), @view_prefix) do
      replace(event, "Staff knowledge LiveView crashed (#{inspect(view)})")
    else
      redact_pool_report(event, ancestors)
    end
  end

  defp redact_process_report(event, {Phoenix.Socket, StaffLiveSocket, _}, _ancestors),
    do: replace(event, "Staff knowledge socket crashed")

  defp redact_process_report(event, _label, ancestors), do: redact_pool_report(event, ancestors)

  # A crash before LiveView labels a verified mount, or in its upload channel,
  # can still carry the join message and connect_info.
  defp redact_pool_report(event, ancestors) do
    if staff_pool?(ancestors),
      do: replace(event, "Staff knowledge channel crashed"),
      else: :ignore
  end

  defp staff_pool?(ancestors) when is_list(ancestors), do: @staff_pool in ancestors
  defp staff_pool?(_), do: false

  defp replace(event, message) do
    # Drop the reason, stack, last message, state, and any report/Logger
    # metadata that can contain the same data. Retain OTP log bookkeeping only.
    %{event | msg: {:string, message}, meta: Map.take(event.meta, [:time, :pid, :gl])}
  end
end
