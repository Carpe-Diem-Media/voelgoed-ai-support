defmodule VoelgoedAi.Support.ShadowSmokeTest do
  use ExUnit.Case, async: false

  import VoelgoedAi.ShadowWorkflowFixture

  @moduletag :provider_smoke
  @moduletag :requires_pgvector

  # This matches the frozen single-slot reservation in Generation. The
  # operator must confirm the provider project's prices and separate cap.
  @cap_nano_usd 525_375_000

  test "owner-approved one-call smoke uses the governed proposal action" do
    assert System.get_env("VGAS_SMOKE_OWNER_APPROVED") == "yes"
    assert System.get_env("VGAS_SMOKE_CAP_NANO_USD") == Integer.to_string(@cap_nano_usd)
    assert System.get_env("TEST_DATABASE_HOST") == "127.0.0.1"
    assert System.get_env("TEST_DATABASE_PORT") == "55435"

    fixture_key = System.get_env("VGAS_SMOKE_OPENAI_API_KEY")

    assert is_binary(fixture_key) and byte_size(fixture_key) > 0,
           "the separate owner-approved smoke key must be injected by the authorized runner"

    latch = :atomics.new(1, [])
    ctx = setup_faq(:en, "grounded")
    id = queue(ctx, question(:en))

    configure(ctx,
      generation: fn request ->
        # GenerationTransport checks the HTTPS endpoint, exact model,
        # request schema, output ceiling and stateless options first.
        :ok = :atomics.compare_exchange(latch, 1, 0, 1)
        committed_before_wire(id, "generate")

        timeout = min(15_000, request.options.receive_timeout)

        request
        |> Req.Request.put_header("authorization", "Bearer " <> fixture_key)
        |> Req.merge(
          receive_timeout: timeout,
          finch: [pool_timeout: timeout],
          connect_options: [timeout: timeout, protocols: [:http1]]
        )
        |> Req.Finch.run()
      end
    )

    assert :ok = perform(id)
    assert Agent.get(ctx.hits, & &1) == %{embedding: 1, generation: 1}
    assert :atomics.get(latch, 1) == 1
    assert_no_writes(ctx)

    assert [
             ["query_embedding", "succeeded", _, _, "settled", _, _],
             ["generate", "succeeded", input, output, "settled", charge, @cap_nano_usd]
           ] = attempts(id)

    assert output <= 500
    assert charge <= @cap_nano_usd

    IO.puts("Smoke trusted usage input=#{input} output=#{output} charge_nano_usd=#{charge}")
  end
end
