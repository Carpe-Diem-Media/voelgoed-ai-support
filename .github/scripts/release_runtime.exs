# Executed by the packaged release. The values below are synthetic and
# deliberately set in memory to test that PROD cannot acquire TEST authority.
alias VoelgoedAi.Intelligence.{Embedding, EmbeddingTransport, Generation}
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

nil = ChatwootAdapter.fixture()
false = ChatwootAdapter.in_scope?(%{})

{:error, :unavailable} =
  ChatwootAdapter.call(:reply, nil, [], DateTime.add(DateTime.utc_now(), 1))

{:error, :scope_denied} = Ingress.accept(%{})
:ok = Recovery.sweep()
{:error, :disabled} = Embedding.publication_deadline(%{})
