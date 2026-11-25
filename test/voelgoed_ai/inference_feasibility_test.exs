defmodule VoelgoedAi.InferenceFeasibilityTest do
  use ExUnit.Case, async: true

  alias VoelgoedAi.Feasibility.{Inference, Reservations}

  @day ~D[2026-11-25]
  @input "Synthetic FAQ"

  setup do
    %{budget: start_supervised!({Reservations, daily: 100_000, monthly: 120_000, concurrent: 2})}
  end

  test "reserves before generation and settles usage even when the proposal is invalid", %{
    budget: budget
  } do
    for {id, object, expected} <- [
          {1, %{"result" => %{"decision" => "handoff"}}, {:ok, :handoff}},
          {2, %{"result" => %{"decision" => "handoff", "extra" => 1}},
           {:error, :invalid_proposal}},
          {3, %{"result" => %{"decision" => "send"}}, {:error, :invalid_proposal}}
        ] do
      assert Inference.run(budget, id, @day, :generation, @input, fn request ->
               assert Reservations.fetch(budget, id).status == :reserved
               assert request.model == "openai:gpt-6-luna"
               assert request.options[:reasoning_effort] == :none
               assert request.options[:max_completion_tokens] == 500
               assert request.options[:total_timeout] == 5_000
               assert request.options[:max_retries] == 0
               assert request.options[:provider_options][:store] == false

               {:ok,
                %{
                  object: object,
                  request_id: "synthetic-response",
                  usage: %{input_tokens: 10, output_tokens: 5}
                }}
             end) == expected

      assert %{status: :settled, actual: 60, request_id: "synthetic-response"} =
               Reservations.fetch(budget, id)

      assert {:error, :terminal} = Reservations.finish(budget, id, {:settle, 60, "duplicate"})
    end
  end

  test "embedding timeout holds the reservation and the same attempt cannot send again", %{
    budget: budget
  } do
    owner = self()

    # Inference rescues anything raised inside the transport as an ambiguous
    # outcome, which this test also expects. Assert on the captured request
    # here instead, so a failed assertion cannot be swallowed.
    assert {:error, :unknown} =
             Inference.run(budget, 1, @day, :embedding, @input, fn request ->
               send(owner, {:sent, request, Reservations.fetch(budget, 1).status})
               {:error, :timeout}
             end)

    assert_received {:sent, request, :reserved}
    assert request.model == "openai:text-embedding-3-small"
    assert request.options[:dimensions] == 1536
    assert request.options[:req_http_options][:max_retries] == 0

    assert %{status: :unknown, ceiling: ceiling} = Reservations.fetch(budget, 1)
    assert ceiling > 0

    assert {:error, :duplicate} =
             Inference.run(budget, 1, @day, :embedding, @input, fn _ -> flunk("repeat send") end)
  end

  test "known no-send releases, but missing usage remains unknown", %{budget: budget} do
    assert {:error, :not_sent} =
             Inference.run(budget, 1, @day, :embedding, @input, fn _ -> {:error, :not_sent} end)

    assert Reservations.fetch(budget, 1).status == :released

    assert {:error, :unknown} =
             Inference.run(budget, 2, @day, :embedding, @input, fn _ ->
               {:ok, %{object: List.duplicate(0.0, 1536), usage: %{}}}
             end)

    assert Reservations.fetch(budget, 2).status == :unknown
  end

  test "embedding success settles trusted input usage, and denied work invokes no transport" do
    budget =
      start_supervised!({Reservations, [daily: 9000, monthly: 9000, concurrent: 1]},
        id: :embedding
      )

    vector = List.duplicate(0.25, 1536)

    assert {:ok, ^vector} =
             Inference.run(budget, 1, @day, :embedding, @input, fn _ ->
               assert Reservations.fetch(budget, 1).status == :reserved

               {:ok,
                %{object: vector, request_id: "embedding-synthetic", usage: %{input_tokens: 500}}}
             end)

    assert %{status: :settled, actual: 1000} = Reservations.fetch(budget, 1)

    assert {:error, :budget} =
             Inference.run(budget, 2, @day, :embedding, @input, fn _ ->
               flunk("denied attempt reached the transport")
             end)
  end

  test "oversized input is rejected before reservation", %{budget: budget} do
    assert {:error, :input_limit} =
             Inference.run(budget, 1, @day, :generation, String.duplicate("a", 4097), fn _ ->
               flunk("oversized input reached transport")
             end)

    assert Reservations.fetch(budget, 1) == nil
  end

  test "parallel admission cannot overspend, and unknown cost carries into a new month" do
    budget =
      start_supervised!({Reservations, [daily: 100, monthly: 100, concurrent: 8]}, id: :parallel)

    results =
      1..8
      |> Task.async_stream(&Reservations.reserve(budget, &1, @day, 75))
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :budget})) == 7
    winning_id = Enum.find(1..8, &Reservations.fetch(budget, &1))
    assert :ok = Reservations.finish(budget, winning_id, :unknown)
    assert {:error, :budget} = Reservations.reserve(budget, :next, ~D[2026-12-01], 30)
    assert :ok = Reservations.finish(budget, winning_id, {:settle, 80, "trusted-late-result"})
    assert :ok = Reservations.reserve(budget, :next, ~D[2026-12-01], 30)
  end

  test "concurrency cap, zero budget and actual overspend inhibit calls", %{budget: budget} do
    assert :ok = Reservations.reserve(budget, 1, @day, 1)
    assert :ok = Reservations.reserve(budget, 2, @day, 1)
    assert {:error, :concurrency} = Reservations.reserve(budget, 3, @day, 1)
    assert :ok = Reservations.finish(budget, 1, {:settle, 100_001, "trusted-overage"})
    assert {:error, :budget} = Reservations.reserve(budget, 3, @day, 1)
    zero = start_supervised!({Reservations, [daily: 0, monthly: 1, concurrent: 1]}, id: :zero)
    assert {:error, :budget} = Reservations.reserve(zero, 1, @day, 1)
  end
end
