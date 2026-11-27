#!/usr/bin/env bash
set -euo pipefail

expected_version=${1:?expected server_version_num is required}
actual=$(
  PGPASSWORD="$TEST_DATABASE_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h "$TEST_DATABASE_HOST" -p "$TEST_DATABASE_PORT" \
    -U "$TEST_DATABASE_USERNAME" -d "$TEST_DATABASE_NAME" <<'SQL'
SELECT current_database(), current_user, current_setting('server_version_num'),
       e.extversion, pg_get_userbyid(d.datdba), r.rolcanlogin,
       r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolreplication, r.rolbypassrls,
       ('[1,0]'::vector <=> '[0,1]'::vector)
FROM pg_roles r
JOIN pg_database d ON d.datname = current_database()
JOIN pg_extension e ON e.extname = 'vector'
WHERE r.rolname = current_user;
SQL
)
printf 'PostgreSQL baseline: %s\n' "$actual"
test "$actual" = "vgas_test|vgas_test|$expected_version|0.8.7|vgas_test|t|f|f|f|f|f|1"
