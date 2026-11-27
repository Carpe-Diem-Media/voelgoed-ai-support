defmodule VoelgoedAi.Support.ShadowDecisionTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase}

  alias VoelgoedAi.Support.{
    DecisionContext,
    DecisionTemplates,
    Ownership,
    RunProcessing,
    SupportDecision
  }

  alias VoelgoedAi.Support.ChatwootAdapter.TextMessage
  alias VoelgoedAi.Support.Workers.{Deliver, ProcessRun, Sweep}

  test "the decision cast rejects extra fields and coercion" do
    value = %{
      "schema_version" => 1,
      "decision" => "greeting",
      "locale" => "af-ZA",
      "reason_code" => "greeting",
      "evidence_revision_ids" => [],
      "reply_text" => nil
    }

    assert {:ok, decision} = SupportDecision.cast(value)
    assert decision.locale == "af-ZA"

    for invalid <- [
          Map.put(value, "target", "other"),
          %{value | "schema_version" => "1"},
          %{value | "decision" => "unsupported"},
          %{value | "locale" => "af"},
          %{value | "reason_code" => "unknown"},
          %{value | "reply_text" => "Unapproved text"}
        ] do
      assert :error = SupportDecision.cast(invalid)
    end
  end

  test "fixed decisions reject cited evidence" do
    for {outcome, reason} <- [
          {"greeting", "greeting"},
          {"handoff", "human_requested"},
          {"decline", "off_topic"}
        ] do
      assert :error =
               SupportDecision.cast(%{
                 "schema_version" => 1,
                 "decision" => outcome,
                 "locale" => "en-ZA",
                 "reason_code" => reason,
                 "evidence_revision_ids" => [Ash.UUIDv7.generate()],
                 "reply_text" => nil
               })
    end
  end

  test "publishing a shadow revision onto an automatic binding denies writes" do
    import VoelgoedAi.SupportFixtures, only: [allow_fixture: 2, invoke: 4]
    alias VoelgoedAi.Intelligence.AssistantRevision
    alias VoelgoedAi.Support.Configuration

    ctx = SupportDBCase.setup()
    id = queue(ctx, "Hello")

    workflow = %{
      workflow_version: "shadow-v1",
      template_version: "shadow-v1",
      locale: :en,
      response_policy: :shadow_decision,
      shadow_evaluation: true
    }

    allow_fixture(
      ctx.assistant,
      Map.merge(VoelgoedAi.Support.ChatwootAdapter.fixture(), workflow)
    )

    assert {:ok, revision} =
             invoke(
               AssistantRevision,
               :create_draft,
               workflow
               |> Map.delete(:shadow_evaluation)
               |> Map.put(:assistant_id, ctx.assistant.id),
               ctx.admin
             )

    assert {:ok, _} =
             invoke(
               AssistantRevision,
               :publish,
               %{id: revision.id, expected_active_revision_id: ctx.revision.id},
               ctx.admin
             )

    assert {:ok, false} =
             RunProcessing.with_run(id, fn config, _, _, _ ->
               assert config.binding.operating_mode == :automatic
               assert config.control.mode == :fake and config.control.status == :enabled

               assert {:ok, %{id: published, response_policy: :shadow_decision}} =
                        Configuration.current_revision(config.assistant)

               assert published == revision.id
               assert Ownership.permitted?(config)
               {:ok, Ownership.write_enabled?(config)}
             end)
  end

  for {locale, label, text, outcome, reason, approved} <- [
        {:af, "greeting", "Hallo!", "greeting", "greeting", "Hallo! Hoe kan ons jou help?"},
        {:en, "greeting", "Hello!", "greeting", "greeting", "Hello! How can we help you?"},
        {:af, "human request", "Mens asseblief", "handoff", "human_requested",
         "Ons ondersteuningspan kan hiermee help."},
        {:en, "human request", "Can I speak to a human?", "handoff", "human_requested",
         "Our support team can help with this."},
        {:af, "clarify", "Help asseblief", "clarify", "ambiguous", "Waarmee het jy hulp nodig?"},
        {:en, "clarify", "Please help", "clarify", "ambiguous", "What do you need help with?"},
        {:af, "decline", "Vertel my 'n grap", "decline", "off_topic",
         "Ek kan help met Voelgoed-ondersteuningsvrae."},
        {:en, "decline", "Tell me a joke", "decline", "off_topic",
         "I can help with Voelgoed support questions."},
        {:af, "unresolved", "Waar kry ek die tydskrif?", "handoff", "missing_evidence",
         "Ons ondersteuningspan kan hiermee help."},
        {:en, "unresolved", "Where can I get the magazine?", "handoff", "missing_evidence",
         "Our support team can help with this."},
        {:en, "account-specific", "Check my account balance", "handoff", "account_specific",
         "Our support team can help with this."}
      ] do
    test "#{locale} #{label} persists one typed decision with no wire writes" do
      ctx = SupportDBCase.setup(shadow: unquote(locale))
      id = queue(ctx, unquote(text))
      SupportDBCase.advance_clock(ctx, 2)
      assert :ok = perform_run(id)
      assert :ok = perform_run(id)

      assert {:ok, run} = RunProcessing.with_run(id, fn _, _, row, _ -> {:ok, row} end)
      assert run.state == :completed
      assert run.decision == :no_send
      assert run.lease_expires_at == nil

      assert %SupportDecision{schema_version: 1, evidence_revision_ids: [], reply_text: nil} =
               decision = run.typed_decision

      assert decision.locale == unquote(to_string(locale) <> "-ZA")
      assert decision.decision == unquote(outcome)
      assert decision.reason_code == unquote(reason)
      assert {:ok, unquote(approved)} = DecisionTemplates.render(decision, "shadow-v1")
      assert :error = DecisionTemplates.render(decision, "unknown")
      assert Agent.get(ctx.fake, & &1.decision_reads) == 2

      if unquote(outcome) == "handoff" do
        assert run.shadow_disposition == :local_handoff
        assert [["handoff_pending", true, epoch]] = session_rows(ctx)
        assert epoch == run.ownership_epoch + 1

        assert %{rows: [[delivery, "handoff_status", "pending"]]} =
                 SupportDBCase.delivery_rows(ctx, "id::text, purpose, state")

        assert :ok = Sweep.perform(job("delivery_id", delivery))
        assert :ok = Deliver.perform(job("delivery_id", delivery))
        assert :ok = Sweep.perform(job("delivery_id", delivery))
        assert [] = SupportDBCase.writes(ctx)

        assert %{rows: [["cancelled", "stale_policy", 0]]} =
                 SupportDBCase.delivery_rows(ctx, "state, reason_code, attempt_count")
      else
        assert run.shadow_disposition == :no_send
        assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "id")
      end

      assert [] = SupportDBCase.writes(ctx)
    end
  end

  test "shadow permission is default off and separate from write permission" do
    ctx = SupportDBCase.setup(shadow: :en, enable: false)
    first = queue(ctx, "Hello")
    assert_permissions(first, false)
    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(first)
    assert %{rows: [["completed", "no_send", nil]]} = run_row(first)
    assert Agent.get(ctx.fake, &Map.get(&1, :decision_reads, 0)) == 0

    SupportDBCase.enable_automation(ctx)
    assert_permissions(first, true)

    SupportDBCase.disable_automation(ctx)
    assert_permissions(first, false)
    assert [] = SupportDBCase.writes(ctx)
  end

  defp assert_permissions(id, shadow?) do
    assert {:ok, {^shadow?, false}} =
             RunProcessing.with_run(id, fn config, _, _, _ ->
               {:ok,
                {Ownership.shadow_evaluation_enabled?(config), Ownership.write_enabled?(config)}}
             end)
  end

  test "a completed typed decision cannot be replaced" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             SQL.query(
               Repo,
               "UPDATE support_runs SET typed_decision = NULL, shadow_disposition = NULL WHERE id = $1",
               [Ecto.UUID.dump!(id)]
             )

    assert %{rows: [["completed", "no_send", %{"decision" => "greeting"}]]} = run_row(id)
  end

  test "shadow policy cannot be switched to automatic writes" do
    ctx = SupportDBCase.setup(shadow: :en)

    assert {:error, _} =
             VoelgoedAi.SupportFixtures.invoke(
               VoelgoedAi.Support.InboxBinding,
               :change_mode,
               %{id: ctx.binding_id, operating_mode: :automatic},
               ctx.admin
             )

    assert_permissions(queue(ctx, "Hello"), true)
  end

  test "exhausted turn allowance routes locally without evaluating or writing" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(id)

    SQL.query!(
      Repo,
      "UPDATE support_admission_windows SET count = 40 WHERE scope = $1 AND window_type = 'contact_day'",
      [
        "#{ctx.event.installation_ref}:#{ctx.event.external_account_id}:contact:#{ctx.event.contact_id}:input"
      ]
    )

    assert next_turn(ctx, 1, "Human please") == id
    assert [["handoff_pending", true, _]] = session_rows(ctx)
    assert %{rows: [[delivery]]} = SupportDBCase.delivery_rows(ctx, "id::text")
    assert :ok = Deliver.perform(job("delivery_id", delivery))
    assert Agent.get(ctx.fake, & &1.decision_reads) == 2
    assert [] = SupportDBCase.writes(ctx)
  end

  test "history projects the last six messages and skips older messages beyond the character cap" do
    earlier = Enum.map(1..8, &text_row(&1, "earlier #{&1}", sender: :human, contact_id: nil))
    current = text_row(9, "Hello")
    assert {:ok, context} = DecisionContext.project(earlier ++ [current], [9], 5)
    assert context.current == [%{role: :contact, text: "Hello"}]
    assert Enum.map(context.prior, & &1.text) == Enum.map(3..8, &"earlier #{&1}")

    earlier = [
      text_row(1, "Skip"),
      text_row(2, String.duplicate("a", 2_000)),
      text_row(3, String.duplicate("b", 2_000))
    ]

    assert {:ok, context} = DecisionContext.project(earlier ++ [current], [9], 5)
    assert Enum.map(context.prior, &String.length(&1.text)) == [2_000, 2_000]
  end

  test "a full question fits at the boundary and oversized or escaped requests are rejected" do
    text = String.duplicate("a", 3_000)

    assert {:ok, %{current: [%{text: ^text}]}} =
             DecisionContext.project([text_row(1, text)], [1], 5)

    assert {:error, :history_changed} =
             DecisionContext.project([text_row(1, text <> "b")], [1], 5)

    assert {:error, :history_changed} =
             DecisionContext.project(
               [text_row(1, text), text_row(2, text), text_row(3, "x")],
               [1, 2, 3],
               5
             )

    escaped = String.duplicate("\u0001", 2_800)

    assert {:error, :history_changed} =
             DecisionContext.project([text_row(1, escaped)], [1], 5)
  end

  test "history rejects cross-contact and unverified sender roles" do
    assert {:error, :scope_denied} =
             DecisionContext.project([text_row(1, "Hello", contact_id: 6)], [1], 5)

    for attrs <- [[sender: :unknown], [sender: :bot, contact_id: nil]] do
      assert {:error, :history_changed} =
               DecisionContext.project([text_row(1, "Hello", attrs)], [1], 5)
    end
  end

  test "history rejects private notes" do
    assert {:error, :history_changed} =
             DecisionContext.project(
               [text_row(1, "Private", visibility: :private), text_row(2, "Hello")],
               [2],
               5
             )
  end

  test "history rejects a missing or duplicate current ID, an edit, or an attachment" do
    current = text_row(2, "Hello")

    for {messages, ids} <- [
          {[current], [1]},
          {[current, current], [2]},
          {[current], [2, 2]},
          {[current, text_row(3, "Newer")], [2]},
          {[%{current | edited?: true}], [2]},
          {[%{current | attachments?: true}], [2]}
        ] do
      assert {:error, :history_changed} = DecisionContext.project(messages, ids, 5)
    end
  end

  test "a shadow turn rejects ordered text from a different destination or contact" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    Agent.update(ctx.fake, &Map.put(&1, :text_contact, 6))
    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(id)
    assert %{rows: [["failed", nil, nil]]} = run_row(id)
    assert [["handoff_pending", true, _]] = session_rows(ctx)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "the second read rejects a silent edit before completion" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    {task, worker} = park(ctx, id)
    put_text(ctx, ctx.event.message_id, "Tell me a joke")
    assert :ok = resume(task, worker)
    assert %{rows: [["failed", nil, nil]]} = run_row(id)
    assert [] = SupportDBCase.writes(ctx)
  end

  # A receipt that has landed but not yet been processed leaves the watermark
  # unchanged. The history read may not show it yet either, so only the
  # pending-input recheck under the completion lock stops the decision from
  # ignoring the newer customer message.
  test "a newer receipt awaiting processing fences the parked decision" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    {task, worker} = park(ctx, id)
    message_id = ctx.event.message_id + 1

    assert {:ok, _} =
             SupportDBCase.signed_receipt(%{ctx | event: %{ctx.event | message_id: message_id}})

    assert :ok = resume(task, worker)
    assert %{rows: [["failed", nil, nil]]} = run_row(id)
    assert [] = SupportDBCase.writes(ctx)
  end

  # No supported action changes a covered receipt after its claim; this
  # simulates that drift to prove completion rechecks the covered set.
  test "a covered receipt that changes after the claim fences the parked decision" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Hello")
    {task, worker} = park(ctx, id)

    SQL.query!(Repo, "UPDATE inbound_events SET disposition = 'triage' WHERE message_id = $1", [
      ctx.event.message_id
    ])

    assert :ok = resume(task, worker)
    assert %{rows: [["failed", nil, nil]]} = run_row(id)
    assert [] = SupportDBCase.writes(ctx)
  end

  test "an ownership or control epoch change fences the parked claim" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Human please")
    {task, worker} = park(ctx, id)
    SupportDBCase.disable_automation(ctx)
    assert :ok = resume(task, worker)
    assert %{rows: [["cancelled", nil, nil]]} = run_row(id)
    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "id")
    assert [] = SupportDBCase.writes(ctx)
  end

  # The runtime adapter switch changes no epoch, so only the completion-time
  # shadow permission recheck stops a decision that was parked before it.
  test "a runtime adapter disable after the claim cancels the parked decision" do
    ctx = SupportDBCase.setup(shadow: :en)
    id = queue(ctx, "Human please")
    {task, worker} = park(ctx, id)
    fixture = Application.fetch_env!(:voelgoed_ai, :support_fixture)
    Application.put_env(:voelgoed_ai, :support_fixture, %{fixture | shadow_evaluation: false})
    assert :ok = resume(task, worker)
    assert %{rows: [["cancelled", nil, nil]]} = run_row(id)
    assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "id")
    assert [] = SupportDBCase.writes(ctx)
  end

  test "a successor reuses the turn and deadline, and human request wins across the batch" do
    ctx = SupportDBCase.setup(shadow: :en)
    first = queue(ctx, "Tell me a joke")
    {task, worker} = park(ctx, first)
    second = next_turn(ctx, 1, "Human please")
    assert :ok = resume(task, worker)

    assert %{rows: [["superseded", nil, nil]]} = run_row(first)

    assert %{rows: [[^first, true, true]]} =
             SQL.query!(
               Repo,
               """
               SELECT parent.id::text, parent.turn_ref = child.turn_ref, parent.deadline_at = child.deadline_at
               FROM support_runs child JOIN support_runs parent ON child.parent_run_id = parent.id
               WHERE child.id = $1
               """,
               [Ecto.UUID.dump!(second)]
             )

    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(second)

    assert %{rows: [["completed", "no_send", %{"reason_code" => "human_requested"}]]} =
             run_row(second)

    assert [] = SupportDBCase.writes(ctx)
  end

  test "two clarifications use separate turns and the third routes to staff" do
    ctx = SupportDBCase.setup(shadow: :en)
    first = queue(ctx, "Help")
    SupportDBCase.advance_clock(ctx, 2)
    assert :ok = perform_run(first)
    assert %{rows: [["completed", "no_send", %{"decision" => "clarify"}]]} = run_row(first)

    for {offset, decision} <- [{1, "clarify"}, {2, "handoff"}] do
      id = next_turn(ctx, offset, "Help")
      SupportDBCase.advance_clock(ctx, 2)
      assert :ok = perform_run(id)
      assert %{rows: [["completed", "no_send", %{"decision" => ^decision}]]} = run_row(id)
    end

    assert [] = SupportDBCase.writes(ctx)
  end

  for {table, constraint} <- [
        {"outbound_deliveries", "purpose <> 'handoff_status'"},
        {"oban_jobs", "NOT (args ? 'delivery_id')"}
      ] do
    test "a failure inserting #{table} rolls back the shadow decision and handoff" do
      ctx = SupportDBCase.setup(shadow: :en)
      id = queue(ctx, "Human please")
      SupportDBCase.advance_clock(ctx, 2)
      table = unquote(table)
      condition = unquote(constraint)

      SQL.query!(
        Repo,
        "ALTER TABLE #{table} ADD CONSTRAINT reject_shadow_fixture CHECK (#{condition}) NOT VALID"
      )

      try do
        if table == "oban_jobs" do
          assert_raise Ash.Error.Unknown, ~r/reject_shadow_fixture/, fn ->
            RunProcessing.process_run(id)
          end
        else
          assert {:error, :storage_failure} = RunProcessing.process_run(id)
        end

        assert %{rows: [["running", nil, nil]]} = run_row(id)
        assert [["bot_active", false, _]] = session_rows(ctx)
        assert %{rows: []} = SupportDBCase.delivery_rows(ctx, "id")
        assert [] = SupportDBCase.writes(ctx)
      after
        SQL.query!(Repo, "ALTER TABLE #{table} DROP CONSTRAINT reject_shadow_fixture")
      end
    end
  end

  test "the fixed automatic workflow still sends its original reply" do
    ctx = SupportDBCase.setup()
    delivery = SupportDBCase.prepare_reply(ctx)
    assert :ok = Deliver.perform(job("delivery_id", delivery))
    assert [{:reply, _, "Synthetic fixture", _}] = SupportDBCase.writes(ctx)
    assert %{rows: [["completed", "fixed_reply", nil]]} = run_row(last_run(ctx))
  end

  defp text_row(id, text, attrs \\ []) do
    struct!(
      TextMessage,
      Keyword.merge(
        [
          id: id,
          text: text,
          sender: :contact,
          contact_id: 5,
          visibility: :public,
          edited?: false,
          attachments?: false
        ],
        attrs
      )
    )
  end

  defp put_text(ctx, message_id, text) do
    Agent.update(ctx.fake, fn state ->
      Map.update(
        state,
        :decision_messages,
        %{message_id => %{text: text}},
        &Map.put(&1, message_id, %{text: text})
      )
    end)
  end

  defp queue(ctx, text) do
    put_text(ctx, ctx.event.message_id, text)
    assert {:ok, receipt} = SupportDBCase.signed_receipt(ctx)
    assert :ok = RunProcessing.process_event(receipt.id)
    last_run(ctx)
  end

  defp next_turn(ctx, offset, text) do
    message_id = ctx.event.message_id + offset
    SupportDBCase.append_public_input(ctx, message_id)
    queue(%{ctx | event: %{ctx.event | message_id: message_id}}, text)
  end

  defp last_run(ctx) do
    assert %{rows: [[id]]} =
             SQL.query!(
               Repo,
               "SELECT id::text FROM support_runs WHERE session_id = $1 ORDER BY id DESC LIMIT 1",
               [Ecto.UUID.dump!(SupportDBCase.session_id(ctx))]
             )

    id
  end

  defp run_row(id) do
    SQL.query!(Repo, "SELECT state, decision, typed_decision FROM support_runs WHERE id = $1", [
      Ecto.UUID.dump!(id)
    ])
  end

  defp session_rows(ctx) do
    SQL.query!(
      Repo,
      "SELECT state, human_inhibit, ownership_epoch FROM support_sessions WHERE id = $1",
      [Ecto.UUID.dump!(SupportDBCase.session_id(ctx))]
    ).rows
  end

  defp job(key, id), do: %Oban.Job{args: %{key => id}}
  defp perform_run(id), do: ProcessRun.perform(job("run_id", id))

  defp park(ctx, id) do
    owner = self()
    Agent.update(ctx.fake, &Map.put(&1, :decision_history_barrier, owner))
    SupportDBCase.advance_clock(ctx, 2)
    task = Task.async(fn -> perform_run(id) end)
    assert_receive {:decision_history, worker}, 2_000
    {task, worker}
  end

  defp resume(task, worker) do
    send(worker, :resume_decision_history)
    Task.await(task, 5_000)
  end
end
