defmodule VoelgoedAi.Intelligence.SupportProposal do
  @moduledoc """
  Generates an ephemeral, typed proposal under a current shadow claim. The
  result carries no authority to complete the run or write to Chatwoot.
  """

  use Ash.Resource,
    domain: VoelgoedAi.Intelligence,
    authorizers: [Ash.Policy.Authorizer]

  import AshAi.Actions

  alias VoelgoedAi.Intelligence.Generation
  alias VoelgoedAi.Knowledge.Retrieval.Evidence
  alias VoelgoedAi.Support.{DecisionContext, SupportDecision}

  @prompt_file Path.expand("../../../priv/prompts/vgas_support_proposal_v1.txt", __DIR__)
  @external_resource @prompt_file
  @system_prompt File.read!(@prompt_file)
  @model "gpt-6-luna"
  @output_limit 500
  @profile "support-proposal-openai-responses-v1"
  @prompt_version "vgas-support-proposal-v1"
  @reasons ~w(supported ambiguous off_topic human_requested account_specific missing_evidence conflicting_evidence unsafe unavailable)
  @properties %{
    "schema_version" => %{"type" => "integer", "enum" => [1]},
    "decision" => %{"type" => "string", "enum" => ~w(answer_grounded clarify decline handoff)},
    "locale" => %{"type" => "string", "enum" => ~w(af-ZA en-ZA)},
    "reason_code" => %{"type" => "string", "enum" => @reasons},
    "evidence_revision_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
    "reply_text" => %{"type" => ["string", "null"]}
  }
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => Enum.sort(Map.keys(@properties)),
    "properties" => @properties
  }

  actions do
    action :generate, SupportDecision do
      description(
        "Reserve and execute one permitted generation slot for the current shadow claim."
      )

      allow_nil?(false)

      argument(:run_id, :uuid, allow_nil?: false)
      argument(:claim_generation, :integer, allow_nil?: false, constraints: [min: 1])

      argument(:context, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: DecisionContext]
      )

      argument(:evidence, {:array, Evidence},
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4]
      )

      run(Generation)
    end

    action :prompt, SupportDecision do
      description("Run the pinned Ash AI prompt with one committed dispatch capability.")
      allow_nil?(false)

      argument(:text, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 16_384, length_count: :bytes, trim?: false]
      )

      run(
        prompt("openai:" <> @model,
          prompt: &__MODULE__.messages/2,
          tools: false,
          response_schema: @schema,
          cast_response: &__MODULE__.cast/1,
          transform_flow: &Generation.configure_prompt/2,
          req_llm_opts: [
            api_key: "synthetic-generation-fixture",
            base_url: "https://api.openai.com/v1",
            max_completion_tokens: @output_limit,
            reasoning_effort: :none,
            openai_structured_output_mode: :json_schema,
            provider_options: [store: false, include: []],
            telemetry: [payloads: :none],
            max_retries: 0
          ]
        )
      )
    end
  end

  policies do
    policy action([:generate, :prompt]) do
      authorize_if(Generation)
    end
  end

  @doc false
  def model, do: @model

  @doc false
  def profile, do: @profile

  @doc false
  def prompt_version, do: @prompt_version

  @doc false
  def output_limit, do: @output_limit

  @doc false
  def system_prompt, do: @system_prompt

  @doc false
  def schema do
    %{
      "type" => "object",
      "properties" => %{"result" => @schema},
      "required" => ["result"],
      "additionalProperties" => false
    }
  end

  @doc false
  def messages(input, _context), do: {@system_prompt, input.arguments.text}

  @doc "Check the provider's exact raw keys and types before Ash casts."
  @spec cast(term()) :: {:ok, SupportDecision.t()} | {:error, :invalid_proposal}
  def cast(
        %{"decision" => decision, "reason_code" => reason, "evidence_revision_ids" => refs} =
          value
      )
      when decision in ~w(answer_grounded clarify decline handoff) and reason in @reasons and
             is_list(refs) and length(refs) <= 4 do
    case SupportDecision.cast(value) do
      {:ok, _} = result -> result
      :error -> {:error, :invalid_proposal}
    end
  end

  def cast(_), do: {:error, :invalid_proposal}
end
