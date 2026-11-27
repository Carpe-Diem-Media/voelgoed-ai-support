#!/bin/sh
set -eu

deps_dir=${1:?pass the isolated production dependency directory}
cd "$deps_dir"
req_llm=req_llm/lib/req_llm.ex
model=llm_db/lib/llm_db/model.ex
pricing=llm_db/lib/llm_db/schema/pricing.ex

# Verify all locked sources before staging any edits.
sha256sum -c <<CHECKSUMS
032a362a5bea00819e0e3094746584d6c387a24f9388b965d690f2ae3e890251  $req_llm
873b215cf233941d37a89077932fc6af242ad7f2782fd8bf12cd5cd93b9649d9  $model
0f903cf67932b2d456b91909e5cef12d4adc8523ebc4347ba374dddf5d14ef1b  $pricing
CHECKSUMS

normalized=$(mktemp -d)
trap 'rm -rf "$normalized"' EXIT
# ReqLLM uses these keys to build the inline-model string membership guard.
sed '/^                       |> Map\.keys()$/a\
                       |> Enum.sort()
' "$req_llm" > "$normalized/req_llm.ex"

# Zoi 0.19.0 consumes field maps into lists in Types.Map.new/2 and
# Types.Struct.new/3. Sort those lists after construction so the public
# constructors keep their documented map inputs and all their options.
sed -e '/Zoi\.object(%{/,/^[[:blank:]]*})$/s/^\([[:blank:]]*})\)$/\1 |> Map.update!(:fields, \&Enum.sort\/1)/' \
    -e '/^            coerce: true$/ {n; s/^          )$/& |> Map.update!(:fields, \&Enum.sort\/1)/;}' \
    "$model" > "$normalized/model.ex"

# Sort both the embedded component and each pricing object after the merge.
sed -e '/^  @component Zoi\.object(%{/,/^             })$/s/^             })$/&\n             |> Map.update!(:fields, \&Enum.sort\/1)/' \
    -e '/^    |> Zoi\.object()$/a\
    |> Map.update!(:fields, \&Enum.sort/1)
' "$pricing" > "$normalized/pricing.ex"

(
  cd "$normalized"
  sha256sum -c <<'CHECKSUMS'
8dd1e73de254d570b41b2752401a3c2c3fbbad63535d64e154a73dfe83a0e7aa  req_llm.ex
e2801cba756ee4a48545875fe702cffdabfb557196a030afad1a506d1697feea  model.ex
0391772d0a123ada95e23257d3b0f8f5da6e9d30bd423fbb05bd16f71391b1a8  pricing.ex
CHECKSUMS
)
cat "$normalized/req_llm.ex" > "$req_llm"
cat "$normalized/model.ex" > "$model"
cat "$normalized/pricing.ex" > "$pricing"
