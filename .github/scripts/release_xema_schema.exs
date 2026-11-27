# Exercise both keyword membership paths around the release-only normalization.
document = %{
  "$schema" => "http://json-schema.org/draft-07/schema#",
  "type" => "object",
  "properties" => %{
    "count" => %{"type" => "integer", "minimum" => 1},
    "label" => %{"type" => "string", "minLength" => 2}
  },
  "required" => ["count", "label"],
  "additionalProperties" => false
}

{:map, rules} = Xema.JsonSchema.to_xema(document)
%{"count" => {:integer, [minimum: 1]}, "label" => {:string, [min_length: 2]}} = rules[:properties]
false = rules[:additional_properties]

{:map, extended} =
  document
  |> Map.put("extension", %{"type" => "string", "maxLength" => 3})
  |> Xema.JsonSchema.to_xema(atom: :force)

{:string, [max_length: 3]} = extended[:extension]

schema = Xema.from_json_schema(document)
true = Xema.valid?(schema, %{"count" => 1, "label" => "ok"})
false = Xema.valid?(schema, %{"count" => 0, "label" => "ok"})
false = Xema.valid?(schema, %{"count" => 1, "label" => "a"})
false = Xema.valid?(schema, %{"count" => 1})
false = Xema.valid?(schema, %{"count" => 1, "label" => "ok", "other" => true})

IO.puts(
  "Xema converted standard and nested extension keywords and enforced the same schema bounds."
)
