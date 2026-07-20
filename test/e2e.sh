#!/usr/bin/env bash
# test/e2e.sh — end-to-end harness for this image's TLS defaulting and
# multi-database wildcard-routing behavior. Mirrors postgres-ssl's
# test/e2e.sh / postgres-ha's test/e2e-ha.sh harness shape (color helpers,
# t_* functions, assert_*, ALL_TESTS dispatch).
#
# Boots this image against a plain postgres:16-alpine upstream (and, for
# the server-side test, the real ghcr.io/railwayapp-templates/postgres-ssl
# image) and walks every assertion about client_tls_sslmode/server_tls_sslmode
# defaulting, plus the wildcard `[databases]` entry (PGDATABASE=*) that lets
# a single pooler reach every database on the upstream instead of just one —
# Railway's postgres-with-pgbouncer template now defaults to this. Each
# assertion is a `t_*` function; final exit code is the count of failed tests.
#
# Run: ./test/e2e.sh
# Or:  ./test/e2e.sh t_tls_allow_default_accepts_both   # subset

set -uo pipefail

IMAGE="pgbouncer-e2e-test:local"
NET="pgb-test-net"
UPSTREAM="pgb-test-upstream"
SSL_UPSTREAM_IMAGE="ghcr.io/railwayapp-templates/postgres-ssl:18"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAILED_TESTS=()

# ----- color / log helpers ---------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi
log()  { echo "${B}==>${N} $*"; }
ok()   { echo "${G}PASS${N} $*"; PASS=$((PASS+1)); }
ko()   { echo "${R}FAIL${N} $*"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
note() { echo "  ${Y}note:${N} $*"; }

fail_dump() {
  local label="$1"; shift
  echo "${R}--- failure detail (${label}) ---${N}" >&2
  for c in "$@"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${c}$"; then
      echo "${R}--- docker logs ${c} (last 100) ---${N}" >&2
      docker logs --tail 100 "$c" 2>&1 | sed 's/^/    /' >&2
    fi
  done
}

# ----- assertion helpers -----------------------------------------------------
assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" = "$expected" ]; then return 0; fi
  echo "  expected: $expected"
  echo "  actual:   $actual"
  echo "  msg:      $msg"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then return 0; fi
  echo "  expected to contain: $needle"
  echo "  actual:              $haystack"
  echo "  msg:                 $msg"
  return 1
}

# ----- environment management ------------------------------------------------
ensure_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "image $IMAGE already built"
    return
  fi
  log "building $IMAGE"
  docker build -q -t "$IMAGE" "$REPO_ROOT" >/dev/null
}

ensure_network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

ensure_upstream() {
  if docker ps --format '{{.Names}}' | grep -q "^${UPSTREAM}$"; then
    return
  fi
  log "starting plain (non-SSL) upstream postgres"
  docker rm -f "$UPSTREAM" >/dev/null 2>&1 || true
  docker run -d --name "$UPSTREAM" --label pgbouncer-e2e=1 --network "$NET" \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=railway \
    postgres:16-alpine >/dev/null
  wait_for_pg_exec "$UPSTREAM"

  # Extra databases beyond the default "railway" — this is exactly the
  # customer-reported shape (many databases on one Postgres instance) that
  # the wildcard `[databases]` entry is meant to reach. Created once here so
  # every wildcard-routing test below can share them without recreating.
  docker exec "$UPSTREAM" psql -U postgres -c "CREATE DATABASE second_db" >/dev/null 2>&1 || true
  docker exec "$UPSTREAM" psql -U postgres -c "CREATE DATABASE third_db" >/dev/null 2>&1 || true
}

wait_for_pg_exec() {
  local container="$1" deadline=$(($(date +%s) + 120))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # postgres-ssl restarts once internally to apply its generated cert
    # (ssl=on), so a single pg_isready success can be a stale pre-restart
    # postmaster. Require two consecutive successes a beat apart before
    # trusting it.
    if docker exec "$container" pg_isready -U postgres -q 2>/dev/null; then
      sleep 2
      docker exec "$container" pg_isready -U postgres -q 2>/dev/null && return 0
    fi
    sleep 1
  done
  return 1
}

cleanup_test_resources() {
  docker rm -f $(docker ps -aq --filter "label=pgbouncer-e2e=1") 2>/dev/null >/dev/null || true
  docker volume rm pgb-e2e-ssl-vol >/dev/null 2>&1 || true
  docker volume rm pgb-e2e-cert-vol >/dev/null 2>&1 || true
}

# Boots a pgbouncer container against $UPSTREAM with the given extra
# `docker run` args, and waits until it's accepting connections on 5432.
# PGDATABASE defaults to "*" (the wildcard fallback entry) — this is
# Railway's actual production default for postgres-with-pgbouncer, so the
# whole suite exercises that config unless a test explicitly overrides it.
start_bouncer() {
  local name="$1"; shift
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$UPSTREAM" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE='*' -e PGPORT=5432 \
    "$@" \
    "$IMAGE" >/dev/null
  local deadline=$(($(date +%s) + 30))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -c "select 1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ----- tests -----------------------------------------------------------------

t_vanilla_boot() {
  local name=t-vanilla
  start_bouncer "$name" || { ko t_vanilla_boot "pgbouncer did not come up"; fail_dump t_vanilla_boot "$name" "$UPSTREAM"; return; }
  local out
  out=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -At -c "select 1" 2>&1)
  assert_eq "$out" "1" "plaintext client should be able to select 1" || { ko t_vanilla_boot ""; fail_dump t_vanilla_boot "$name"; return; }
  ok t_vanilla_boot
  docker rm -f "$name" >/dev/null
}

t_tls_allow_default_accepts_both() {
  local name=t-tls-allow-default
  start_bouncer "$name" || { ko t_tls_allow_default_accepts_both "pgbouncer did not come up"; fail_dump t_tls_allow_default_accepts_both "$name"; return; }

  local sslmode_line
  sslmode_line=$(docker exec "$name" grep -F "client_tls_sslmode" /etc/pgbouncer/pgbouncer.ini)
  assert_eq "$sslmode_line" "client_tls_sslmode = allow" "client_tls_sslmode should default to allow" || { ko t_tls_allow_default_accepts_both ""; fail_dump t_tls_allow_default_accepts_both "$name"; return; }

  if ! docker exec "$name" test -f /etc/pgbouncer/tls/server.crt; then
    ko t_tls_allow_default_accepts_both "expected an auto-generated cert at /etc/pgbouncer/tls/server.crt"
    fail_dump t_tls_allow_default_accepts_both "$name"
    return
  fi

  local plain
  plain=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -At -c "select 1" 2>&1)
  assert_eq "$plain" "1" "plaintext client (sslmode=disable) should still work under allow" || { ko t_tls_allow_default_accepts_both ""; fail_dump t_tls_allow_default_accepts_both "$name"; return; }

  local tls_conninfo
  tls_conninfo=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=require" -c "\conninfo" 2>&1)
  # psql's \conninfo format varies by version (one-line "SSL connection
  # (protocol: TLSv1.3, ...)" vs. a tabular "SSL Connection | true" plus
  # separate "SSL Protocol | TLSv1.3" rows) — match on the protocol string,
  # which appears verbatim in both.
  assert_contains "$tls_conninfo" "TLSv1" "TLS client (sslmode=require) should negotiate SSL against the auto-generated cert" || { ko t_tls_allow_default_accepts_both ""; fail_dump t_tls_allow_default_accepts_both "$name"; return; }

  ok t_tls_allow_default_accepts_both
  docker rm -f "$name" >/dev/null
}

t_tls_sslmode_disable_opt_out() {
  local name=t-tls-disable-opt-out
  start_bouncer "$name" -e CLIENT_TLS_SSLMODE=disable || { ko t_tls_sslmode_disable_opt_out "pgbouncer did not come up"; fail_dump t_tls_sslmode_disable_opt_out "$name"; return; }

  if docker exec "$name" test -e /etc/pgbouncer/tls/server.crt; then
    ko t_tls_sslmode_disable_opt_out "cert should not be generated when the operator explicitly disabled TLS"
    fail_dump t_tls_sslmode_disable_opt_out "$name"
    return
  fi

  local plain
  plain=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -At -c "select 1" 2>&1)
  assert_eq "$plain" "1" "plaintext client should still work with TLS explicitly disabled" || { ko t_tls_sslmode_disable_opt_out ""; fail_dump t_tls_sslmode_disable_opt_out "$name"; return; }

  if docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=require" -c "select 1" >/dev/null 2>&1; then
    ko t_tls_sslmode_disable_opt_out "a TLS-requesting client should be refused when the operator explicitly disabled TLS"
    fail_dump t_tls_sslmode_disable_opt_out "$name"
    return
  fi

  ok t_tls_sslmode_disable_opt_out
  docker rm -f "$name" >/dev/null
}

t_tls_custom_cert_respected() {
  local name=t-tls-custom-cert
  docker volume rm pgb-e2e-cert-vol >/dev/null 2>&1 || true
  docker volume create pgb-e2e-cert-vol >/dev/null
  # Generate the "operator's own" cert using this same image (it now
  # bundles openssl) into a volume, mimicking a customer mounting their
  # own cert/key into the container. A fresh named volume is root-owned;
  # generate as root (the image otherwise runs as the postgres user) and
  # open up perms so pgbouncer's postgres user can read it back below.
  docker run --rm --user root -v pgb-e2e-cert-vol:/out --entrypoint sh "$IMAGE" -c '
    openssl req -new -x509 -days 30 -nodes -subj "/CN=custom-operator-cert" -out /out/custom.crt -keyout /out/custom.key &&
    chmod 644 /out/custom.crt /out/custom.key
  ' >/dev/null 2>&1

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$UPSTREAM" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE='*' -e PGPORT=5432 \
    -e CLIENT_TLS_SSLMODE=require \
    -e CLIENT_TLS_CERT_FILE=/custom-tls/custom.crt \
    -e CLIENT_TLS_KEY_FILE=/custom-tls/custom.key \
    -v pgb-e2e-cert-vol:/custom-tls:ro \
    "$IMAGE" >/dev/null

  local deadline=$(($(date +%s) + 30)) up=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=require" -c "select 1" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    ko t_tls_custom_cert_respected "pgbouncer did not come up with the operator-provided cert"
    fail_dump t_tls_custom_cert_respected "$name"
    return
  fi

  if docker exec "$name" test -e /etc/pgbouncer/tls/server.crt; then
    ko t_tls_custom_cert_respected "auto-gen should be skipped once CLIENT_TLS_CERT_FILE is already set"
    fail_dump t_tls_custom_cert_respected "$name"
    return
  fi

  local cert_line
  cert_line=$(docker exec "$name" grep -F "client_tls_cert_file" /etc/pgbouncer/pgbouncer.ini)
  assert_eq "$cert_line" "client_tls_cert_file = /custom-tls/custom.crt" "the operator's cert path should be used, not an auto-generated one" || { ko t_tls_custom_cert_respected ""; fail_dump t_tls_custom_cert_respected "$name"; return; }

  # require means require: a plaintext client must now be refused.
  if docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -c "select 1" >/dev/null 2>&1; then
    ko t_tls_custom_cert_respected "plaintext client should be refused once the operator sets sslmode=require"
    fail_dump t_tls_custom_cert_respected "$name"
    return
  fi

  ok t_tls_custom_cert_respected
  docker rm -f "$name" >/dev/null
}

t_server_tls_scope_unchanged() {
  # This PR only defaults CLIENT_TLS_SSLMODE (the client<->pgbouncer leg).
  # server_tls_sslmode (pgbouncer<->upstream) is untouched — pgbouncer's
  # own compiled-in default is already "prefer" (opportunistic, confirmed
  # via SHOW CONFIG against a live instance), so there's nothing to add
  # there. This test guards that scope: no SERVER_TLS_SSLMODE line should
  # appear in the generated config unless the operator sets one, and the
  # live default reported by pgbouncer itself must still be "prefer".
  local name=t-server-tls-scope
  start_bouncer "$name" || { ko t_server_tls_scope_unchanged "pgbouncer did not come up"; fail_dump t_server_tls_scope_unchanged "$name"; return; }

  if docker exec "$name" grep -qF "server_tls_sslmode" /etc/pgbouncer/pgbouncer.ini; then
    ko t_server_tls_scope_unchanged "server_tls_sslmode should not be written to the config unless the operator set SERVER_TLS_SSLMODE"
    fail_dump t_server_tls_scope_unchanged "$name"
    return
  fi

  local live_default
  live_default=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/pgbouncer?sslmode=disable" -At -F'|' -c "SHOW CONFIG" 2>&1 | awk -F'|' '$1=="server_tls_sslmode"{print $3}')
  assert_eq "$live_default" "prefer" "pgbouncer's own compiled-in default for server_tls_sslmode should still be prefer" || { ko t_server_tls_scope_unchanged ""; fail_dump t_server_tls_scope_unchanged "$name"; return; }

  ok t_server_tls_scope_unchanged
  docker rm -f "$name" >/dev/null
}

t_server_tls_prefer_encrypts_against_ssl_upstream() {
  # End-to-end confirmation that the pgbouncer -> Postgres leg is already
  # opportunistically encrypted today against a real SSL-enabled upstream
  # (the actual postgres-ssl production image), via pgbouncer's own
  # server_tls_sslmode=prefer default — no Railway-side config needed.
  local ssl_up=t-ssl-upstream name=t-server-tls-prefer
  docker rm -f "$ssl_up" >/dev/null 2>&1 || true
  docker volume rm pgb-e2e-ssl-vol >/dev/null 2>&1 || true
  docker volume create pgb-e2e-ssl-vol >/dev/null
  docker run -d --name "$ssl_up" --label pgbouncer-e2e=1 --network "$NET" \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=railway \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    -v pgb-e2e-ssl-vol:/var/lib/postgresql/data \
    "$SSL_UPSTREAM_IMAGE" >/dev/null
  wait_for_pg_exec "$ssl_up" || { ko t_server_tls_prefer_encrypts_against_ssl_upstream "postgres-ssl upstream did not start"; fail_dump t_server_tls_prefer_encrypts_against_ssl_upstream "$ssl_up"; return; }

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$ssl_up" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE='*' -e PGPORT=5432 \
    "$IMAGE" >/dev/null

  local deadline=$(($(date +%s) + 30)) up=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -c "select 1" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    ko t_server_tls_prefer_encrypts_against_ssl_upstream "pgbouncer did not come up against the SSL upstream"
    fail_dump t_server_tls_prefer_encrypts_against_ssl_upstream "$name" "$ssl_up"
    return
  fi

  # Query pg_stat_ssl directly on the upstream (bypassing pgbouncer) for
  # the backend connection pgbouncer opened, identified by client_addr
  # being pgbouncer's container IP rather than a local socket connection.
  local ssl_used
  ssl_used=$(docker exec "$ssl_up" psql -U postgres -At -c \
    "select ssl from pg_stat_ssl join pg_stat_activity using (pid) where usename='postgres' and client_addr is not null" 2>&1)
  assert_eq "$ssl_used" "t" "pgbouncer's backend connection to postgres-ssl should be TLS-encrypted via server_tls_sslmode=prefer" || { ko t_server_tls_prefer_encrypts_against_ssl_upstream ""; fail_dump t_server_tls_prefer_encrypts_against_ssl_upstream "$name" "$ssl_up"; return; }

  ok t_server_tls_prefer_encrypts_against_ssl_upstream
  docker rm -f "$name" "$ssl_up" >/dev/null
  docker volume rm pgb-e2e-ssl-vol >/dev/null 2>&1 || true
}

# ----- wildcard multi-database routing ---------------------------------------
# Railway's postgres-with-pgbouncer template defaults PGDATABASE to "*"
# instead of pinning to one database — the customer-reported bug this fixes
# was "no such database" for every database on the upstream except the
# default one. These tests exercise that config end-to-end: multiple real
# databases, the image's own implicit default (no PGDATABASE set at all),
# a genuinely-missing database, per-database pool visibility, auth_query
# composed with wildcard routing, and — as a control — that the old
# single-database pin still behaves the old way (so these tests are
# actually exercising the wildcard, not just always-permissive routing).

t_wildcard_routes_multiple_databases() {
  local name=t-wildcard-multi
  start_bouncer "$name" || { ko t_wildcard_routes_multiple_databases "pgbouncer did not come up"; fail_dump t_wildcard_routes_multiple_databases "$name"; return; }

  local db out
  for db in railway second_db third_db; do
    out=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/${db}?sslmode=disable" -At -c "select current_database()" 2>&1)
    assert_eq "$out" "$db" "wildcard entry should route to ${db} through the pooler" || { ko t_wildcard_routes_multiple_databases "failed on ${db}"; fail_dump t_wildcard_routes_multiple_databases "$name"; return; }
  done

  ok t_wildcard_routes_multiple_databases
  docker rm -f "$name" >/dev/null
}

t_wildcard_implicit_default_when_pgdatabase_unset() {
  # The entrypoint's own generate_config_db_entry falls back to "*" when
  # PGDATABASE isn't set at all (${PGDATABASE:-*}) — Railway now sets it
  # explicitly, but the image's inherent default must independently work
  # too, since anyone booting this image directly (not through Railway's
  # template) relies on it.
  local name=t-wildcard-implicit-default
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$UPSTREAM" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGPORT=5432 \
    "$IMAGE" >/dev/null

  local deadline=$(($(date +%s) + 30)) up=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/second_db?sslmode=disable" -c "select 1" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    ko t_wildcard_implicit_default_when_pgdatabase_unset "pgbouncer did not come up, or second_db wasn't reachable, with PGDATABASE entirely unset"
    fail_dump t_wildcard_implicit_default_when_pgdatabase_unset "$name"
    return
  fi

  local entry
  entry=$(docker exec "$name" sed -n '/\[databases\]/,/^\[/p' /etc/pgbouncer/pgbouncer.ini | grep -F '=')
  assert_contains "$entry" "* = host=" "the rendered [databases] entry should be the wildcard, not a pinned name" || { ko t_wildcard_implicit_default_when_pgdatabase_unset ""; fail_dump t_wildcard_implicit_default_when_pgdatabase_unset "$name"; return; }

  ok t_wildcard_implicit_default_when_pgdatabase_unset
  docker rm -f "$name" >/dev/null
}

t_wildcard_nonexistent_database_surfaces_postgres_error() {
  # A database the wildcard forwards to but that genuinely doesn't exist on
  # the upstream must fail with POSTGRES's error ("does not exist"), not
  # silently hang or get a PgBouncer-level rejection — proving the wildcard
  # entry forwards blindly and Postgres itself remains the source of truth.
  local name=t-wildcard-missing-db
  start_bouncer "$name" || { ko t_wildcard_nonexistent_database_surfaces_postgres_error "pgbouncer did not come up"; fail_dump t_wildcard_nonexistent_database_surfaces_postgres_error "$name"; return; }

  local out
  out=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/totally_made_up_db?sslmode=disable" -c "select 1" 2>&1)
  assert_contains "$out" "does not exist" "a genuinely-missing database should surface Postgres's own error through the pooler" || { ko t_wildcard_nonexistent_database_surfaces_postgres_error ""; fail_dump t_wildcard_nonexistent_database_surfaces_postgres_error "$name"; return; }

  ok t_wildcard_nonexistent_database_surfaces_postgres_error
  docker rm -f "$name" >/dev/null
}

t_wildcard_independent_pools_per_database() {
  # Once clients have actually connected to more than one database through
  # the wildcard entry, pgbouncer's admin console should list a distinct
  # pool per database — the pooling story downstream monitoring (databaseCount
  # in Railway's pgbouncer-monitor) depends on, not just "everything works
  # under one shared pool".
  local name=t-wildcard-pools
  start_bouncer "$name" || { ko t_wildcard_independent_pools_per_database "pgbouncer did not come up"; fail_dump t_wildcard_independent_pools_per_database "$name"; return; }

  docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -c "select 1" >/dev/null 2>&1
  docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/second_db?sslmode=disable" -c "select 1" >/dev/null 2>&1
  docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/third_db?sslmode=disable" -c "select 1" >/dev/null 2>&1

  local databases
  databases=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/pgbouncer?sslmode=disable" -At -F'|' -c "SHOW DATABASES" 2>&1 | cut -d'|' -f1)
  local db
  for db in railway second_db third_db; do
    if ! echo "$databases" | grep -qxF "$db"; then
      ko t_wildcard_independent_pools_per_database "expected SHOW DATABASES to list a distinct pool for ${db}, got: $databases"
      fail_dump t_wildcard_independent_pools_per_database "$name"
      return
    fi
  done

  ok t_wildcard_independent_pools_per_database
  docker rm -f "$name" >/dev/null
}

t_wildcard_auth_query_role_reaches_other_database() {
  # Mirrors Railway's actual production config: AUTH_USER/AUTH_QUERY let
  # pgbouncer authenticate a role that's NOT in the static userlist.txt (only
  # the boot-time PGUSER is) by looking it up in pg_shadow at login time. This
  # confirms that composes correctly with the wildcard entry — a second role,
  # unknown to pgbouncer at boot, reaching a non-default database.
  local name=t-wildcard-auth-query
  docker exec "$UPSTREAM" psql -U postgres -c "CREATE ROLE otheruser LOGIN PASSWORD 'otherpass'" >/dev/null 2>&1 || true
  docker exec "$UPSTREAM" psql -U postgres -d second_db -c "GRANT ALL ON SCHEMA public TO otheruser" >/dev/null 2>&1 || true

  start_bouncer "$name" \
    -e AUTH_USER=postgres \
    -e AUTH_QUERY='SELECT usename, passwd FROM pg_shadow WHERE usename=$1' \
    || { ko t_wildcard_auth_query_role_reaches_other_database "pgbouncer did not come up"; fail_dump t_wildcard_auth_query_role_reaches_other_database "$name"; return; }

  local out
  out=$(docker exec "$name" psql "postgresql://otheruser:otherpass@localhost:5432/second_db?sslmode=disable" -At -c "select current_user" 2>&1)
  assert_eq "$out" "otheruser" "a role resolved only via auth_query (not the boot-time userlist) should reach a non-default database through the wildcard entry" || { ko t_wildcard_auth_query_role_reaches_other_database ""; fail_dump t_wildcard_auth_query_role_reaches_other_database "$name"; return; }

  ok t_wildcard_auth_query_role_reaches_other_database
  docker rm -f "$name" >/dev/null
}

t_explicit_single_database_pin_still_works() {
  # Control case: an operator who explicitly pins PGDATABASE to one database
  # (the pre-wildcard default, and still valid config) should keep getting
  # the OLD behavior — the pinned database works, everything else gets
  # PgBouncer's own "no such database" rejection. This is the exact error
  # string from the original customer report; proves it's still reachable
  # for anyone who wants a single-database pool, and that the wildcard tests
  # above are actually exercising the wildcard rather than pgbouncer just
  # permitting everything unconditionally.
  local name=t-single-db-pin
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$UPSTREAM" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE=railway -e PGPORT=5432 \
    "$IMAGE" >/dev/null
  local deadline=$(($(date +%s) + 30)) up=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -c "select 1" >/dev/null 2>&1 && { up=1; break; }
    sleep 1
  done
  if [ "$up" -ne 1 ]; then
    ko t_explicit_single_database_pin_still_works "pgbouncer did not come up with an explicit single-database pin"
    fail_dump t_explicit_single_database_pin_still_works "$name"
    return
  fi

  local pinned
  pinned=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/railway?sslmode=disable" -At -c "select current_database()" 2>&1)
  assert_eq "$pinned" "railway" "the pinned database should still work" || { ko t_explicit_single_database_pin_still_works ""; fail_dump t_explicit_single_database_pin_still_works "$name"; return; }

  local rejected
  rejected=$(docker exec "$name" psql "postgresql://postgres:testpass@localhost:5432/second_db?sslmode=disable" -c "select 1" 2>&1)
  assert_contains "$rejected" "no such database" "a database outside the pin should get PgBouncer's own rejection, not be silently routed" || { ko t_explicit_single_database_pin_still_works ""; fail_dump t_explicit_single_database_pin_still_works "$name"; return; }

  ok t_explicit_single_database_pin_still_works
  docker rm -f "$name" >/dev/null
}

ALL_TESTS=(
  t_vanilla_boot
  t_tls_allow_default_accepts_both
  t_tls_sslmode_disable_opt_out
  t_tls_custom_cert_respected
  t_server_tls_scope_unchanged
  t_server_tls_prefer_encrypts_against_ssl_upstream
  t_wildcard_routes_multiple_databases
  t_wildcard_implicit_default_when_pgdatabase_unset
  t_wildcard_nonexistent_database_surfaces_postgres_error
  t_wildcard_independent_pools_per_database
  t_wildcard_auth_query_role_reaches_other_database
  t_explicit_single_database_pin_still_works
)

trap 'cleanup_test_resources' EXIT

ensure_image
ensure_network
ensure_upstream

if [ "$#" -gt 0 ]; then
  TESTS=("$@")
else
  TESTS=("${ALL_TESTS[@]}")
fi

for t in "${TESTS[@]}"; do
  log "running $t"
  if ! declare -f "$t" > /dev/null; then
    ko "$t" "no such test"
    continue
  fi
  before_pass=$PASS
  before_fail=$FAIL
  "$t"
  if [ "$PASS" -eq "$before_pass" ] && [ "$FAIL" -eq "$before_fail" ]; then
    ko "$t" "test exited without recording PASS or FAIL — likely a silent skip"
  fi
done

echo
log "summary: ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}"
if [ "$FAIL" -gt 0 ]; then
  echo "${R}failed:${N} ${FAILED_TESTS[*]}"
fi
exit "$FAIL"
