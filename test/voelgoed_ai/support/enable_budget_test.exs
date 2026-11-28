defmodule VoelgoedAi.Support.EnableBudgetTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias VoelgoedAi.{Repo, SupportDBCase, SupportFixtures}
  alias VoelgoedAi.Governance.AutomationControl
  alias VoelgoedAi.Support.ChatwootAdapter

  for {mode, lane, cap} <- [
        {:shadow, :generation, :day_cap},
        {:assisted, :embedding, :month_cap}
      ] do
    test "#{mode} Enable rejects an insufficient #{lane} #{cap} without changing accounting" do
      ctx = SupportDBCase.setup(shadow: :en, assisted: unquote(mode) == :assisted, enable: false)
      original = Application.fetch_env(:voelgoed_ai, :embedding_fixture)

      on_exit(fn ->
        case original do
          {:ok, fixture} -> Application.put_env(:voelgoed_ai, :embedding_fixture, fixture)
          :error -> Application.delete_env(:voelgoed_ai, :embedding_fixture)
        end
      end)

      owner = self()

      wire = fn _ ->
        send(owner, :unexpected_inference)
        {:error, :unexpected_inference}
      end

      embedding = %{mode: :fixture, wire: wire}
      generation = %{generation_wire: wire}
      fixture = ChatwootAdapter.fixture()

      profiles =
        if unquote(lane) == :embedding,
          do: {Map.put(embedding, unquote(cap), 1), generation},
          else: {embedding, Map.put(generation, unquote(cap), 1)}

      configure(fixture, profiles)
      before = control_and_accounting()
      assert {:error, _} = enable(ctx)
      assert control_and_accounting() == before
      refute_received :unexpected_inference

      configure(fixture, {embedding, generation})
      assert {:ok, %{status: :enabled, mode: :shadow_test}} = enable(ctx)
      refute_received :unexpected_inference
    end
  end

  test "a fixed-reply fixture can Enable without an inference budget" do
    ctx = SupportDBCase.setup(enable: false)
    assert {:ok, %{status: :enabled, mode: :fake}} = enable(ctx)
  end

  test "a deterministic shadow fixture can Enable without an inference budget" do
    ctx = SupportDBCase.setup(shadow: :en, enable: false)
    refute Map.has_key?(ChatwootAdapter.fixture(), :shadow_inference)
    assert {:ok, %{status: :enabled, mode: :shadow_test}} = enable(ctx)
  end

  defp enable(ctx) do
    SupportFixtures.invoke(
      AutomationControl,
      :enable_automation,
      %{binding_id: ctx.binding_id},
      ctx.admin
    )
  end

  defp configure(fixture, {embedding, generation}) do
    Application.put_env(:voelgoed_ai, :embedding_fixture, embedding)

    Application.put_env(
      :voelgoed_ai,
      :support_fixture,
      Map.put(fixture, :shadow_inference, generation)
    )
  end

  defp control_and_accounting do
    SQL.query!(Repo, """
    SELECT status, security_epoch,
           (SELECT count(*) FROM audit_events WHERE event = 'enable_automation'),
           (SELECT count(*) FROM usage_reservations),
           (SELECT count(*) FROM usage_ledger_entries),
           (SELECT count(*) FROM spend_windows)
    FROM automation_controls WHERE singleton
    """).rows
  end
end
