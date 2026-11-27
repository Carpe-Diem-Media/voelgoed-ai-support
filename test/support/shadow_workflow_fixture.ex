defmodule VoelgoedAi.ShadowWorkflowFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import VoelgoedAi.KnowledgeFixtures
  import VoelgoedAi.SupportFixtures, only: [allow_fixture: 2, invoke: 4]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}
  alias VoelgoedAi.Intelligence.{AssistantRevision, Embedding, EmbeddingTransport}
  alias VoelgoedAi.Knowledge.{Article, ArticleRevision}
  alias VoelgoedAi.Knowledge.Workers.FinalizePublication
  alias VoelgoedAi.Support.{ChatwootAdapter, RunProcessing}
  alias VoelgoedAi.Support.Workers.{Deliver, ProcessEvent, ProcessRun, Reconcile, Sweep}

  def setup_faq(locale, mode, opts \\ []) do
    staff = setup_knowledge(%{embedding_index: true})
    fixture(%{})
    collection = collection(staff)
    raw = Map.put(payload(), "response_mode", mode)
    target = publish(staff, collection, Keyword.get(opts, :content, & &1).(raw))

    decoy =
      if opts[:decoy] do
        publish(staff, collection, opts[:decoy].(raw), "-DECOY")
      end

    support =
      SupportDBCase.setup(
        staff: {staff, staff.admin, nil},
        shadow: locale,
        enable: Keyword.get(opts, :enable, true),
        before_publish: fn admin, revision ->
          assert {:ok, _} =
                   invoke(
                     AssistantRevision,
                     :grant_collection,
                     %{id: revision.id, collection_id: collection.id},
                     admin
                   )
        end
      )

    {:ok, hits} = Agent.start_link(fn -> %{embedding: 0, generation: 0} end)
    on_exit(fn -> if Process.alive?(hits), do: Agent.stop(hits) end)

    %{support: support, staff: staff, target: target, decoy: decoy, hits: hits, locale: locale}
  end

  def configure(ctx, opts \\ []) do
    embed = Keyword.get(opts, :embedding, &EmbeddingTransport.fixture_wire/1)

    fixture(%{
      wire: fn request ->
        Agent.update(ctx.hits, &Map.update!(&1, :embedding, fn value -> value + 1 end))
        embed.(request)
      end,
      clock: fn -> ChatwootAdapter.now() end
    })

    settings =
      case Keyword.get(opts, :generation) do
        nil ->
          %{}

        gen ->
          %{
            generation_wire: fn request ->
              Agent.update(ctx.hits, &Map.update!(&1, :generation, fn value -> value + 1 end))
              gen.(request)
            end
          }
      end

    allow_fixture(
      ctx.support.assistant,
      Map.put(ChatwootAdapter.fixture(), :shadow_inference, settings)
    )
  end

  def publish(staff, collection, raw, suffix \\ "") do
    args = draft_args(staff, collection)

    args = %{
      args
      | article_ref: args.article_ref <> suffix,
        slug: args.slug <> String.downcase(suffix),
        content: raw
    }

    assert {:ok, %{revision: draft}} = invoke(Article, :create_draft, args, staff.editor)
    reviewed = review(staff, draft)

    assert {:ok, target} =
             invoke(ArticleRevision, :approve, attest(snapshot(reviewed)), staff.reviewer)

    for id <- request_index(staff, target), do: assert(:ok = Embedding.index(id))

    assert :ok =
             FinalizePublication.perform(%Oban.Job{
               args: %{"revision_id" => target.id, "generation" => 1}
             })

    assert %{rows: [["published"]]} =
             SQL.query!(Repo, "SELECT status FROM article_revisions WHERE id = $1", [
               uuid(target.id)
             ])

    target
  end

  def question(:af), do: "Sintetiese vrae"
  def question(:en), do: "Synthetic FAQ"

  def approved(:af), do: "Sintetiese antwoord."
  def approved(:en), do: "Synthetic answer."

  def paraphrase(:af), do: "Hier is die sintetiese antwoord."
  def paraphrase(:en), do: "Here is the synthetic answer."

  def put_text(ctx, id, text) do
    Agent.update(ctx.support.fake, fn state ->
      Map.update(
        state,
        :decision_messages,
        %{id => %{text: text}},
        &Map.put(&1, id, %{text: text})
      )
    end)
  end

  def queue(ctx, text, offset \\ 0) do
    id = ctx.support.event.message_id + offset
    if offset > 0, do: SupportDBCase.append_public_input(ctx.support, id)
    put_text(ctx, id, text)
    support = %{ctx.support | event: %{ctx.support.event | message_id: id}}
    assert {:ok, receipt} = SupportDBCase.signed_receipt(support)
    assert :ok = ProcessEvent.perform(job("event_id", receipt.id))

    assert %{rows: [[run_id]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM support_runs WHERE session_id = $1 ORDER BY id DESC LIMIT 1",
               [uuid(SupportDBCase.session_id(ctx.support))]
             )

    on_exit(fn ->
      SQL.query!(
        Repo,
        "DELETE FROM oban_jobs WHERE args->>'generation_id' IN (SELECT id::text FROM inference_runs WHERE support_run_id = $1)",
        [uuid(run_id)]
      )

      cleanup_query_attempts(run_id)
    end)

    SupportDBCase.advance_clock(ctx.support, 2)
    run_id
  end

  def run(id) do
    assert {:ok, row} = RunProcessing.with_run(id, fn _, _, row, _ -> {:ok, row} end)
    row
  end

  def perform(id), do: ProcessRun.perform(job("run_id", id))

  def job(key, id), do: %Oban.Job{args: %{key => id}}

  def attempts(id) do
    SQL.query!(
      Repo,
      """
      SELECT i.purpose, i.state, i.input_tokens, i.output_tokens, h.state,
             h.actual_nano_usd, h.reserved_nano_usd
      FROM inference_runs i JOIN usage_reservations h ON h.inference_run_id = i.id
      WHERE i.support_run_id = $1 ORDER BY i.started_at, i.id
      """,
      [uuid(id)]
    ).rows
  end

  def committed_before_wire(id, purpose, backend \\ nil) do
    refute Repo.in_transaction?()

    assert %{rows: [[true, "reserved", "running"]]} =
             SQL.query!(
               Repo,
               """
               SELECT dispatched_at IS NOT NULL, h.state, i.state
               FROM inference_runs i JOIN usage_reservations h ON h.inference_run_id = i.id
               WHERE i.support_run_id = $1 AND i.purpose = $2
               """,
               [uuid(id), purpose]
             )

    if backend do
      assert %{rows: [["idle", true]]} =
               SQL.query!(
                 Repo,
                 "SELECT state, xact_start IS NULL FROM pg_stat_activity WHERE pid = $1",
                 [backend]
               )
    end
  end

  def response(request, ctx, changes \\ %{}, overrides \\ %{}) do
    proposal = %{
      "schema_version" => 1,
      "decision" => "answer_grounded",
      "locale" => to_string(ctx.locale) <> "-ZA",
      "reason_code" => "supported",
      "evidence_revision_ids" => [ctx.target.id],
      "reply_text" => paraphrase(ctx.locale)
    }

    fields = %{
      "id" => "resp_synthetic_" <> Ash.UUIDv7.generate(),
      "model" => "gpt-6-luna",
      "status" => "completed",
      "output" => [
        %{
          "id" => "msg_synthetic",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" => Jason.encode!(%{"result" => Map.merge(proposal, changes)})
            }
          ]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    }

    {request,
     Req.Response.new(
       status: 200,
       body: fields |> Map.merge(overrides) |> Jason.encode!(),
       headers: [
         {"x-request-id", "req_" <> Ash.UUIDv7.generate()},
         {"content-type", "application/json"}
       ]
     )}
  end

  def wire_payload(request) do
    assert %{
             "model" => "gpt-6-luna",
             "store" => false,
             "max_output_tokens" => 500,
             "input" => [
               %{"role" => "system"},
               %{"role" => "user", "content" => [%{"text" => text}]}
             ]
           } = request.body |> IO.iodata_to_binary() |> Jason.decode!()

    Jason.decode!(text)
  end

  def assert_no_writes(ctx) do
    assert %{rows: deliveries} = SupportDBCase.delivery_rows(ctx.support, "id::text, purpose")

    for [id, purpose] <- deliveries do
      assert purpose == "handoff_status"
      assert :ok = Sweep.perform(job("delivery_id", id))
      assert :ok = Deliver.perform(job("delivery_id", id))
      assert :ok = Reconcile.perform(job("delivery_id", id))
      assert :ok = Sweep.perform(job("delivery_id", id))
    end

    assert [] = SupportDBCase.writes(ctx.support)
  end

  def revoke(ctx) do
    assert {:ok, %{status: :revoked}} =
             invoke(
               ArticleRevision,
               :revoke,
               Map.put(snapshot(ctx.target), :reason, :obsolete),
               ctx.staff.reviewer
             )
  end

  def uuid(id), do: Ecto.UUID.dump!(id)
end
