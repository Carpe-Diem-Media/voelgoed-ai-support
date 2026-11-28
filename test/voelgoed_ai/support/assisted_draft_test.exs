defmodule VoelgoedAi.Support.AssistedDraftTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.ShadowWorkflowFixture

  alias VoelgoedAi.{Accounts, StaffFixtures, SupportDBCase}
  alias VoelgoedAi.Support.RunProcessing

  @moduletag :requires_pgvector

  for locale <- [:en, :af] do
    test "#{locale} qualified assisted no-send drafts can be reviewed and expire" do
      locale = unquote(locale)
      ctx = setup_faq(locale, "exact", assisted: true)
      operator = operator(ctx)
      id = queue(ctx, question(locale))
      configure(ctx)

      assert :ok = perform(id)
      assert run(id).assisted_draft
      assert {:ok, draft} = RunProcessing.review_draft(operator, id)
      assert draft.text == approved(locale)
      assert draft.evidence == [ctx.target.id]
      assert {:error, :unavailable} = RunProcessing.review_draft(ctx.staff.admin, id)
      assert_no_writes(ctx)

      SupportDBCase.advance_clock(ctx.support, 45)
      assert {:error, :unavailable} = RunProcessing.review_draft(operator, id)
    end
  end

  test "a shadow answer is unavailable for review" do
    ctx = setup_faq(:en, "exact")
    operator = operator(ctx)
    id = queue(ctx, question(:en))
    configure(ctx)
    assert :ok = perform(id)
    refute run(id).assisted_draft
    assert {:error, :unavailable} = RunProcessing.review_draft(operator, id)
    assert_no_writes(ctx)
  end

  test "a qualified grounded draft is withheld after its input changes" do
    ctx = setup_faq(:en, "grounded", assisted: true)
    operator = operator(ctx)
    id = queue(ctx, question(:en))
    configure(ctx, generation: &response(&1, ctx))
    assert :ok = perform(id)
    assert {:ok, %{text: text}} = RunProcessing.review_draft(operator, id)
    assert text == paraphrase(:en)

    put_text(ctx, ctx.support.event.message_id, "Different synthetic input")
    assert {:error, :unavailable} = RunProcessing.review_draft(operator, id)

    capability = Ash.UUIDv7.generate()

    inbox =
      Map.take(ctx.support.event, [:installation_ref, :external_account_id, :external_inbox_id])

    Application.put_env(:voelgoed_ai, :retention_fixture, %{
      capability: capability,
      inbox: inbox,
      batch_size: 25
    })

    on_exit(fn -> Application.delete_env(:voelgoed_ai, :retention_fixture) end)
    SupportDBCase.advance_clock(ctx.support, 7 * 86_400)
    assert :ok = VoelgoedAi.Support.Workers.Retention.perform(job("capability", capability))
    assert run(id).retention_state == :purged
    assert {:error, :unavailable} = RunProcessing.review_draft(operator, id)
    assert_no_writes(ctx)
  end

  defp operator(ctx) do
    identity = StaffFixtures.identity("#{ctx.staff.slug}-operations")
    assert {:ok, row} = Accounts.provision(ctx.staff.admin, identity, [:support_operator])

    on_exit(fn ->
      VoelgoedAi.Repo.query!("DELETE FROM audit_events WHERE target_id = $1", [uuid(row.id)])
      VoelgoedAi.Repo.query!("DELETE FROM staff_users WHERE id = $1", [uuid(row.id)])
    end)

    assert {:ok, session} = StaffFixtures.authenticate(row.id)
    session
  end
end
