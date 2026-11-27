defmodule VoelgoedAi.KnowledgeFeasibilityTest do
  use ExUnit.Case, async: false

  alias VoelgoedAi.Feasibility.{DurableLedger, Knowledge}
  alias VoelgoedAi.Repo

  @moduletag skip: System.get_env("VGAS_F04_DISPOSABLE") != "1"
  @now ~U[2026-11-25 12:00:00Z]
  @profile "openai:text-embedding-3-small/1536/cosine/v1"
  @other_profile "synthetic-incompatible-profile"

  setup do
    assert Repo.config()[:hostname] == "127.0.0.1"
    assert Repo.config()[:port] in [55434, 55436, 55437]

    assert %{
             rows: [
               ["vgas_test", "vgas_test", "180007", "0.8.7", false, false, false, false, false]
             ]
           } =
             Repo.query!("""
             SELECT current_database(), current_user, current_setting('server_version_num'),
               (SELECT extversion FROM pg_extension WHERE extname = 'vector'),
               rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
             FROM pg_roles WHERE rolname = current_user
             """)

    store = Knowledge.create!()
    ledger = DurableLedger.create!()

    on_exit(fn ->
      Knowledge.drop!(store)
      DurableLedger.drop!(ledger)
    end)

    Knowledge.collection!(store, 1, true, true, true)
    %{store: store, ledger: ledger}
  end

  test "approval, background claims and publication have independent guards", %{
    store: store,
    ledger: ledger
  } do
    add(store, 1, 1, 1, "card renewal", "kaart hernuwing")
    assert :ok = Knowledge.edit(store, 1, content("card replacement", "kaart vervanging"))
    assert {:error, :not_approved} = Knowledge.queue(store, 1, @profile, :reviewer)
    assert DurableLedger.fetch(ledger, 1) == nil
    assert :ok = Knowledge.submit(store, 1, :editor)
    assert {:error, :forbidden} = Knowledge.approve(store, 1, :editor)
    assert :ok = Knowledge.approve(store, 1, :reviewer)
    assert {:error, :immutable} = Knowledge.edit(store, 1, content("other", "ander"))
    assert {:error, :forbidden} = Knowledge.queue(store, 1, @profile, :worker)
    assert {:ok, [english, afrikaans]} = Knowledge.queue(store, 1, @profile, :reviewer)
    assert [english.locale, afrikaans.locale] == ["af-ZA", "en-ZA"]
    assert {:error, :not_approved} = Knowledge.queue(store, 1, @profile, :reviewer)
    assert {:error, :not_ready} = Knowledge.publish(store, 1, nil, @now, :reviewer)

    run_index(store, ledger, english, 1, vector([1]))
    assert {:error, :not_ready} = Knowledge.publish(store, 1, nil, @now, :reviewer)
    run_index(store, ledger, afrikaans, 2, vector([1]))
    assert {:error, :forbidden} = Knowledge.publish(store, 1, nil, @now, :worker)
    assert %{selected: [], decision: :clarify} = search(store, "card", [1])
    assert :ok = Knowledge.publish(store, 1, nil, @now, :reviewer)
    assert %{selected: [1]} = search(store, "card", [1])
    assert {:error, :stale} = Knowledge.claim(store, english)
  end

  test "invalid and stale indexing leave the old publication eligible", %{
    store: store,
    ledger: ledger
  } do
    add(store, 1, 1, 1, "badge access", "kenteken toegang")
    publish_fixture(store, ledger, 1, 1, 1)

    add(store, 2, 1, 1, "badge access update", "kenteken toegang nuut")
    approve(store, 2)
    assert {:ok, [job, _]} = Knowledge.queue(store, 2, @profile, :reviewer)
    assert {:error, :stale} = Knowledge.claim(store, %{job | hash: "wrong"})
    assert {:error, :stale} = Knowledge.claim(store, %{job | text: "changed"})
    assert {:error, :stale} = Knowledge.claim(store, %{job | profile: @other_profile})
    assert :ok = Knowledge.claim(store, job)
    assert {:error, :invalid_vector} = Knowledge.finish(store, job, [1.0])
    assert {:error, :not_ready} = Knowledge.publish(store, 2, 1, @now, :reviewer)
    assert %{selected: [1]} = search(store, "badge", [1])

    assert {:ok, [retry_job, _]} = Knowledge.queue(store, 2, @profile, :reviewer)
    assert :ok = Knowledge.claim(store, retry_job)
    assert {:error, :stale} = Knowledge.finish(store, job, vector([1]))

    assert {:error, :invalid_vector} =
             Knowledge.finish(store, retry_job, [:nan | tl(vector([1]))])

    assert {:error, %Postgrex.Error{}} = Repo.query("SELECT '[NaN]'::vector", [], log: false)

    assert {:ok, jobs} = Knowledge.queue(store, 2, @profile, :reviewer)

    Enum.with_index(jobs, 20)
    |> Enum.each(fn {j, id} -> run_index(store, ledger, j, id, vector([1])) end)

    assert {:error, :stale_pointer} = Knowledge.publish(store, 2, nil, @now, :reviewer)
    assert :ok = Knowledge.publish(store, 2, 1, @now, :reviewer)
    assert %{selected: [2], vector: [2], lexical: [2]} = search(store, "badge", [1])

    add(store, 3, 1, 1, "badge access newer", "kenteken toegang meer")
    approve(store, 3)
    assert {:ok, [pending, _]} = Knowledge.queue(store, 3, @profile, :reviewer)
    assert :ok = Knowledge.claim(store, pending)
    assert :ok = Knowledge.revoke(store, 3, :reviewer)
    assert {:error, :stale} = Knowledge.finish(store, pending, vector([1]))
    assert {:error, :not_ready} = Knowledge.publish(store, 3, 2, @now, :reviewer)
    assert %{selected: [2]} = search(store, "badge", [1])
  end

  test "competing publication switches activate only one revision", %{
    store: store,
    ledger: ledger
  } do
    for id <- 1..2 do
      add(store, id, 1, 1, "card renewal", "kaart hernuwing")
      approve(store, id)
      assert {:ok, jobs} = Knowledge.queue(store, id, @profile, :reviewer)

      Enum.with_index(jobs, id * 10)
      |> Enum.each(fn {job, attempt} -> run_index(store, ledger, job, attempt, vector([1])) end)
    end

    owner = self()

    workers =
      for id <- 1..2 do
        Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:ready, pid})
            receive do: (:go -> Knowledge.publish(store, id, nil, @now, :reviewer))
          end)
        end)
      end

    pids =
      for _ <- workers do
        assert_receive {:ready, pid}, 3000
        pid
      end

    assert length(Enum.uniq(pids)) == 2
    Enum.each(workers, &send(&1.pid, :go))
    assert Enum.sort(Task.await_many(workers)) == [:ok, {:error, :stale_pointer}]
    assert %{selected: [_]} = search(store, "card renewal", [1])
  end

  test "expired or unreserved work cannot invoke embeddings", %{store: store, ledger: ledger} do
    add(store, 1, 1, 1, "expired article", "vervalde artikel", expires: @now)
    approve(store, 1)
    assert {:ok, [expired, _]} = Knowledge.queue(store, 1, @profile, :reviewer)
    assert {:error, :not_current} = Knowledge.index(store, ledger, expired, 1, @now)
    assert DurableLedger.fetch(ledger, 1) == nil

    add(store, 2, 2, 1, "example article", "voorbeeld artikel")
    approve(store, 2)
    assert {:ok, [job, _]} = Knowledge.queue(store, 2, @profile, :reviewer)

    assert {:error, :storage_unavailable} =
             Knowledge.index(store, DurableLedger.missing(ledger), job, 2, @now)

    assert {:error, :not_ready} = Knowledge.publish(store, 2, nil, @now, :reviewer)
    assert %{selected: []} = search(store, "article", [1])
  end

  test "28 synthetic revisions and 20 labelled bilingual queries prove both rankings", %{
    store: store,
    ledger: ledger
  } do
    topics = [
      {"card renewal", "kaart hernuwing"},
      {"office directions", "kantoor aanwysings"},
      {"parcel tracking", "pakkie opsporing"},
      {"delivery appointment", "aflewering afspraak"},
      {"newsletter subscription", "nuusbrief intekening"},
      {"venue accessibility", "lokaal toeganklikheid"},
      {"event programme", "geleentheid program"},
      {"receipt copy", "kwitansie afskrif"},
      {"contact hours", "kontak ure"},
      {"pickup point", "afhaalpunt ligging"},
      {"parking permit", "parkering permit"},
      {"ticket transfer", "kaartjie oordrag"},
      {"website language", "webwerf taal"},
      {"feedback form", "terugvoer vorm"},
      {"volunteer application", "vrywilliger aansoek"},
      {"lost property", "verlore eiendom"},
      {"public transport", "openbare vervoer"},
      {"calendar reminder", "kalender herinnering"},
      {"account registration", "rekening registrasie"},
      {"password reset", "wagwoord herstel"}
    ]

    Enum.with_index(topics, 1)
    |> Enum.each(fn {{en, af}, id} ->
      add(store, id, id, 1, en, af)
      publish_fixture(store, ledger, id, id, id)
    end)

    Knowledge.collection!(store, 2, false, true, true)
    Knowledge.collection!(store, 3, true, true, false)
    Knowledge.collection!(store, 4, true, true, true)

    add(store, 21, 21, 2, "card renewal", "kaart hernuwing")
    publish_fixture(store, ledger, 21, 21, 1)
    add(store, 22, 22, 3, "card renewal", "kaart hernuwing")
    publish_fixture(store, ledger, 22, 22, 1)
    add(store, 23, 23, 4, "card renewal", "kaart hernuwing")
    publish_fixture(store, ledger, 23, 23, 1)
    Knowledge.collection!(store, 4, true, false, true)
    add(store, 24, 24, 1, "card renewal", "kaart hernuwing", expires: @now)
    publish_fixture(store, ledger, 24, 24, 1, now: DateTime.add(@now, -1, :second))
    add(store, 25, 25, 1, "card renewal", "kaart hernuwing", scope: "different-product")
    publish_fixture(store, ledger, 25, 25, 1)
    add(store, 26, 26, 1, "card renewal", "kaart hernuwing")
    publish_fixture(store, ledger, 26, 26, 1)
    assert :ok = Knowledge.revoke(store, 26, :reviewer)
    add(store, 27, 27, 1, "card renewal", "kaart hernuwing")
    publish_fixture(store, ledger, 27, 27, 1)
    # Simulate a previous profile's data after selection of the current profile.
    Repo.query!("UPDATE #{store.variants} SET profile=$1 WHERE revision=27", [@other_profile])
    add(store, 28, 28, 1, "card renewal", "kaart hernuwing")
    approve(store, 28)
    assert {:ok, jobs} = Knowledge.queue(store, 28, @profile, :reviewer)

    Enum.with_index(jobs, 280)
    |> Enum.each(fn {job, attempt} -> run_index(store, ledger, job, attempt, vector([1])) end)

    cases = [
      {"en-card", "card renewal", "en-ZA", [1], [1], [1]},
      {"af-card", "kaart hernuwing", "af-ZA", [1], [1], [1]},
      {"en-office", "office directions", "en-ZA", [2], [2], [2]},
      {"af-parcel", "pakkie opsporing", "af-ZA", [3], [3], [3]},
      {"mixed-delivery", "delivery afspraak", "en-ZA", [4], [4], [4]},
      {"af-newsletter", "nuusbrief", "af-ZA", [5], [5], [5]},
      {"en-access", "venue accessibility", "en-ZA", [6], [6], [6]},
      {"af-programme", "geleentheid", "af-ZA", [7], [7], [7]},
      {"en-receipt", "receipt", "en-ZA", [8], [8], [8]},
      {"af-hours", "kontak ure", "af-ZA", [9], [9], [9]},
      {"mixed-pickup", "pickup afhaalpunt", "af-ZA", [10], [10], [10]},
      {"typo-parking", "parkng permit", "en-ZA", [11], [11], [11]},
      {"typo-transfer", "kaartjie oordragg", "af-ZA", [12], [12], [12]},
      {"vector-only-typo", "langauge", "en-ZA", [13], [], [13]},
      {"lexical-only-feedback", "feedback", "en-ZA", [1536], [14], [14]},
      {"fused-account", "registration", "en-ZA", [15, 19], [19], [19, 15]},
      {"af-lost", "verlore eiendom", "af-ZA", [16], [16], [16]},
      {"ambiguous", "public parking", "en-ZA", [11, 17], [], []},
      {"off-topic", "planetary geology", "en-ZA", [1536], [], []},
      {"no-relevant-af", "sterrekunde", "af-ZA", [1536], [], []}
    ]

    results =
      for {label, text, locale, features, lexical, expected} <- cases do
        scope = if label == "ambiguous", do: :unresolved, else: "public-support"
        result = search(store, text, features, locale: locale, scope: scope)
        semantic = if scope == :unresolved or features == [1536], do: [], else: features
        assert result.lexical == lexical, label
        assert result.vector == semantic, label
        assert result.selected == expected, label
        assert result.decision == if(expected == [], do: :clarify, else: :evidence)
        assert Enum.all?(result.evidence, &(&1.locale == locale and byte_size(&1.hash) == 64))

        %{
          label: label,
          expected: expected,
          results: Map.take(result, [:vector, :lexical, :selected, :duration_us])
        }
      end

    if System.get_env("VGAS_F04_EVIDENCE") == "1",
      do: IO.puts("VGAS_F05_EVIDENCE " <> Jason.encode!(results))

    # A changed grant cuts off both branches immediately, including an otherwise exact match.
    Knowledge.collection!(store, 1, true, true, false)
    assert %{vector: [], lexical: [], selected: []} = search(store, "card renewal", [1])
  end

  defp approve(store, id) do
    assert :ok = Knowledge.submit(store, id, :editor)
    assert :ok = Knowledge.approve(store, id, :reviewer)
  end

  defp add(store, id, article, collection, en, af, options \\ []) do
    Knowledge.draft!(store, id, article, collection, content(en, af), options)
  end

  defp content(en, af), do: %{"en-ZA" => en, "af-ZA" => af}

  defp publish_fixture(store, ledger, id, article, feature, options \\ []) do
    approve(store, id)
    assert {:ok, jobs} = Knowledge.queue(store, id, @profile, :reviewer)

    Enum.with_index(jobs, article * 10)
    |> Enum.each(fn {job, attempt} ->
      run_index(store, ledger, job, attempt, vector([feature]), options[:now] || @now)
    end)

    assert :ok =
             Knowledge.publish(store, id, options[:previous], options[:now] || @now, :reviewer)
  end

  defp run_index(store, ledger, job, attempt, vector, now \\ @now) do
    owner = self()

    Req.Test.expect(Knowledge, fn conn ->
      assert %{state: "dispatching"} = DurableLedger.fetch(ledger, attempt)
      refute Repo.in_transaction?()
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"dimensions" => 1536, "input" => [serialized]} = Jason.decode!(body)
      assert %{"locale" => locale, "text" => text, "scope" => _scope} = Jason.decode!(serialized)
      assert locale == job.locale and text == job.text
      send(owner, {:indexed, attempt})

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "fixture-#{attempt}")
      |> Req.Test.json(%{
        "model" => "text-embedding-3-small",
        "object" => "list",
        "data" => [%{"object" => "embedding", "index" => 0, "embedding" => vector}],
        "usage" => %{"prompt_tokens" => 12, "total_tokens" => 12}
      })
    end)

    task = Task.async(fn -> Knowledge.index(store, ledger, job, attempt, now) end)
    assert :ok = Task.await(task, 10_000)
    assert_received {:indexed, ^attempt}
    refute_received {:indexed, ^attempt}
    assert %{state: "settled", actual: 240} = DurableLedger.fetch(ledger, attempt)
  end

  defp search(store, query, dimensions, options \\ []) do
    Knowledge.search(
      store,
      query,
      vector(dimensions),
      options[:locale] || "en-ZA",
      options[:scope] || "public-support",
      @profile,
      options[:now] || @now
    )
  end

  defp vector(dimensions) do
    keys = MapSet.new(dimensions)
    Enum.map(1..1536, fn key -> if MapSet.member?(keys, key), do: 1.0, else: 0.0 end)
  end
end
