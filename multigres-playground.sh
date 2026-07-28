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
# See docs/plans/2026-07-27-realtime-playground-against-multigres-design.md
# for the full design and rationale (notably: why there's no reverse proxy,
# and why the tenant's external_id is "localhost").
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
PLAYGROUND_WORKTREE_BRANCH="multigres-realtime-url"
PLAYGROUND_WORKTREE_DIR="${PLAYGROUND_DIR}/.worktrees/${PLAYGROUND_WORKTREE_BRANCH}"

REALTIME_PORT="${REALTIME_PORT:-4000}"
PLAYGROUND_PORT="${PLAYGROUND_PORT:-3000}"

# external_id "localhost": Realtime resolves tenants from the first label of
# the Host header (Database.get_external_id/1). Everything here runs on
# localhost (just different ports), so the Host header's hostname is always
# "localhost" — no subdomain tricks needed.
PLAYGROUND_TENANT_ID="${PLAYGROUND_TENANT_ID:-localhost}"
PLAYGROUND_JWT_SECRET="${PLAYGROUND_JWT_SECRET:-multigres-playground-secret}"

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-15432}"
GATEWAY_USER="${GATEWAY_USER:-postgres}"
GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-postgres}"
GATEWAY_DB="${GATEWAY_DB:-postgres}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/.run"
PATCH_FILE="${SCRIPT_DIR}/realtime-playground/0001-use-public-realtime-url.patch"
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

# Kill the PID recorded in pidfile $1, tolerating an already-dead process.
kill_pidfile() {
  local pidfile="$1" label="$2"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping $label (pid $pid)"
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

# Clone the Playground repo, create its worktree, and apply the
# PUBLIC_REALTIME_URL patch — each step skipped if already done.
ensure_playground_worktree() {
  command -v pnpm >/dev/null 2>&1 || die "pnpm not found on PATH (needed to run the Playground)"

  if [ ! -d "$PLAYGROUND_DIR" ]; then
    log "Cloning $PLAYGROUND_REPO_URL into $PLAYGROUND_DIR"
    git clone "$PLAYGROUND_REPO_URL" "$PLAYGROUND_DIR"
  fi

  if [ ! -d "$PLAYGROUND_WORKTREE_DIR" ]; then
    log "Creating worktree $PLAYGROUND_WORKTREE_DIR"
    (cd "$PLAYGROUND_DIR" && git worktree add ".worktrees/${PLAYGROUND_WORKTREE_BRANCH}" -b "$PLAYGROUND_WORKTREE_BRANCH")
  fi

  local target="$PLAYGROUND_WORKTREE_DIR/apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx"
  if ! grep -q "PUBLIC_REALTIME_URL" "$target"; then
    log "Applying patch: prefer PUBLIC_REALTIME_URL in RealtimeClientForm.tsx"
    (cd "$PLAYGROUND_WORKTREE_DIR" && git apply "$PATCH_FILE")
  fi
}

cmd_up() {
  mkdir -p "$RUN_DIR"

  log "Bringing up the Multigres cluster"
  "$SCRIPT_DIR/multigres-realtime.sh" up

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

  log "Registering/updating the Multigres tenant and minting an anon JWT"
  local jwt
  if ! jwt="$(cd "$REALTIME_DIR" && \
    GATEWAY_HOST="$GATEWAY_HOST" GATEWAY_PORT="$GATEWAY_PORT" \
    GATEWAY_USER="$GATEWAY_USER" GATEWAY_PASSWORD="$GATEWAY_PASSWORD" GATEWAY_DB="$GATEWAY_DB" \
    PLAYGROUND_TENANT_ID="$PLAYGROUND_TENANT_ID" PLAYGROUND_JWT_SECRET="$PLAYGROUND_JWT_SECRET" \
    GEN_RPC_TCP_SERVER_PORT=0 GEN_RPC_TCP_CLIENT_PORT=0 \
    mix run "$SETUP_SCRIPT" 2>"$RUN_DIR/playground_setup.log" | tail -1)"; then
    die "playground_setup.exs failed — see $RUN_DIR/playground_setup.log"
  fi

  [ -n "$jwt" ] || die "playground_setup.exs did not print a JWT — see $RUN_DIR/playground_setup.log"
  log "Minted anon JWT for tenant '${PLAYGROUND_TENANT_ID}'"

  ensure_playground_worktree

  log "Writing $PLAYGROUND_WORKTREE_DIR/.env"
  cat > "$PLAYGROUND_WORKTREE_DIR/.env" <<ENV
PUBLIC_REALTIME_URL=http://localhost:${REALTIME_PORT}/socket
PUBLIC_SUPABASE_KEY=${jwt}
PUBLIC_SUPABASE_URL=http://localhost:${REALTIME_PORT}
ENABLE_PLAYGROUND=true
ENV

  if [ ! -d "$PLAYGROUND_WORKTREE_DIR/node_modules" ]; then
    log "Installing playground dependencies (pnpm install)"
    (cd "$PLAYGROUND_WORKTREE_DIR" && pnpm install)
  fi

  log "Starting the Playground (pnpm web) on :$PLAYGROUND_PORT"
  kill_pidfile "$RUN_DIR/playground.pid" "Playground"
  (
    cd "$PLAYGROUND_WORKTREE_DIR"
    PORT="$PLAYGROUND_PORT" nohup pnpm web > "$RUN_DIR/playground.log" 2>&1 &
    echo $! > "$RUN_DIR/playground.pid"
  )

  wait_for_http "http://localhost:${PLAYGROUND_PORT}" "Playground"

  echo
  cmd_info
}

cmd_down() {
  die "cmd_down not yet implemented"
}

cmd_logs() {
  die "cmd_logs not yet implemented"
}

cmd_info() {
  die "cmd_info not yet implemented"
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
  PLAYGROUND_JWT_SECRET   tenant jwt_secret (default: multigres-playground-secret)
  GATEWAY_HOST/PORT/USER/PASSWORD/DB   gateway target (same defaults as
                          multigres-realtime.sh / broadcast_smoke.exs)
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
