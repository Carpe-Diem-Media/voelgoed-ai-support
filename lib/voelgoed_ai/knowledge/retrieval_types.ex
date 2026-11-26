defmodule VoelgoedAi.Knowledge.Retrieval.Scope do
  @moduledoc "Verified applicability values. An omitted field conveys no authority."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields:
        Enum.map([:brand, :product, :event, :service], fn field ->
          {field, [type: :string, constraints: [match: ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,79}\z/]]}
        end)
    ]
end

defmodule VoelgoedAi.Knowledge.Retrieval.Evidence do
  @moduledoc "Approved text and the exact publication and support claims that qualified it."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        citation_id: [type: :uuid, allow_nil?: false],
        run_id: [type: :uuid, allow_nil?: false],
        claim_generation: [type: :integer, allow_nil?: false],
        assistant_revision_id: [type: :uuid, allow_nil?: false],
        assistant_hash: [type: :string, allow_nil?: false],
        article_id: [type: :uuid, allow_nil?: false],
        revision_id: [type: :uuid, allow_nil?: false],
        article_ref: [type: :string, allow_nil?: false],
        locale: [type: :string, constraints: [match: ~r/\A(?:af|en)-ZA\z/], allow_nil?: false],
        content_hash: [type: :string, allow_nil?: false],
        mode: [type: :atom, constraints: [one_of: [:exact, :grounded]], allow_nil?: false],
        profile_id: [type: :string, allow_nil?: false],
        generation: [type: :integer, allow_nil?: false],
        index_epoch: [type: :integer, allow_nil?: false],
        collection_id: [type: :uuid, allow_nil?: false],
        collection_epoch: [type: :integer, allow_nil?: false],
        assistant_epoch: [type: :integer, allow_nil?: false],
        binding_epoch: [type: :integer, allow_nil?: false],
        control_epoch: [type: :integer, allow_nil?: false],
        ownership_epoch: [type: :integer, allow_nil?: false],
        scope: [type: VoelgoedAi.Knowledge.Retrieval.Scope, allow_nil?: false],
        title: [type: :string, allow_nil?: false, constraints: [max_length: 160]],
        answer: [type: :string, allow_nil?: false, constraints: [max_length: 4096]],
        steps: [type: {:array, :string}, constraints: [max_length: 12, items: [max_length: 480]]],
        links: [type: {:array, :string}, constraints: [max_length: 8, items: [max_length: 512]]]
      ]
    ]
end

defmodule VoelgoedAi.Knowledge.Retrieval.Manifest do
  @moduledoc "Bounded result of an authorized search or evidence revalidation."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        status: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:evidence, :no_evidence, :unavailable, :denied]]
        ],
        evidence: [
          type: {:array, VoelgoedAi.Knowledge.Retrieval.Evidence},
          allow_nil?: false,
          constraints: [max_length: 4]
        ]
      ]
    ]
end
