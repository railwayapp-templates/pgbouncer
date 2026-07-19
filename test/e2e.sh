#!/usr/bin/env bash
# test/e2e.sh — end-to-end harness for this image's TLS defaulting
# behavior. Mirrors postgres-ssl's test/e2e.sh / postgres-ha's
# test/e2e-ha.sh harness shape (color helpers, t_* functions, assert_*,
# ALL_TESTS dispatch).
#
# Boots this image against a plain postgres:16-alpine upstream (and, for
# the server-side test, the real ghcr.io/railwayapp-templates/postgres-ssl
# image) and walks every assertion about client_tls_sslmode/server_tls_sslmode
# defaulting. Each assertion is a `t_*` function; final exit code is the
# count of failed tests.
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
start_bouncer() {
  local name="$1"; shift
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --label pgbouncer-e2e=1 --network "$NET" \
    -e UPSTREAM_POSTGRESQL_HOST="$UPSTREAM" \
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE=railway -e PGPORT=5432 \
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
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE=railway -e PGPORT=5432 \
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
    -e PGUSER=postgres -e PGPASSWORD=testpass -e PGDATABASE=railway -e PGPORT=5432 \
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

ALL_TESTS=(
  t_vanilla_boot
  t_tls_allow_default_accepts_both
  t_tls_sslmode_disable_opt_out
  t_tls_custom_cert_respected
  t_server_tls_scope_unchanged
  t_server_tls_prefer_encrypts_against_ssl_upstream
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
