# Compare the printed digest with the locked baseline. The digest ignores
# field and error order while retaining full schemas, values and error terms.
alias LLMDB.{Model, Schema.Pricing}

defmodule ReleaseModelSchemaProbe do
  def canonical(%type{fields: fields} = schema, require_sorted)
      when type in [Zoi.Types.Map, Zoi.Types.Struct] and is_list(fields) do
    sorted = Enum.sort(fields)

    if require_sorted and fields != sorted do
      raise "unsorted model or pricing field list"
    end

    schema
    |> Map.put(:fields, sorted)
    |> canonical_map(require_sorted)
  end

  def canonical(value, require_sorted) when is_map(value),
    do: canonical_map(value, require_sorted)

  def canonical(value, require_sorted) when is_list(value),
    do: Enum.map(value, &canonical(&1, require_sorted))

  def canonical(value, require_sorted) when is_tuple(value) do
    value |> Tuple.to_list() |> canonical(require_sorted) |> List.to_tuple()
  end

  def canonical(value, _require_sorted), do: value

  defp canonical_map(map, require_sorted) do
    Map.new(:maps.to_list(map), fn {key, value} -> {key, canonical(value, require_sorted)} end)
  end
end

require_sorted = System.get_env("VGAS_REQUIRE_SORTED_MODEL_SCHEMAS") == "1"
{:ok, _} = Application.ensure_all_started(:req_llm)

schemas =
  for schema <- [Model.schema(), Pricing.schema(%{merge: Zoi.string()})] do
    ReleaseModelSchemaProbe.canonical(schema, require_sorted)
  end

valid = %{
  id: "vgas-release-probe",
  provider: :openai,
  limits: %{context: 32},
  pricing: %{
    currency: "USD",
    components: [%{id: "input", role: "rate", unit: "token", rate: 0, per: 1}]
  }
}

{:ok, %Model{deprecated: false, aliases: [], pricing: %{currency: "USD"}} = parsed} =
  Model.new(valid)

{:ok, %Model{id: "vgas-release-probe", provider: :openai} = inline} =
  ReqLLM.model(%{
    "id" => "vgas-release-probe",
    "provider" => "openai",
    "limits" => %{context: 32}
  })

invalid = %{
  valid
  | id: 1,
    limits: %{context: 0, input: -1},
    pricing: %{currency: 1, components: [%{id: "broken", role: "rate"}, %{id: 1, per: 0}]}
}

{:error, errors} = Model.new(invalid)
true = length(errors) > 3

{:error, _} = ReqLLM.model(invalid)

owner = self()

wire = fn request ->
  send(owner, :invalid_model_wire)
  {request, Req.Response.new(status: 500)}
end

{:error, _} =
  ReqLLM.embed(invalid, "synthetic-input",
    api_key: "synthetic-release-probe",
    total_timeout: 1_000,
    max_retries: 0,
    req_http_options: [adapter: wire, retry: false]
  )

receive do
  :invalid_model_wire -> raise "invalid inline model entered the wire adapter"
after
  0 -> :ok
end

models = LLMDB.models()
true = length(models) > 0
required = Model.__info__(:struct) |> Enum.sort()

digest =
  :crypto.hash(
    :sha256,
    :erlang.term_to_binary(
      {schemas, required, Model.__struct__(), parsed, inline, Enum.sort(errors),
       Enum.sort_by(models, &{&1.provider, &1.id})},
      [:deterministic]
    )
  )

digest = Base.encode16(digest, case: :lower)

if digest != "920384b882479de2d7c1164fd059679f589ff40f07132804fb9a901e6288f5f8" do
  raise "model schemas, defaults, validation errors or catalog differ from the locked baseline"
end

IO.puts("Model schema, validation and #{length(models)} catalog models: #{digest}")
