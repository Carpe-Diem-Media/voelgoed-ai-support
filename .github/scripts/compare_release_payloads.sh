#!/usr/bin/env bash
set -euo pipefail

first=${1:?pass the first release image}
second=${2:?pass the second release image}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

manifest() {
  docker run --rm --network none --entrypoint /bin/sh "$1" -ec '
    cd /app
    export LC_ALL=C
    find . -printf "%y %m %U:%G %p %l\n" | sort
    find . -type f -exec sha256sum {} + | sort -k2
  '
}
manifest "$first" > "$tmp/first"
manifest "$second" > "$tmp/second"
for image in "$first" "$second"; do
  docker image inspect --format '{{.Os}}/{{.Architecture}} {{.Id}} {{.Config.User}}' "$image"
done
sha256sum "$tmp/first" "$tmp/second"
diff -u "$tmp/first" "$tmp/second"
