#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [[ ${MIX_ENV:-} != test || ${TEST_DATABASE_HOST:-} != 127.0.0.1 ||
      ${TEST_DATABASE_PORT:-} != 55434 || ${TEST_DATABASE_NAME:-} != vgas_test ||
      ${TEST_DATABASE_USERNAME:-} != vgas_test ]]; then
  echo 'Run this proof on a fresh disposable TEST container at 127.0.0.1:55434.' >&2
  exit 1
fi

unset OPENAI_API_KEY
bash .github/scripts/verify_postgres.sh 180007

psql_test() {
  PGPASSWORD="$TEST_DATABASE_PASSWORD" psql -X --no-password -qAt -v ON_ERROR_STOP=1 \
    -h "$TEST_DATABASE_HOST" -p "$TEST_DATABASE_PORT" \
    -U "$TEST_DATABASE_USERNAME" -d "$TEST_DATABASE_NAME" "$@"
}

mix_test() {
  mise exec -- mix "$@"
}

assert_equal() {
  local label=$1 expected=$2 actual=$3
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nExpected: %s\nActual: %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'Result: %s\n' "$label"
}

public_relations=$(psql_test -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
assert_equal 'disposable public schema starts empty' 0 "$public_relations"

predecessor=20261126053035
contributor=20261126060400
b1=20261126063108
revision='019ac561-0000-7000-8000-000000000021'
missing_staff='019ac561-0000-7000-8000-000000000099'

contributor_version() {
  psql_test -c "SELECT version, inserted_at FROM schema_migrations WHERE version = $contributor"
}

contributor_column() {
  psql_test -c "
    SELECT udt_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'article_revisions'
      AND column_name = 'contributor_ids'"
}

revision_rows() {
  # Preserve every predecessor field. The argument removes the new column only
  # when comparing the predecessor and the upgraded rows.
  psql_test -c "SELECT to_jsonb(r) ${1:-} FROM article_revisions r ORDER BY id"
}

audit_rows() {
  psql_test -c 'SELECT to_jsonb(e) FROM audit_events e ORDER BY id'
}

assert_contributors() {
  local actual expected
  expected='019ac561-0000-7000-8000-000000000021|019ac561-0000-7000-8000-000000000003|{019ac561-0000-7000-8000-000000000001,019ac561-0000-7000-8000-000000000002,019ac561-0000-7000-8000-000000000003}
019ac561-0000-7000-8000-000000000022|019ac561-0000-7000-8000-000000000003|{019ac561-0000-7000-8000-000000000003}'
  actual=$(psql_test -c "
    SELECT id, created_by_id, contributor_ids
    FROM article_revisions ORDER BY id")
  assert_equal 'exact creator and ordered contributor IDs on both revisions' "$expected" "$actual"
}

assert_full_chain() {
  local versions
  mix_test ecto.migrate --strict-version-order
  versions=$(mix_test ecto.migrations)
  printf '%s\n' "$versions"
  if grep -Eq '^[[:space:]]+down[[:space:]]' <<<"$versions"; then
    echo 'Application migrations are pending.' >&2
    exit 1
  fi
}

reject_write() {
  local label=$1 assignment=$2 sqlstate=$3 constraint=$4
  local output status=0
  output=$(psql_test -v VERBOSITY=verbose 2>&1 <<SQL
BEGIN;
UPDATE article_revisions SET $assignment WHERE id = '$revision';
ROLLBACK;
SQL
  ) || status=$?
  if [[ "$status" != 3 || "$output" != *"ERROR:  $sqlstate:"* ||
        "$output" != *"CONSTRAINT NAME:  $constraint"* ]]; then
    printf 'FAIL: %s (psql exit %s)\n%s\n' "$label" "$status" "$output" >&2
    exit 1
  fi
  printf 'Result: %s (%s, %s, psql exit %s)\n' "$label" "$sqlstate" "$constraint" "$status"
}

case "${1:-}" in
  fresh)
    assert_full_chain
    column=$(contributor_column)
    assert_equal 'fresh contributor column has UUID array type, NOT NULL and empty default' \
      '_uuid|NO|ARRAY[]::uuid[]' "$column"
    mix_test test test/voelgoed_ai/repo_foundation_test.exs --seed 0
    ;;
  clean)
    mix_test ecto.migrate --strict-version-order --to "$contributor"
    before_version=$(contributor_version)
    before_column=$(contributor_column)
    [[ "$before_version" == "$contributor|"* && -n "$before_column" ]]
    mix_test ecto.rollback --step 1
    rolled_back_version=$(contributor_version)
    rolled_back_column=$(contributor_column)
    assert_equal 'clean rollback removes migration version' '' "$rolled_back_version"
    assert_equal 'clean rollback removes contributor column' '' "$rolled_back_column"
    mix_test ecto.migrate --strict-version-order --to "$contributor"
    reapplied_version=$(contributor_version)
    assert_equal 'clean reapply restores migration version' "$contributor" "${reapplied_version%%|*}"
    assert_equal 'clean reapply restores contributor column' "$before_column" "$(contributor_column)"
    assert_equal 'clean reapply preserves empty revisions' 0 "$(psql_test -c 'SELECT count(*) FROM article_revisions')"
    ;;
  upgrade)
    mix_test ecto.migrate --strict-version-order --to "$predecessor"
    psql_test -f test/fixtures/vgas_22_contributor_predecessor.sql
    predecessor_revisions=$(revision_rows)
    predecessor_audit=$(audit_rows)
    mix_test ecto.migrate --strict-version-order --to "$contributor"
    assert_contributors
    assert_equal 'backfill preserves predecessor revision fields' "$predecessor_revisions" \
      "$(revision_rows "- 'contributor_ids'")"
    assert_equal 'backfill preserves every audit field' "$predecessor_audit" "$(audit_rows)"

    before_version=$(contributor_version)
    before_column=$(contributor_column)
    before_revisions=$(revision_rows)
    status=0
    output=$(mix_test ecto.rollback --step 1 2>&1) || status=$?
    if [[ "$status" != 1 || "$output" != *'ERROR P0001 (raise_exception) VGAS-003 editorial contributor history exists.'* ]]; then
      printf 'FAIL: populated rollback (Mix exit %s)\n%s\n' "$status" "$output" >&2
      exit 1
    fi
    echo 'Result: populated rollback raised P0001 from the contributor history guard (Mix exit 1)'
    assert_equal 'refusal preserves migration version and insertion time' "$before_version" "$(contributor_version)"
    assert_equal 'refusal preserves contributor column' "$before_column" "$(contributor_column)"
    assert_equal 'refusal preserves complete revision rows' "$before_revisions" "$(revision_rows)"
    assert_equal 'refusal preserves complete audit rows' "$predecessor_audit" "$(audit_rows)"

    mix_test ecto.migrate --strict-version-order --to "$b1"
    reject_write 'creator must reference existing staff' \
      "created_by_id = '$missing_staff', contributor_ids = ARRAY['$missing_staff'::uuid]" \
      23503 article_revisions_created_by_id_fkey
    reject_write 'existing creator must remain a contributor' \
      "contributor_ids = array_remove(contributor_ids, created_by_id)" 23514 article_revisions_contributors
    reject_write 'contributor array rejects a null element even with the creator present' \
      "contributor_ids = array_append(contributor_ids, NULL::uuid)" 23514 article_revisions_contributors

    assert_full_chain
    assert_contributors
    assert_equal 'full upgrade preserves complete audit rows' "$predecessor_audit" "$(audit_rows)"
    mix_test test test/verification/vgas_22_backfilled_approval.exs --seed 0
    ;;
  *)
    echo "Usage: bash $0 {fresh|clean|upgrade}" >&2
    exit 2
    ;;
esac
