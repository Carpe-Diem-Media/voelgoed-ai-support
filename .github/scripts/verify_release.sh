#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

image=${1:?pass the built release image}
db_image=pgvector/pgvector@sha256:4bdc16048580b56345bca441bffe8d9b45dd2f5d76963808c853df1661df6e00

tmp=$(mktemp -d)
scope="vgas-release-${tmp##*.}"
network="$scope-net"
db="$scope-db"
server="$scope-http"
tls="$scope-tls"
missing="$scope-missing"
cleanup() {
  docker rm -fv "$tls" "$server" "$missing" "$db" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This network has no external route and publishes no port on the workstation.
docker network create --internal "$network" >/dev/null
export POSTGRES_PASSWORD
POSTGRES_PASSWORD=$(openssl rand -hex 24)
docker run -d --name "$db" --network "$network" --network-alias postgres \
  --env POSTGRES_PASSWORD "$db_image" >/dev/null
for ((attempt=0; attempt<60; attempt++)); do
  if docker exec "$db" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$db" pg_isready -h 127.0.0.1 -U postgres

role_password=$(openssl rand -hex 24)
docker exec -i "$db" psql -X -q -v ON_ERROR_STOP=1 -U postgres <<SQL
CREATE ROLE vgas_release LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$role_password';
CREATE DATABASE vgas_fresh OWNER vgas_release;
CREATE DATABASE vgas_upgrade OWNER vgas_release;
\connect vgas_fresh
CREATE EXTENSION vector;
\connect vgas_upgrade
CREATE EXTENSION vector;
SQL

export PHX_HOST=vgas-release.test SECRET_KEY_BASE DATABASE_URL PGPASSWORD=$role_password
SECRET_KEY_BASE=$(openssl rand -hex 64)
release_args=(--network "$network" --read-only --tmpfs /tmp --env PHX_HOST
  --env SECRET_KEY_BASE --env DATABASE_URL --env ERL_FLAGS=+S4)

sql() {
  docker exec -i --env PGPASSWORD "$db" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -U vgas_release -d "$@"
}

baseline=$(sql vgas_fresh <<'SQL'
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
printf 'Release PostgreSQL baseline: %s\n' "$baseline"
[[ "$baseline" == 'vgas_fresh|vgas_release|180007|0.8.7|vgas_release|t|f|f|f|f|f|1' ]]
[[ "$(docker run --rm --network none "$image" id -u)" == 65534 ]]

predecessor=92ef0e39a7808d4ffa692b37b48ba3ee27a05e30
for name in 20261125141215_foundation_extensions_1.exs 20261125205628_add_staff_authorization.exs; do
  git show "$predecessor:priv/repo/migrations/$name" | cmp - "priv/repo/migrations/$name"
done
expected_versions=$(find priv/repo/migrations -maxdepth 1 -type f -name '*.exs' -printf '%f\n' |
  cut -d _ -f 1 | LC_ALL=C sort)

for lane in vgas_fresh vgas_upgrade; do
  DATABASE_URL="postgresql://vgas_release:$role_password@postgres/$lane"
  if [[ "$lane" == vgas_upgrade ]]; then
    docker run --rm "${release_args[@]}" "$image" /app/bin/voelgoed_ai eval '
      {:ok, _} = Application.ensure_all_started(:ssl)
      {:ok, [20261125141215, 20261125205628], _} =
        Ecto.Migrator.with_repo(VoelgoedAi.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, to: 20261125205628, strict_version_order: true)
        end)
    '
    sql "$lane" < .github/scripts/vgas001_upgrade_fixture.sql
  fi

  docker run --rm "${release_args[@]}" "$image" /app/bin/migrate
  [[ "$(sql "$lane" -c 'SELECT version FROM schema_migrations ORDER BY version')" == "$expected_versions" ]]
  before=$(sql "$lane" -c 'SELECT version, inserted_at FROM schema_migrations ORDER BY version')
  docker run --rm "${release_args[@]}" "$image" /app/bin/migrate
  [[ "$(sql "$lane" -c 'SELECT version, inserted_at FROM schema_migrations ORDER BY version')" == "$before" ]]

  if [[ "$lane" == vgas_upgrade ]]; then
    history=$(sql "$lane" <<'SQL'
SELECT s.identity_subject, s.status, s.roles, s.session_generation, a.event, a.reason_code,
       a.after_state = '{"status":"invited","roles":["admin"],"session_generation":0}'::jsonb
FROM staff_users s JOIN audit_events a ON a.target_id = s.id
WHERE s.id = '019ac560-0000-7000-8000-000000000001' AND a.id = '019ac560-0000-7000-8000-000000000002';
SQL
    )
    [[ "$history" == 'vgas001-upgrade-fixture|invited|{admin}|0|provisioned|allowlisted|t' ]]
  fi
  printf '%s: migrated all %s versions and repeated with no changes.\n' "$lane" "$(wc -l <<< "$expected_versions")"
done

docker run --rm "${release_args[@]}" --env VGAS_REQUIRE_SORTED_MODEL_SCHEMAS=1 \
  --mount "type=bind,source=$PWD/.github/scripts/release_model_schemas.exs,target=/release_model_schemas.exs,readonly" \
  --mount "type=bind,source=$PWD/.github/scripts/release_runtime.exs,target=/release_runtime.exs,readonly" \
  --mount "type=bind,source=$PWD/.github/scripts/release_xema_schema.exs,target=/release_xema_schema.exs,readonly" \
  "$image" /app/bin/voelgoed_ai eval 'Code.eval_file("/release_runtime.exs"); Code.eval_file("/release_xema_schema.exs"); Code.eval_file("/release_model_schemas.exs")'
echo 'Packaged runtime denied TEST capability issuers and kept the default configuration disabled.'

for required in DATABASE_URL PHX_HOST SECRET_KEY_BASE; do
  if timeout 30s env -u "$required" docker run --name "$missing" "${release_args[@]}" "$image" \
      > "$tmp/missing.log" 2>&1; then
    echo "Release started without $required" >&2
    exit 1
  fi
  grep -Fq "could not fetch environment variable \"$required\"" "$tmp/missing.log"
  docker rm -v "$missing" >/dev/null
  printf 'Startup refused missing %s.\n' "$required"
done

container_ip() {
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
}

probe() {
  curl --noproxy '*' --silent --show-error --max-time 3 "$@"
}

await_health() {
  for ((attempt=0; attempt<60; attempt++)); do
    if probe --fail "$@" > "$tmp/health.json" 2>/dev/null &&
        [[ "$(cat "$tmp/health.json")" == '{"status":"ok"}' ]]; then
      return
    fi
    sleep 1
  done
  echo 'Packaged endpoint did not become healthy.' >&2
  return 1
}

check_shutdown() {
  docker stop --signal SIGTERM --timeout 15 "$1" >/dev/null
  [[ "$(docker inspect --format '{{.State.ExitCode}}' "$1")" == 0 ]]
}

docker run -d --name "$server" "${release_args[@]}" "$image" >/dev/null
origin="http://$(container_ip "$server"):4000"
await_health "$origin/health"
[[ "$(probe -H 'X-Forwarded-Proto: https' -o /dev/null -w '%{http_code}' "$origin/staff/assets/knowledge.js")" == 401 ]]
[[ "$(probe -o /dev/null -w '%{http_code}' "$origin/staff/session")" == 401 ]]
[[ "$(probe -X POST -d 'invalid body' -o /dev/null -w '%{http_code}' "$origin/webhooks/chatwoot/synthetic")" == 404 ]]
check_shutdown "$server"
echo 'Packaged HTTP server passed health, default staff/webhook denial and clean SIGTERM.'

# Entra values only let the request exercise the local origin guard. The
# network and requested routes cannot contact the identity provider.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$PHX_HOST" \
  -addext "subjectAltName=DNS:$PHX_HOST" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
chmod 0444 "$tmp/key.pem"
docker run -d --name "$tls" "${release_args[@]}" \
  --env VGAS_STAFF_AUTH_ENABLED=true \
  --env VGAS_ENTRA_TENANT_ID=11111111-1111-4111-8111-111111111111 \
  --env VGAS_ENTRA_CLIENT_ID=22222222-2222-4222-8222-222222222222 \
  --env VGAS_ENTRA_CLIENT_SECRET=synthetic-staff-probe \
  --env "VGAS_ENTRA_REDIRECT_URI=https://$PHX_HOST/staff/entra/callback" \
  --mount "type=bind,source=$tmp/cert.pem,target=/cert.pem,readonly" \
  --mount "type=bind,source=$tmp/key.pem,target=/key.pem,readonly" \
  "$image" /app/bin/voelgoed_ai eval '
    endpoint = Application.fetch_env!(:voelgoed_ai, VoelgoedAiWeb.Endpoint)
    Application.put_env(:voelgoed_ai, VoelgoedAiWeb.Endpoint,
      Keyword.merge(endpoint, server: true, http: false,
        https: [ip: {0, 0, 0, 0}, port: 443, certfile: "/cert.pem", keyfile: "/key.pem"]))
    {:ok, _} = Application.ensure_all_started(:voelgoed_ai)
    Process.sleep(:infinity)
  ' >/dev/null
tls_origin="https://$PHX_HOST"
tls_ip=$(container_ip "$tls")
tls_probe=(--cacert "$tmp/cert.pem" --resolve "$PHX_HOST:443:$tls_ip")
await_health "${tls_probe[@]}" "$tls_origin/health"

check_asset() {
  local path=$1 packaged=$2 mime=$3
  local code
  code=$(probe "${tls_probe[@]}" -D "$tmp/headers" -o "$tmp/asset" -w '%{http_code}' \
    "$tls_origin/staff/assets/$path")
  [[ "$code" == 200 ]]
  tr -d '\r' < "$tmp/headers" > "$tmp/headers.txt"
  grep -Eiq "^content-type: ($mime)(;.*)?$" "$tmp/headers.txt"
  grep -Fixq 'x-content-type-options: nosniff' "$tmp/headers.txt"
  grep -Fixq "content-security-policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' wss://$PHX_HOST; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" "$tmp/headers.txt"
  docker exec "$tls" cat "$packaged" | cmp - "$tmp/asset"
  sha256sum "$tmp/asset" | awk -v asset="$path" '{print $1, asset}'
}

check_asset knowledge.css /app/lib/voelgoed_ai-0.1.0/priv/static/staff/knowledge.css 'text/css'
check_asset knowledge.js /app/lib/voelgoed_ai-0.1.0/priv/static/staff/knowledge.js '(text|application)/javascript'
check_asset phoenix/phoenix.min.js /app/lib/phoenix-1.8.17/priv/static/phoenix.min.js '(text|application)/javascript'
check_asset live_view/phoenix_live_view.min.js /app/lib/phoenix_live_view-1.2.15/priv/static/phoenix_live_view.min.js '(text|application)/javascript'
[[ "$(probe "${tls_probe[@]}" -o /dev/null -w '%{http_code}' "$tls_origin/staff/assets/phoenix/phoenix.js")" == 404 ]]
[[ "$(probe "${tls_probe[@]}" -H 'Host: denied.example.test' -o /dev/null -w '%{http_code}' "$tls_origin/staff/assets/knowledge.css")" == 401 ]]
check_shutdown "$tls"
echo 'Packaged HTTPS assets passed byte comparison, MIME, nosniff, CSP and origin denial.'
