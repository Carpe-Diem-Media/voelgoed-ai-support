defmodule VoelgoedAi.DurableFeasibilityTest do
  use ExUnit.Case, async: false

  alias VoelgoedAi.Feasibility.{DurableLedger, TransportEvidence}
  alias VoelgoedAi.Repo

  @day ~D[2026-11-30]
  @luna "gpt-6-luna"
  @embedding "text-embedding-3-small"

  setup do
    assert %{rows: [["vgas_test", "vgas_test"]]} =
             Repo.query!("SELECT current_database(), current_user")

    ledger = DurableLedger.create!()
    on_exit(fn -> DurableLedger.drop!(ledger) end)
    %{ledger: ledger}
  end

  test "concurrent callers use distinct backend connections and cannot overspend", %{
    ledger: ledger
  } do
    owner = self()

    workers =
      for id <- 1..4 do
        Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:ready, self(), pid})

            receive do: (:go ->
                           reserve(ledger, id, @day, daily: 100, monthly: 100, concurrent: 4))
          end)
        end)
      end

    pids =
      for _ <- workers do
        assert_receive {:ready, _worker, backend}, 3000
        backend
      end

    assert length(Enum.uniq(pids)) == 4
    Enum.each(workers, &send(&1.pid, :go))
    results = Task.await_many(workers)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :budget})) == 3
  end

  test "daily, monthly, concurrency and zero caps deny before invoking transport", %{
    ledger: ledger
  } do
    assert :ok = reserve(ledger, 1)

    assert {:error, :concurrency} =
             reserve(ledger, 2, @day, daily: 500, monthly: 500, concurrent: 1)

    assert {:error, :budget} = reserve(ledger, 2, @day, daily: 70, monthly: 500, concurrent: 4)
    assert {:error, :budget} = reserve(ledger, 2, @day, daily: 500, monthly: 0, concurrent: 4)
    assert {:error, :duplicate} = reserve(ledger, 1)

    assert {:error, :storage_unavailable} =
             TransportEvidence.run(
               DurableLedger.missing(ledger),
               9,
               @day,
               @luna,
               limits(),
               fn _ ->
                 flunk("storage failure invoked transport")
               end
             )

    assert {:error, :budget} =
             TransportEvidence.run(
               ledger,
               9,
               @day,
               @luna,
               [daily: 0, monthly: 0, concurrent: 1],
               fn _ ->
                 flunk("budget denial invoked transport")
               end
             )
  end

  test "uncertain execution survives worker death and crosses month rollover", %{ledger: ledger} do
    pid =
      spawn(fn ->
        :ok = reserve(ledger, 1)
        :ok = DurableLedger.claim(ledger, 1)
        Process.sleep(:infinity)
      end)

    await_state(ledger, 1, "dispatching")
    stop_worker(pid)
    assert {:ok, "unknown"} = DurableLedger.recover(ledger, 1)

    assert {:error, :budget} =
             reserve(ledger, 2, ~D[2026-12-01], daily: 100, monthly: 100, concurrent: 3)

    assert {:error, :already_claimed} = DurableLedger.reject_before_send(ledger, 1)
  end

  test "committed reservation and captured usage recover across worker death", %{ledger: ledger} do
    pid =
      spawn(fn ->
        :ok = reserve(ledger, 1)
        Process.sleep(:infinity)
      end)

    await_state(ledger, 1, "reserved")
    stop_worker(pid)
    assert {:ok, "released"} = DurableLedger.recover(ledger, 1)
    assert {:error, :duplicate} = reserve(ledger, 1)

    pid =
      spawn(fn ->
        :ok = reserve(ledger, 2)
        :ok = DurableLedger.claim(ledger, 2)
        :ok = DurableLedger.record(ledger, 2, %{"status" => 200, "charge" => 25})
        Process.sleep(:infinity)
      end)

    await_evidence(ledger, 2)
    stop_worker(pid)
    assert {:ok, "settled"} = DurableLedger.recover(ledger, 2)
    assert {:ok, "settled"} = DurableLedger.recover(ledger, 2)
    assert %{state: "settled", actual: 25} = DurableLedger.fetch(ledger, 2)
  end

  test "overage records actual charge and inhibits other calls", %{ledger: ledger} do
    assert :ok = reserve(ledger, 1)
    assert :ok = DurableLedger.claim(ledger, 1)
    assert :ok = DurableLedger.record(ledger, 1, %{"status" => 200, "charge" => 80})
    assert {:ok, "settled"} = DurableLedger.recover(ledger, 1)
    assert {:error, :inhibited} = reserve(ledger, 2, ~D[2026-12-01])
  end

  test "late trusted evidence can reconcile an unknown attempt only once", %{ledger: ledger} do
    assert :ok = reserve(ledger, 1)
    assert :ok = DurableLedger.claim(ledger, 1)
    assert {:ok, "unknown"} = DurableLedger.recover(ledger, 1)
    assert :ok = DurableLedger.record(ledger, 1, %{"status" => 200, "charge" => 24})

    assert {:error, :already_recorded} =
             DurableLedger.record(ledger, 1, %{"status" => 200, "charge" => 25})

    results =
      1..4
      |> Task.async_stream(fn _ -> DurableLedger.recover(ledger, 1) end)
      |> Enum.to_list()

    assert results == List.duplicate({:ok, {:ok, "settled"}}, 4)
    assert %{state: "settled", actual: 24} = DurableLedger.fetch(ledger, 1)
  end

  test "a nested transaction cannot run a transport callback", %{ledger: ledger} do
    assert {:ok, {:error, :open_transaction}} =
             Repo.transaction(fn ->
               TransportEvidence.run(ledger, 1, @day, @luna, limits(), fn _ ->
                 flunk("an uncommitted attempt reached transport")
               end)
             end)

    assert DurableLedger.fetch(ledger, 1) == nil
  end

  test "generation and embedding ceilings fail closed for unapproved models" do
    assert {:ok, 525_375_000} = TransportEvidence.ceiling(@luna)
    assert {:ok, 163_840} = TransportEvidence.ceiling(@embedding)
    assert {:error, :unpriced_model} = TransportEvidence.ceiling("unknown")
  end

  defp reserve(ledger, id, day \\ @day, limits \\ limits()),
    do: DurableLedger.reserve(ledger, id, day, @luna, 75, limits)

  defp limits, do: [daily: 1_000_000_000, monthly: 2_000_000_000, concurrent: 4]

  defp await_state(ledger, id, state),
    do: await(fn -> match?(%{state: ^state}, DurableLedger.fetch(ledger, id)) end)

  defp await_evidence(ledger, id),
    do: await(fn -> match?(%{evidence: %{"charge" => 25}}, DurableLedger.fetch(ledger, id)) end)

  defp await(check, retries \\ 100)
  defp await(_check, 0), do: flunk("worker did not commit expected state")

  defp await(check, retries) do
    unless check.() do
      Process.sleep(10)
      await(check, retries - 1)
    end
  end

  defp stop_worker(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 3000
  end
end
