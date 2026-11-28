# Executed by the packaged release. The values below are synthetic and
# deliberately set in memory to test that PROD cannot acquire TEST authority.
alias VoelgoedAi.Governance.{AutomationControl, FinancialControl}
alias VoelgoedAi.Intelligence.{Embedding, EmbeddingTransport, Generation, GenerationTransport}
alias VoelgoedAi.Knowledge.{Publication, Retrieval}
alias VoelgoedAi.Support.{ChatwootAdapter, Ingress, Recovery, RunProcessing}

:nonode@nohost = node()
~c"17.1.1" = :erlang.system_info(:version)
"1.20.5" = System.version()
"29.1.2" = File.read!("/app/releases/OTP_VERSION") |> String.trim()

oban = Application.fetch_env!(:voelgoed_ai, Oban)
[false, false, false, false] = Enum.map([:queues, :plugins, :peer, :stager], &oban[&1])
nil = oban[:testing]
nil = oban[:cron]
{:error, :staff_auth_unavailable} = VoelgoedAi.Accounts.EntraConfig.enabled()
:disabled = Application.fetch_env!(:voelgoed_ai, :chatwoot_adapter)
nil = Application.get_env(:voelgoed_ai, :embedding_fixture)
nil = Application.get_env(:voelgoed_ai, :entra_fixture_transport)
nil = Application.get_env(:ash_authentication, :http_adapter)

for {module, function, arity} <- [
      {Retrieval, :with_fixture, 2},
      {Retrieval, :with_shadow, 8},
      {Retrieval, :sort_fixture_ranks, 1},
      {Generation, :with_fixture, 4},
      {Generation, :propose, 5},
      {Generation, :reset_budget, 1},
      {Embedding, :reset_budget, 1},
      {FinancialControl, :with_decision, 4},
      {RunProcessing, :claim_evidence_fixture, 1},
      {RunProcessing, :complete_evidence_fixture, 3},
      {Publication, :record_fixture_evaluation, 2},
      {EmbeddingTransport, :fixture_wire, 1}
    ] do
  true = Code.ensure_loaded?(module)

  if function_exported?(module, function, arity),
    do: raise("TEST function shipped: #{inspect(module)}.#{function}/#{arity}")
end

for module <- [
      VoelgoedAi.StaffEntraFixture,
      VoelgoedAi.Feasibility.EntraProvider,
      VoelgoedAi.CITimingFormatter
    ],
    do: false = Code.ensure_loaded?(module)

{:ok, _} = Application.ensure_all_started(:voelgoed_ai)

Application.put_env(:voelgoed_ai, :chatwoot_adapter, :fixture)
Application.put_env(:voelgoed_ai, :support_fixture, %{adapter: {__MODULE__, nil}})
Application.put_env(:voelgoed_ai, :embedding_fixture, %{mode: :fixture})

reset_input =
  Ash.ActionInput.for_action(AutomationControl, :reset_financial_inhibit, %{
    lane: :generation,
    occurrence: Ash.UUIDv7.generate()
  })

{:error, %Ash.Error.Forbidden{}} = Ash.run_action(reset_input)
{:error, "financial inhibit reset denied"} = FinancialControl.run(reset_input, [], %{})

nil = ChatwootAdapter.fixture()
false = ChatwootAdapter.in_scope?(%{})

for operation <- [:reply, :open_for_handoff] do
  {:error, {:not_issued, :disabled}} =
    ChatwootAdapter.write(
      operation,
      nil,
      [],
      DateTime.add(DateTime.utc_now(), 1),
      %VoelgoedAi.Support.OutboundDelivery{control_epoch: 0}
    )
end

{:error, :scope_denied} = Ingress.accept(%{})
:ok = Recovery.sweep()
{:error, :unavailable} = RunProcessing.review_draft(nil, Ash.UUIDv7.generate())
{:error, :disabled} = Embedding.publication_deadline(%{})

# Neither fabricated authority nor an invalid envelope can reach a wire adapter.
ref = make_ref()
args = %{text: "vgas-synthetic-rejected-input"}

{:error, "support proposal unavailable"} =
  Generation.run(%{action: %{name: :generate}, arguments: args}, [], %{
    actor: struct!(Generation, ref: ref)
  })

owner = self()

wire = fn request ->
  send(owner, :invalid_dispatch_wire)
  {request, Req.Response.new(status: 500)}
end

:unknown = EmbeddingTransport.invoke(ref, args.text, 1_000, {:fixture, wire})

attempt = %{
  id: "synthetic-attempt",
  dispatch_fence: 1,
  deadline_at: DateTime.add(DateTime.utc_now(), 1)
}

adapter =
  GenerationTransport.options(attempt, {owner, ref}, wire, args.text, 1_000, fn ->
    {:ok, attempt.deadline_at}
  end)[:adapter]

request =
  Req.Request.prepend_response_steps(Req.new(),
    llm_decode_response: &Function.identity/1
  )

{%Req.Request{}, %Req.TransportError{reason: :closed}} = adapter.(request)
:unknown = GenerationTransport.take(attempt, ref)

receive do
  :invalid_dispatch_wire -> raise "invalid dispatch entered the wire adapter"
after
  0 -> :ok
end

# A packaged release denies retention even with a syntactically valid fixture
# capability. The expected return also proves the gate precedes database work.
retention_grant = Ash.UUIDv7.generate()

Application.put_env(:voelgoed_ai, :retention_fixture, %{
  capability: retention_grant,
  batch_size: 1
})

{:discard, :retention_disabled} =
  VoelgoedAi.Support.Workers.Retention.perform(%Oban.Job{
    args: %{"capability" => retention_grant}
  })

{:error, :denied} =
  VoelgoedAi.Support.Retention.staff_transition(
    %{},
    :hold,
    Ash.UUIDv7.generate(),
    retention_grant
  )

retention = VoelgoedAi.Support.Retention

{:ok, {^retention, [imports: retention_imports]}} =
  :beam_lib.chunks(:code.which(retention), [:imports])

false =
  Enum.any?(retention_imports, fn {module, _, _} ->
    module in [
      Ecto.Adapters.SQL,
      VoelgoedAi.Repo,
      VoelgoedAi.Accounts.StaffAccess,
      VoelgoedAi.Support.Configuration,
      VoelgoedAi.Support.WorkStore
    ]
  end)
