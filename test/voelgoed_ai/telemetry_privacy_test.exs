defmodule VoelgoedAi.TelemetryPrivacyTest do
  use ExUnit.Case, async: false

  alias VoelgoedAi.Repo
  alias VoelgoedAiWeb.StaffSession

  @framework_prefixes [
    [:phoenix, :socket_connected],
    [:phoenix, :channel_joined],
    [:phoenix, :channel_handled_in],
    [:phoenix, :endpoint],
    [:phoenix, :router_dispatch],
    [:phoenix, :error_rendered],
    [:phoenix, :live_view],
    [:phoenix, :live_component]
  ]
  @staff_denied [:voelgoed_ai, :staff_auth, :denied]

  test "booted telemetry accepts only reviewed framework subscribers" do
    assert unexpected_handlers() == []
  end

  test "inventory detects extra subscribers including span exceptions" do
    for event <- [
          [:phoenix, :socket_connected],
          [:phoenix, :live_view, :mount, :exception],
          repo_prefix() ++ [:query],
          @staff_denied
        ] do
      id = {__MODULE__, make_ref()}
      assert :ok = :telemetry.attach(id, event, &__MODULE__.ignore/4, nil)

      try do
        assert unexpected_handlers() == [event]
      after
        :telemetry.detach(id)
      end
    end

    assert unexpected_handlers() == []
  end

  test "a familiar framework ID cannot hide a replacement callback" do
    for {logger, event} <- [
          {Phoenix.Logger, [:phoenix, :socket_connected]},
          {Phoenix.LiveView.Logger, [:phoenix, :live_view, :mount, :start]}
        ] do
      id = {logger, event}
      [original] = Enum.filter(:telemetry.list_handlers(event), &(&1.id == id))
      assert :ok = :telemetry.detach(id)

      try do
        assert :ok = :telemetry.attach(id, event, &__MODULE__.ignore/4, nil)
        assert unexpected_handlers() == [event]
      after
        :telemetry.detach(id)
        :ok = :telemetry.attach(id, event, original.function, original.config)
      end
    end

    event = repo_prefix() ++ [:query]
    id = {Phoenix.Logger, event}
    assert :ok = :telemetry.attach(id, event, &__MODULE__.ignore/4, nil)

    try do
      assert unexpected_handlers() == [event]
    after
      :telemetry.detach(id)
    end
  end

  test "staff denial diagnostics carry count, bounded reason and generated correlation only" do
    id = {__MODULE__, make_ref()}
    assert :ok = :telemetry.attach(id, @staff_denied, &__MODULE__.classify_denial/4, self())

    try do
      StaffSession.record_denial(:invalid_csrf)
      assert_received :bounded_staff_denial
      refute_received :unexpected_staff_denial
    after
      :telemetry.detach(id)
    end
  end

  def ignore(_, _, _, _), do: :ok

  def classify_denial(_, measurements, metadata, destination) do
    bounded? =
      measurements == %{count: 1} and map_size(metadata) == 2 and
        metadata[:reason] == :invalid_csrf and
        match?({:ok, _}, Ecto.UUID.cast(metadata[:correlation_id]))

    send(destination, if(bounded?, do: :bounded_staff_denial, else: :unexpected_staff_denial))
  end

  defp repo_prefix, do: Keyword.fetch!(Repo.config(), :telemetry_prefix)

  defp unexpected_handlers do
    prefixes =
      Enum.uniq(
        @framework_prefixes ++
          [
            [:voelgoed_ai, :repo],
            repo_prefix(),
            [:voelgoed_ai, :staff_auth],
            [:voelgoed_ai, :support]
          ]
      )

    for prefix <- prefixes,
        %{id: id, event_name: event, function: callback} <- :telemetry.list_handlers(prefix),
        not allowed_logger?(id, event, callback),
        do: event
  end

  defp allowed_logger?({Phoenix.Logger, event}, event, callback) do
    {event, callback} in [
      {[:phoenix, :socket_connected], &Phoenix.Logger.phoenix_socket_connected/4},
      {[:phoenix, :channel_joined], &Phoenix.Logger.phoenix_channel_joined/4},
      {[:phoenix, :channel_handled_in], &Phoenix.Logger.phoenix_channel_handled_in/4},
      {[:phoenix, :endpoint, :start], &Phoenix.Logger.phoenix_endpoint_start/4},
      {[:phoenix, :endpoint, :stop], &Phoenix.Logger.phoenix_endpoint_stop/4},
      {[:phoenix, :router_dispatch, :start], &Phoenix.Logger.phoenix_router_dispatch_start/4},
      {[:phoenix, :error_rendered], &Phoenix.Logger.phoenix_error_rendered/4}
    ]
  end

  defp allowed_logger?(
         {Phoenix.LiveView.Logger, event},
         [:phoenix, type, lifecycle, suffix] = event,
         callback
       ) do
    {type, lifecycle, suffix, callback} in [
      {:live_view, :mount, :start, &Phoenix.LiveView.Logger.lv_mount_start/4},
      {:live_view, :mount, :stop, &Phoenix.LiveView.Logger.lv_mount_stop/4},
      {:live_view, :handle_params, :start, &Phoenix.LiveView.Logger.lv_handle_params_start/4},
      {:live_view, :handle_params, :stop, &Phoenix.LiveView.Logger.lv_handle_params_stop/4},
      {:live_view, :handle_event, :start, &Phoenix.LiveView.Logger.lv_handle_event_start/4},
      {:live_view, :handle_event, :stop, &Phoenix.LiveView.Logger.lv_handle_event_stop/4},
      {:live_component, :handle_event, :start, &Phoenix.LiveView.Logger.lc_handle_event_start/4},
      {:live_component, :handle_event, :stop, &Phoenix.LiveView.Logger.lc_handle_event_stop/4}
    ]
  end

  defp allowed_logger?(_id, _event, _callback), do: false
end
