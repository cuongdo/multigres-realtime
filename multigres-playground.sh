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
  until curl -sf "$url" >/dev/null 2>&1; do
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
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

cmd_up() {
  die "cmd_up not yet implemented"
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
