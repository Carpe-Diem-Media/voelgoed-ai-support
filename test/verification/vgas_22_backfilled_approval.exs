defmodule VoelgoedAi.Knowledge.BackfilledApprovalProof do
  use ExUnit.Case, async: false

  import VoelgoedAi.KnowledgeFixtures, only: [attest: 1, snapshot: 1]
  import VoelgoedAi.StaffFixtures, only: [authenticate: 1]
  import VoelgoedAi.SupportFixtures, only: [invoke: 4]

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, StaffFixtures}
  alias VoelgoedAi.Knowledge.{ArticleRevision, Content}

  @collection "019ac561-0000-7000-8000-000000000010"
  @revision "019ac561-0000-7000-8000-000000000021"
  @submitter "019ac561-0000-7000-8000-000000000001"
  @editor "019ac561-0000-7000-8000-000000000002"

  test "backfilled editor and submitter must attest before approving the reviewed snapshot" do
    StaffFixtures.setup()
    assert {:ok, editor} = authenticate(@editor)
    assert {:ok, submitter} = authenticate(@submitter)

    Application.put_env(:voelgoed_ai, :knowledge_fixture_scope, %{
      @collection => %{reviewers: [editor.id, submitter.id]}
    })

    on_exit(fn -> Application.delete_env(:voelgoed_ai, :knowledge_fixture_scope) end)

    assert {:ok, %{status: :in_review} = reviewed} =
             invoke(ArticleRevision, :read_revision, %{id: @revision}, editor)

    assert Content.hash(reviewed.content) == reviewed.content_hash
    before_denials = stored_facts()
    args = attest(snapshot(reviewed))

    for reviewer <- [editor, submitter] do
      assert {:error, error} = invoke(ArticleRevision, :approve, args, reviewer)
      assert Exception.message(error) =~ "approval_denied"
      assert stored_facts() == before_denials
    end

    assert {:ok, %{status: :approved, approved_by_id: @submitter}} =
             invoke(ArticleRevision, :approve, %{args | self_approval: true}, submitter)

    assert %{rows: [[@submitter, "self_approval_attested"]]} =
             SQL.query!(
               Repo,
               """
               SELECT actor_staff_id::text, reason_code
               FROM audit_events
               WHERE article_revision_target_id = $1 AND event = 'approve'
               """,
               [Ecto.UUID.dump!(@revision)]
             )
  end

  defp stored_facts do
    SQL.query!(
      Repo,
      """
      SELECT to_jsonb(r),
             (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
              FROM audit_events e WHERE e.article_revision_target_id = r.id),
             (SELECT count(*) FROM oban_jobs)
      FROM article_revisions r WHERE r.id = $1
      """,
      [Ecto.UUID.dump!(@revision)]
    ).rows
  end
end
