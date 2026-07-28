#!/usr/bin/env bash
#
# multigres-playground.sh — run the Realtime Playground
# (supabase-community/realtime-playground) against a Multigres gateway, for
# manual interactive exploration of Broadcast/Presence/Postgres Changes.
#
# Composes with multigres-realtime.sh (this repo) for the Multigres cluster
# itself; this script additionally brings up a persistent Realtime server
# (mix phx.server, not the one-off smoke scripts) and the Playground's
# Next.js dev server, wires a tenant + anon JWT between them, and prints the
# Playground's URL.
#
# See ~/dev/multigres-plans/2026-07-28-realtime-playground-test-runner-against-multigres-design.md
# for the full design and rationale (notably: why Kong fronts GoTrue/PostgREST/
# Realtime, and why the tenant's external_id is "localhost").
#
# Prerequisite (not automated here, same as the existing README): Realtime's
# metadata DB has been set up at least once —
#   cd ~/dev/realtime && mix ecto.setup
#
#   ./multigres-playground.sh up                     # bring everything up, print the URL
#   ./multigres-playground.sh info                    # reprint URL + teardown instructions
#   ./multigres-playground.sh logs [realtime|playground]  # tail logs (default: both)
#   ./multigres-playground.sh down [--with-cluster]   # stop realtime+playground (+ cluster)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------

REALTIME_DIR="${REALTIME_DIR:-$HOME/dev/realtime}"

PLAYGROUND_DIR="${PLAYGROUND_DIR:-$HOME/dev/realtime-playground}"
PLAYGROUND_REPO_URL="${PLAYGROUND_REPO_URL:-https://github.com/supabase-community/realtime-playground.git}"

REALTIME_PORT="${REALTIME_PORT:-4000}"
PLAYGROUND_PORT="${PLAYGROUND_PORT:-3000}"

# external_id "localhost": Realtime resolves tenants from the first label of
# the Host header (Database.get_external_id/1). Everything here runs on
# localhost (just different ports), so the Host header's hostname is always
# "localhost" — no subdomain tricks needed.
PLAYGROUND_TENANT_ID="${PLAYGROUND_TENANT_ID:-localhost}"
PLAYGROUND_JWT_SECRET="${PLAYGROUND_JWT_SECRET:-multigres-playground-jwt-secret-key}"

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-15432}"
GATEWAY_USER="${GATEWAY_USER:-postgres}"
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-postgres}"
GATEWAY_DB="${GATEWAY_DB:-postgres}"

KONG_PORT="${KONG_PORT:-8000}"
PLAYGROUND_NETWORK="multigres-playground-net"
GOTRUE_IMAGE="${GOTRUE_IMAGE:-supabase/gotrue:v2.186.0}"
POSTGREST_IMAGE="${POSTGREST_IMAGE:-postgrest/postgrest:v14.8}"
KONG_IMAGE="${KONG_IMAGE:-kong:3.9.1}"

PLAYGROUND_TEST_USER_EMAIL="${PLAYGROUND_TEST_USER_EMAIL:-playground@localhost}"
PLAYGROUND_TEST_USER_PASSWORD="${PLAYGROUND_TEST_USER_PASSWORD:-multigres-playground-password}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/.run"
PATCH_FILE="${SCRIPT_DIR}/realtime-playground/0002-fix-broadcast-send-schema-nonoptional.patch"
SETUP_SCRIPT="${SCRIPT_DIR}/realtime/playground_setup.exs"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Wait until `curl -sf` against $1 succeeds, or die after WAIT_TIMEOUT.
wait_for_http() {
  local url="$1" label="$2" waited=0
  until curl -sf --max-time 5 "$url" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
      die "$label did not become ready within ${WAIT_TIMEOUT}s ($url)"
    fi
  done
}

# Wait until container $1's Docker healthcheck reports "healthy", or die after
# WAIT_TIMEOUT. (curl-based wait_for_http doesn't work for GoTrue/PostgREST,
# which aren't published to the host — only Kong is.)
wait_for_healthy() {
  local container="$1" waited=0 status
  until status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)" \
    && [ "$status" = "healthy" ]; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
      die "$container did not become healthy within ${WAIT_TIMEOUT}s (last status: ${status:-unknown})"
    fi
  done
}

# Kill the PID recorded in pidfile $1, tolerating an already-dead process.
kill_pidfile() {
  local pidfile="$1" label="$2"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping $label (pid $pid)"
      # Signal $pid and its whole descendant tree, not just $pid itself.
      # pnpm/Next.js fan out into a multi-process tree rather than
      # exec-replacing themselves, so `kill -9 $pid` alone would only hit
      # the top-level process and orphan the rest (notably next-server,
      # which keeps holding its port). Note: this can't be done by
      # signalling $pid's process group (kill -- "-$pid") because bash
      # scripts run without job control (monitor mode) by default, so a
      # backgrounded job's pgid is inherited from the ambient group rather
      # than being its own pid — verified empirically against this script's
      # actual `pnpm web` process tree.
      local pids=("$pid") i=0 kids k
      while [ "$i" -lt "${#pids[@]}" ]; do
        kids="$(pgrep -P "${pids[$i]}" 2>/dev/null || true)"
        for k in $kids; do pids+=("$k"); done
        i=$((i + 1))
      done
      kill "${pids[@]}" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      pids=("$pid"); i=0
      while [ "$i" -lt "${#pids[@]}" ]; do
        kids="$(pgrep -P "${pids[$i]}" 2>/dev/null || true)"
        for k in $kids; do pids+=("$k"); done
        i=$((i + 1))
      done
      kill -9 "${pids[@]}" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

# Create the extra Postgres roles GoTrue and PostgREST need to connect as.
# multigres-realtime.sh already creates anon/authenticated/service_role/etc. for
# Realtime's own compat surface; these two are specific to adding GoTrue+PostgREST.
prepare_gateway_roles() {
  log "Ensuring GoTrue/PostgREST roles exist on the gateway"
  PGPASSWORD="$GATEWAY_PASSWORD" psql -v ON_ERROR_STOP=1 \
    -h "$GATEWAY_HOST" -p "$GATEWAY_PORT" -U "$GATEWAY_USER" -d "$GATEWAY_DB" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '${GATEWAY_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOINHERIT CREATEROLE LOGIN PASSWORD '${GATEWAY_PASSWORD}';
  END IF;
END
\$\$;
GRANT anon, authenticated, service_role TO authenticator;
GRANT ALL ON SCHEMA auth TO supabase_auth_admin;
ALTER SCHEMA auth OWNER TO supabase_auth_admin;
ALTER ROLE supabase_auth_admin SET search_path TO auth, public;
-- GoTrue's migrations CREATE OR REPLACE these (already created by
-- multigres-realtime.sh, owned by postgres) and its own schema_migrations
-- tracking table (created in "public" regardless of search_path).
GRANT CREATE, USAGE ON SCHEMA public TO supabase_auth_admin;
ALTER FUNCTION auth.uid() OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.role() OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.email() OWNER TO supabase_auth_admin;
ALTER FUNCTION auth.jwt() OWNER TO supabase_auth_admin;
SQL
}

# Start GoTrue, PostgREST, and Kong on a dedicated network, all pointed at the
# gateway (and, for Kong, at Realtime) via host.docker.internal. Only Kong
# publishes a host port — GoTrue/PostgREST are reachable only through it,
# matching the real self-hosted stack.
start_auth_stack() {
  docker network inspect "$PLAYGROUND_NETWORK" >/dev/null 2>&1 || \
    docker network create "$PLAYGROUND_NETWORK" >/dev/null

  log "Starting GoTrue"
  docker rm -f playground-gotrue >/dev/null 2>&1 || true
  docker run -d --name playground-gotrue \
    --network "$PLAYGROUND_NETWORK" --network-alias gotrue \
    --add-host host.docker.internal:host-gateway \
    --health-cmd="wget --no-verbose --tries=1 --spider http://localhost:9999/health || exit 1" \
    --health-interval=5s --health-timeout=5s --health-retries=5 \
    -e GOTRUE_API_HOST=0.0.0.0 \
    -e GOTRUE_API_PORT=9999 \
    -e API_EXTERNAL_URL="http://localhost:${KONG_PORT}" \
    -e GOTRUE_DB_DRIVER=postgres \
    -e GOTRUE_DB_DATABASE_URL="postgres://supabase_auth_admin:${GATEWAY_PASSWORD}@host.docker.internal:${GATEWAY_PORT}/${GATEWAY_DB}" \
    -e GOTRUE_SITE_URL="http://localhost:${PLAYGROUND_PORT}" \
    -e GOTRUE_DISABLE_SIGNUP=false \
    -e GOTRUE_JWT_ADMIN_ROLES=service_role \
    -e GOTRUE_JWT_AUD=authenticated \
    -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    -e GOTRUE_JWT_EXP=3600 \
    -e GOTRUE_JWT_SECRET="$PLAYGROUND_JWT_SECRET" \
    -e GOTRUE_MAILER_AUTOCONFIRM=true \
    "$GOTRUE_IMAGE" >/dev/null

  log "Starting PostgREST"
  docker rm -f playground-postgrest >/dev/null 2>&1 || true
  docker run -d --name playground-postgrest \
    --network "$PLAYGROUND_NETWORK" --network-alias postgrest \
    --add-host host.docker.internal:host-gateway \
    -e PGRST_DB_URI="postgres://authenticator:${GATEWAY_PASSWORD}@host.docker.internal:${GATEWAY_PORT}/${GATEWAY_DB}" \
    -e PGRST_DB_SCHEMAS=public \
    -e PGRST_DB_ANON_ROLE=anon \
    -e PGRST_JWT_SECRET="$PLAYGROUND_JWT_SECRET" \
    "$POSTGREST_IMAGE" >/dev/null

  wait_for_healthy playground-gotrue
  log "GoTrue is up"
}

# Render kong/kong.yml with the current run's JWTs and start Kong. Must be
# called after $anon_jwt/$service_jwt are known.
start_kong() {
  local anon_jwt="$1" service_jwt="$2"
  log "Rendering Kong config"
  ANON_JWT="$anon_jwt" SERVICE_JWT="$service_jwt" \
    envsubst '${ANON_JWT} ${SERVICE_JWT}' < "$SCRIPT_DIR/kong/kong.yml" > "$RUN_DIR/kong.yml"

  log "Starting Kong on :$KONG_PORT"
  docker rm -f playground-kong >/dev/null 2>&1 || true
  docker run -d --name playground-kong \
    --network "$PLAYGROUND_NETWORK" \
    --add-host host.docker.internal:host-gateway \
    -p "${KONG_PORT}:8000" \
    -v "$RUN_DIR/kong.yml:/kong.yml:ro" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/kong.yml \
    -e KONG_PLUGINS=cors,key-auth \
    --health-cmd="kong health" --health-interval=5s --health-timeout=5s --health-retries=5 \
    "$KONG_IMAGE" >/dev/null

  wait_for_healthy playground-kong
  log "Kong is up"
}

# Create/update the fixture schema Test Runner's auth-gated suites need
# (tables, RLS, triggers, publication entries) by running realtime-check.ts
# *in place* from the Realtime checkout — it already contains this logic
# (see docs/plans/2026-07-28-...-design.md, "Fixture setup"), so there's
# nothing to copy here. Picks the cheapest DB-required category
# ("authorization") purely to trigger its setup() step; the one test it runs
# is a bonus compatibility check.
run_fixture_setup() {
  local anon_jwt="$1" service_jwt="$2"
  command -v bun >/dev/null 2>&1 || die "bun not found on PATH (needed for realtime-check.ts — see https://bun.sh)"

  log "Running realtime-check.ts fixture setup against the gateway"
  if ! bun run "$REALTIME_DIR/test/e2e/realtime-check.ts" \
    --env local --url "http://localhost:${KONG_PORT}" \
    --db-url "postgresql://postgres:${GATEWAY_PASSWORD}@${GATEWAY_HOST}:${GATEWAY_PORT}/${GATEWAY_DB}" \
    --publishable-key "$anon_jwt" --secret-key "$service_jwt" \
    --test authorization > "$RUN_DIR/fixture_setup.log" 2>&1; then
    warn "fixture setup reported a failure — see $RUN_DIR/fixture_setup.log"
    warn "(the fixture schema may still have been created; check before re-running)"
  fi
}

# Create a persistent test user via GoTrue's admin API — separate from
# realtime-check.ts's own ephemeral user (which it deletes after its run) —
# so the Playground's .env can reference a stable email/password for a real
# browser session.
create_test_user() {
  local service_jwt="$1"
  log "Ensuring persistent test user ($PLAYGROUND_TEST_USER_EMAIL)"
  local http_status
  http_status="$(curl -s -o "$RUN_DIR/create_test_user.log" -w '%{http_code}' \
    -X POST "http://localhost:${KONG_PORT}/auth/v1/admin/users" \
    -H "apikey: ${service_jwt}" -H "Authorization: Bearer ${service_jwt}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${PLAYGROUND_TEST_USER_EMAIL}\",\"password\":\"${PLAYGROUND_TEST_USER_PASSWORD}\",\"email_confirm\":true}")"

  case "$http_status" in
    200|201) log "  created" ;;
    422)     log "  already exists" ;;
    *) die "could not create test user (HTTP $http_status) — see $RUN_DIR/create_test_user.log" ;;
  esac
}

# Clone the Playground repo and apply the local crash-fix patch — each step
# skipped if already done. No worktree: Kong (added in this plan) makes the
# old URL patch unnecessary, leaving only this one small local fix, which
# doesn't need a separate branch.
ensure_playground_clone() {
  command -v pnpm >/dev/null 2>&1 || die "pnpm not found on PATH (needed to run the Playground)"

  if [ ! -d "$PLAYGROUND_DIR" ]; then
    log "Cloning $PLAYGROUND_REPO_URL into $PLAYGROUND_DIR"
    git clone "$PLAYGROUND_REPO_URL" "$PLAYGROUND_DIR"
  fi

  local schemas="$PLAYGROUND_DIR/packages/realtime-core/src/schemas/index.ts"
  if grep -qF "default('message').nonoptional()" "$schemas"; then
    log "Applying patch: fix broadcastSendSchema's .nonoptional()-after-.default() crash"
    (cd "$PLAYGROUND_DIR" && git apply "$PATCH_FILE")
  fi
}

cmd_up() {
  mkdir -p "$RUN_DIR"

  log "Bringing up the Multigres cluster"
  "$SCRIPT_DIR/multigres-realtime.sh" up
  prepare_gateway_roles

  log "Ensuring Realtime's metadata DB is running"
  (cd "$REALTIME_DIR" && mise run db-start)

  log "Starting Realtime (mix phx.server) on :$REALTIME_PORT"
  kill_pidfile "$RUN_DIR/realtime.pid" "Realtime"
  (
    cd "$REALTIME_DIR"
    PORT="$REALTIME_PORT" nohup mix phx.server > "$RUN_DIR/realtime.log" 2>&1 &
    echo $! > "$RUN_DIR/realtime.pid"
  )

  sleep 2
  if ! kill -0 "$(cat "$RUN_DIR/realtime.pid")" 2>/dev/null; then
    warn "Realtime exited immediately — recent log output:"
    tail -n 40 "$RUN_DIR/realtime.log" || true
    die "Realtime failed to start. If this is the first run, make sure you've run 'mix ecto.setup' in $REALTIME_DIR."
  fi

  wait_for_http "http://localhost:${REALTIME_PORT}/status" "Realtime"
  log "Realtime is up (logs: $RUN_DIR/realtime.log)"

  start_auth_stack

  log "Registering/updating the Multigres tenant and minting JWTs"
  local setup_output anon_jwt service_jwt
  if ! setup_output="$(cd "$REALTIME_DIR" && \
    GATEWAY_HOST="$GATEWAY_HOST" GATEWAY_PORT="$GATEWAY_PORT" \
    GATEWAY_USER="$GATEWAY_USER" GATEWAY_PASSWORD="$GATEWAY_PASSWORD" GATEWAY_DB="$GATEWAY_DB" \
    PLAYGROUND_TENANT_ID="$PLAYGROUND_TENANT_ID" PLAYGROUND_JWT_SECRET="$PLAYGROUND_JWT_SECRET" \
    GEN_RPC_TCP_SERVER_PORT=0 GEN_RPC_TCP_CLIENT_PORT=0 \
    mix run "$SETUP_SCRIPT" 2>"$RUN_DIR/playground_setup.log" | tail -2)"; then
    die "playground_setup.exs failed — see $RUN_DIR/playground_setup.log"
  fi
  anon_jwt="$(printf '%s\n' "$setup_output" | grep '^ANON_JWT=' | cut -d= -f2-)"
  service_jwt="$(printf '%s\n' "$setup_output" | grep '^SERVICE_JWT=' | cut -d= -f2-)"
  [ -n "$anon_jwt" ] && [ -n "$service_jwt" ] || die "playground_setup.exs did not print both JWTs — see $RUN_DIR/playground_setup.log"
  log "Minted anon + service_role JWTs for tenant '${PLAYGROUND_TENANT_ID}'"

  start_kong "$anon_jwt" "$service_jwt"
  run_fixture_setup "$anon_jwt" "$service_jwt"
  create_test_user "$service_jwt"

  ensure_playground_clone

  log "Writing $PLAYGROUND_DIR/.env"
  cat > "$PLAYGROUND_DIR/.env" <<ENV
PUBLIC_SUPABASE_URL=http://localhost:${KONG_PORT}
PUBLIC_SUPABASE_KEY=${anon_jwt}
PUBLIC_TEST_USER_EMAIL=${PLAYGROUND_TEST_USER_EMAIL}
PUBLIC_TEST_USER_PASSWORD=${PLAYGROUND_TEST_USER_PASSWORD}
ENABLE_PLAYGROUND=true
ENV

  if [ ! -d "$PLAYGROUND_DIR/node_modules" ]; then
    log "Installing playground dependencies (pnpm install)"
    (cd "$PLAYGROUND_DIR" && pnpm install)
  fi

  log "Starting the Playground (pnpm web) on :$PLAYGROUND_PORT"
  kill_pidfile "$RUN_DIR/playground.pid" "Playground"
  (
    cd "$PLAYGROUND_DIR"
    PORT="$PLAYGROUND_PORT" nohup pnpm web > "$RUN_DIR/playground.log" 2>&1 &
    echo $! > "$RUN_DIR/playground.pid"
  )

  wait_for_http "http://localhost:${PLAYGROUND_PORT}" "Playground"

  echo
  cmd_info
}

cmd_down() {
  local with_cluster=false
  for a in "$@"; do
    case "$a" in
      --with-cluster) with_cluster=true ;;
      *) die "unknown flag for down: $a" ;;
    esac
  done

  kill_pidfile "$RUN_DIR/playground.pid" "Playground"
  kill_pidfile "$RUN_DIR/realtime.pid" "Realtime"

  log "Stopping GoTrue/PostgREST/Kong"
  docker rm -f playground-kong playground-postgrest playground-gotrue >/dev/null 2>&1 || true

  if [ "$with_cluster" = true ]; then
    "$SCRIPT_DIR/multigres-realtime.sh" down
  else
    log "Multigres cluster left running (pass --with-cluster to also stop it)"
  fi
}

cmd_logs() {
  local which="${1:-all}"
  case "$which" in
    realtime)   tail -f "$RUN_DIR/realtime.log" ;;
    playground) tail -f "$RUN_DIR/playground.log" ;;
    all)        tail -f "$RUN_DIR/realtime.log" "$RUN_DIR/playground.log" ;;
    *) die "unknown logs target: $which (expected realtime|playground|all)" ;;
  esac
}

cmd_info() {
  cat <<INFO
Realtime Playground is running against the Multigres gateway.

  Playground   http://localhost:${PLAYGROUND_PORT}/playground
  Test Runner  http://localhost:${PLAYGROUND_PORT}/test
  Kong         http://localhost:${KONG_PORT}  (auth/rest/realtime routing)
  Realtime     http://localhost:${REALTIME_PORT}  (tenant: ${PLAYGROUND_TENANT_ID})
  Gateway      ${GATEWAY_USER}@${GATEWAY_HOST}:${GATEWAY_PORT}/${GATEWAY_DB}

  Test user    ${PLAYGROUND_TEST_USER_EMAIL} / ${PLAYGROUND_TEST_USER_PASSWORD}

  Fresh JWTs are minted on every 'up' and written into
  ${PLAYGROUND_DIR}/.env — no manual copying needed.

  Logs:
    $0 logs             # both
    $0 logs realtime
    $0 logs playground

  Tear down:
    $0 down                 # stop everything except the cluster
    $0 down --with-cluster  # also stop the Multigres cluster
INFO
}

usage() {
  cat <<USAGE
Usage: $0 <command>

  up                     Bring up the cluster, Realtime, and the Playground
  info                   Print URLs and teardown instructions
  logs [target]          Tail logs (target: realtime|playground|all, default all)
  down [--with-cluster]  Stop Realtime + Playground (and optionally the cluster)

Environment:
  REALTIME_DIR            Realtime checkout to run mix phx.server from
                          (default: ~/dev/realtime)
  PLAYGROUND_DIR          where to clone supabase-community/realtime-playground
                          (default: ~/dev/realtime-playground)
  REALTIME_PORT           Realtime's HTTP/WS port (default: 4000)
  PLAYGROUND_PORT         Playground's Next.js dev port (default: 3000)
  PLAYGROUND_TENANT_ID    tenant external_id (default: localhost)
  PLAYGROUND_JWT_SECRET   tenant jwt_secret (default: multigres-playground-jwt-secret-key)
  GATEWAY_HOST/PORT/USER/PASSWORD/DB   gateway target (same defaults as
                          multigres-realtime.sh / broadcast_smoke.exs)
  KONG_PORT                     Kong's published port (default: 8000)
  PLAYGROUND_TEST_USER_EMAIL    persistent test user email
                                 (default: playground@localhost)
  PLAYGROUND_TEST_USER_PASSWORD persistent test user password
                                 (default: multigres-playground-password)
  WAIT_TIMEOUT            seconds to wait for each health check (default: 60)
USAGE
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] && shift || true
  case "$cmd" in
    up)   cmd_up "$@" ;;
    info) cmd_info "$@" ;;
    logs) cmd_logs "$@" ;;
    down) cmd_down "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
