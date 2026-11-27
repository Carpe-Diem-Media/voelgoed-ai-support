defmodule VoelgoedAiWeb.StaffKnowledgeCrashFilterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VoelgoedAiWeb.KnowledgeLive.CrashLog

  test "malformed reports do not remove the primary filter" do
    report = %{label: {:proc_lib, :crash}, report: [:malformed, []]}
    event = %{level: :error, msg: {:report, report}, meta: %{pid: self()}}

    Process.set_label({Phoenix.Socket, VoelgoedAiWeb.StaffLiveSocket, :test})

    log = capture_log(fn -> :logger.error(report) end)
    filters = :logger.get_primary_config().filters
    assert Keyword.has_key?(filters, :vgas_staff_knowledge_crash_log), "OTP removed the filter"
    assert log =~ "Staff crash report redacted"

    assert %{msg: {:string, "Staff crash report redacted"}, meta: %{pid: pid}} =
             CrashLog.filter(event, nil)

    assert pid == self()

    Process.set_label(:non_staff)

    for malformed <- [event, %{msg: :unexpected}, :not_a_log_event] do
      assert CrashLog.filter(malformed, nil) == :ignore
    end
  end

  test "gap view, transport and channel pool redact synthetic crash details" do
    alias VoelgoedAiWeb.{Endpoint, GapLive, GapLiveSocket}

    for {label, ancestors} <- [
          {{Phoenix.LiveView, GapLive, :synthetic_private}, []},
          {{Phoenix.Socket, GapLiveSocket, :synthetic_private}, []},
          {nil, [Module.concat(Endpoint, GapLiveSocket)]}
        ] do
      event = %{
        msg:
          {:report,
           %{
             label: {:proc_lib, :crash},
             report: [
               %{process_label: label, ancestors: ancestors, reason: :synthetic_private},
               []
             ]
           }},
        meta: %{pid: self(), sensitive: :synthetic_private}
      }

      assert %{msg: {:string, safe}, meta: %{pid: _} = metadata} = CrashLog.filter(event, nil)
      assert safe =~ "crashed"
      refute safe =~ "synthetic_private"
      refute Map.has_key?(metadata, :sensitive)
    end
  end
end
