#!/bin/sh
set -eu

deps_dir=${1:?pass the isolated production dependency directory}
source_file=$deps_dir/req_llm/lib/req_llm/message.ex

printf '%s  %s\n' d255513ac8d71ebc1025da5e67042b92132fc753c64ce41dab1189ec8d8f233a "$source_file" |
  sha256sum -c

normalized=$(mktemp "${source_file}.XXXXXXXX")
trap 'rm -f "$normalized"' EXIT

# Preserve line numbers outside the edited schema and encoder declaration.
sed -e '/^  defmodule ReasoningDetails do$/,/^  end$/ {
    /^    @derive Jason\.Encoder$/ {
      N
      d
    }
    /^            })$/a\
            |> Map.update!(:fields, \&Enum.sort/1)\
    @derive {Jason.Encoder, only: Keyword.keys(@schema.fields)}
  }' "$source_file" > "$normalized"

printf '%s  %s\n' 0dc3cd1d50a8a55f7d4129768e0c3636a24b3c79d6ddef73eaa8bd18766396b6 "$normalized" |
  sha256sum -c

chmod --reference="$source_file" "$normalized"
mv -f "$normalized" "$source_file"
