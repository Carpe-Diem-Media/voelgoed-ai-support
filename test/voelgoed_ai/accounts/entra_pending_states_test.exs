defmodule VoelgoedAi.Accounts.EntraPendingStatesTest do
  # The store is a named singleton shared with the staff route tests.
  use ExUnit.Case, async: false

  alias VoelgoedAi.Accounts.EntraPendingStates
  alias VoelgoedAi.StaffFixtures

  setup do
    original = :sys.get_state(EntraPendingStates)
    on_exit(fn -> :sys.replace_state(EntraPendingStates, fn _ -> original end) end)
  end

  test "queued consumers of one state get exactly one success" do
    state = unique_state()
    assert :ok = EntraPendingStates.remember(state)
    consumers = 20

    # Queue every call before the server handles any, so a check-then-delete
    # implementation would answer all of the checks first.
    :sys.suspend(EntraPendingStates)

    tasks =
      try do
        tasks = for _ <- 1..consumers, do: Task.async(fn -> EntraPendingStates.consume(state) end)
        wait_for_queue(consumers)
        tasks
      after
        :sys.resume(EntraPendingStates)
      end

    assert tasks |> Task.await_many() |> Enum.frequencies() == %{
             true => 1,
             false => consumers - 1
           }
  end

  test "the store refuses new states at the cap until space is freed" do
    state = unique_state()

    StaffFixtures.with_full_pending_states(fn ->
      assert EntraPendingStates.remember(state) == {:error, :pending_limit}
      refute EntraPendingStates.consume(state)

      :sys.replace_state(EntraPendingStates, &Map.delete(&1, &1 |> Map.keys() |> hd()))
      assert :ok = EntraPendingStates.remember(state)
      assert EntraPendingStates.consume(state)
    end)
  end

  defp unique_state, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp wait_for_queue(count) do
    case Process.info(Process.whereis(EntraPendingStates), :message_queue_len) do
      {:message_queue_len, queued} when queued >= count ->
        :ok

      _ ->
        Process.sleep(5)
        wait_for_queue(count)
    end
  end
end
