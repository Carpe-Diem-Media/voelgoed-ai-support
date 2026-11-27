#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export PLAN=success BUILD=success SNAPSHOTS=success MIGRATIONS=success SECRETS=success
export PROD_COMPILE=success RELEASE_PACKAGE=success TEST=success HAS_TESTS=true
bash check_application_gate.sh
HAS_TESTS=false TEST=skipped bash check_application_gate.sh

for job in PROD_COMPILE RELEASE_PACKAGE; do
  for result in failure skipped cancelled; do
    if env "$job=$result" bash check_application_gate.sh; then
      echo "Unexpected gate success for $job=$result" >&2
      exit 1
    fi
  done
  if env -u "$job" bash check_application_gate.sh; then
    echo "Unexpected gate success without $job" >&2
    exit 1
  fi
done
echo 'Application CI gate accepted both positive controls and denied all eight negative controls.'
