#!/usr/bin/env bash
set -euo pipefail

for job in PLAN BUILD SNAPSHOTS MIGRATIONS SECRETS PROD_COMPILE RELEASE_PACKAGE; do
  if [[ "${!job:-}" != success ]]; then
    echo "$job did not succeed" >&2
    exit 1
  fi
done

if [[ "${HAS_TESTS:-}" == true ]]; then
  [[ "${TEST:-}" == success ]]
else
  [[ "${HAS_TESTS:-}" == false && "${TEST:-}" == skipped ]]
fi
