#!/bin/sh
set -eu

source_file=${1:?pass the locked Xema 0.17.10 JsonSchema source}
printf '%s  %s\n' c1f2004cf974a7be9c46d24cf21fb693534929312aea32cb9b9ef1e564a1477d "$source_file" |
  sha256sum -c -

normalized=$(mktemp)
trap 'rm -f "$normalized"' EXIT
# The generated guard and the runtime check both use keyword membership.
sed '/^            |> Enum\.concat(/a\
            |> Enum.sort()
' "$source_file" > "$normalized"
printf '%s  %s\n' 41b8d9a3f664e08dbec6b890a4106a49e4b47bcad8e7030de005f6fc6cecc7ce "$normalized" |
  sha256sum -c -
cat "$normalized" > "$source_file"
