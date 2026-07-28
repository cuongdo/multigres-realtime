#!/usr/bin/env bash
#
# multigres-realtime.sh — bring up a Multigres cluster in Docker and prepare it
# so Supabase Realtime (Broadcast-from-Database / logical replication) can run
# against it.
#
# The Multigres cluster image (Dockerfile.cluster + docker-compose.yml in the
# multigres repo) bundles a full cluster — etcd, multiadmin, and per-cell
# pgctld/PostgreSQL + multipooler + multiorch + multigateway — and exposes the
# zone1 multigateway on the PostgreSQL wire protocol. Realtime points its
# replication connection at that gateway exactly as it would at a normal
# PostgreSQL server; the gateway tunnels the replication=database connection
# through to PostgreSQL.
#
# Building from a local worktree (the default) compiles the CURRENT checkout, so
# this runs whatever branch is checked out there — not the nightly ghcr.io
# image. Defaults to a worktree tracking upstream/main (all Realtime-related
# fixes are merged there); set MULTIGRES_DIR to test a different branch.
#
# By default the cluster builds on the Supabase-flavored base image (see
# multigres PR #1203 / docker/README.md "Custom base image") rather than stock
# Debian `postgres` — it already bundles wal2json, the auth.*/realtime/storage
# schemas, the anon/authenticated/service_role/supabase_* roles, and default
# privilege grants, avoiding a pile of Supabase-DB provisioning workarounds
# this script would otherwise need. Set MULTIGRES_POSTGRES_IMAGE="" (+
# MULTIGRES_PROVISION_PG_PACKAGES="") to build on stock Debian postgres
# instead, e.g. to isolate whether a failure is Multigres-specific vs.
# Supabase-image-specific:
#
#   MULTIGRES_POSTGRES_IMAGE="" MULTIGRES_PROVISION_PG_PACKAGES="" ./multigres-realtime.sh up
#
# The connecting superuser (PGUSER) is auto-detected from the running
# container's POSTGRES_USER (supabase_admin for the Supabase base, postgres
# for stock) — override explicitly by exporting PGUSER yourself.
#
#   ./multigres-realtime.sh up      # build + start the cluster, prep roles, print info
#   ./multigres-realtime.sh info    # print connection details + how to test
#   ./multigres-realtime.sh psql    # open psql against the gateway
#   ./multigres-realtime.sh logs    # follow cluster logs
#   ./multigres-realtime.sh down    # stop & remove the cluster (add -v to wipe data)
#
# Then, from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/broadcast_smoke.exs
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via environment)
# ----------------------------------------------------------------------------

# Multigres checkout to build the cluster image from. Defaults to a worktree
# tracking upstream/main (all Realtime-related fixes are merged there — no
# need to build from an unmerged branch anymore). Point this at any multigres
# checkout to test a different branch.
MULTIGRES_DIR="${MULTIGRES_DIR:-/Users/cdo/dev/multigres/.worktrees/upstream-main}"

# Host port the gateway's PostgreSQL endpoint is published on. This must match
# the published port in the multigres docker-compose.yml (15432 by default);
# changing it here alone is not enough — edit the compose file's ports/env too.
GATEWAY_PG_PORT="${GATEWAY_PG_PORT:-15432}"

# PostgreSQL max_connections for the bundled PG (also sizes the pooler to this
# minus 10).
#
# Do NOT raise this to try to fix periodic `UnableToConnectToProject` /
# `:tenant_database_unavailable` failures during a full-suite run (mix test,
# no file filter, TENANT_DB=gateway). Verified 2026-07-10: tripling this
# (100->300) barely changed the failure's timing/count, and broke 7 unrelated
# tests that rely on a deliberately low connection ceiling to simulate "too
# many connections" (Realtime.Tenants.ConnectTest, Realtime.DatabaseTest,
# RealtimeWeb.RealtimeChannelTest). The stalls are not a connection-count
# problem — see investigations/2026-07-10-realtime-fullsuite-tenant-database-unavailable-stalls.md
# in the plans repo for the current (unconfirmed) leading hypothesis
# (periodic checkpoint I/O stalls) and what's already been ruled out.
MULTIGRES_PG_MAX_CONNECTIONS="${MULTIGRES_PG_MAX_CONNECTIONS:-100}"

# Base image to build the cluster on + whether to skip apt provisioning of
# pgBackRest/pgvector/procps (the Supabase image below already bundles them,
# plus wal2json, the auth.*/realtime/storage/graphql schemas, the anon/
# authenticated/service_role/supabase_* roles, and default privilege grants —
# all the Supabase-DB provisioning gaps stock Debian postgres lacks). See
# docker/README.md "Custom base image" in the multigres repo (PR #1203).
# Override to "" (+ MULTIGRES_PROVISION_PG_PACKAGES="") to build on stock
# Debian `postgres:17.7` instead.
MULTIGRES_POSTGRES_IMAGE="${MULTIGRES_POSTGRES_IMAGE-supabase/postgres:17.6.1.150-multigres}"
MULTIGRES_PROVISION_PG_PACKAGES="${MULTIGRES_PROVISION_PG_PACKAGES-false}"

# Gateway credentials. The superuser follows the base image's POSTGRES_USER
# (`postgres` for stock Debian postgres, `supabase_admin` for the Supabase
# base) — resolve_pguser() auto-detects it from the running container unless
# PGUSER is explicitly exported before calling this script.
PGUSER_OVERRIDE="${PGUSER:-}"
PGUSER="postgres"
PGPASSWORD="postgres"
PGDATABASE="postgres"

# Supabase roles that Realtime's tenant migrations GRANT to but do NOT create
# (they exist by default in supabase/postgres; the bundled image is stock
# postgres, so we create them). `supabase_realtime_admin` is intentionally NOT
# here — Realtime's migration 20240401105812 creates it itself. Edit this list
# if a migration turns out to reference another pre-existing role.
# `dashboard_user` is referenced (REVOKE-only) by migration 20260707120000
# (RestrictRealtimeSchema).
SUPABASE_ROLES=(anon authenticated service_role dashboard_user)

# `supabase_admin` is created separately (see cmd_prep) because, unlike the
# roles above, it must be a LOGIN SUPERUSER: Realtime's ExUnit harness
# (test/support/containers.ex `reset_realtime_schema!`) opens a connection AS
# supabase_admin to drop/recreate the realtime schema between tests. Only
# needed when routing the ExUnit suite at the gateway (TENANT_DB=gateway);
# harmless otherwise. In supabase/postgres this role is a superuser too.

# Schemas Realtime's tenant migrations assume already exist (shipped in
# supabase/postgres; absent in stock postgres). `realtime` must exist before
# Ecto's prefixed migrator can create realtime.schema_migrations; `auth` and
# `extensions` are GRANT targets in the admin-setup migration.
SUPABASE_SCHEMAS=(realtime auth extensions)

# Fixed compose project name so up/down/logs/psql target the same stack
# regardless of the current working directory.
PROJECT="multigres_realtime"
COMPOSE_FILE="${MULTIGRES_DIR}/docker-compose.yml"

# Healthcheck wait timeout (seconds) for `up`.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-240}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

# Resolve PGUSER from the running container's POSTGRES_USER env var (set by the
# base image; `postgres` for stock Debian postgres, `supabase_admin` for the
# Supabase base — see PR #1203). Falls back to `postgres` if the container
# isn't reachable yet or the var is unset. An explicit PGUSER export always
# wins.
resolve_pguser() {
  if [ -n "$PGUSER_OVERRIDE" ]; then
    PGUSER="$PGUSER_OVERRIDE"
    return
  fi
  local detected
  detected="$(compose exec -T multigres sh -c 'echo "${POSTGRES_USER:-postgres}"' 2>/dev/null | tr -d '\r\n')"
  PGUSER="${detected:-postgres}"
}

# Run psql inside the cluster container against the gateway. Using the container
# avoids requiring a psql client on the host; the gateway listens on
# 127.0.0.1:$GATEWAY_PG_PORT inside the container too.
gw_psql() {
  compose exec -T \
    -e PGPASSWORD="$PGPASSWORD" \
    multigres \
    psql -h 127.0.0.1 -p "$GATEWAY_PG_PORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable (is Docker running?)"
  [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE
Set MULTIGRES_DIR to a multigres checkout that contains docker-compose.yml."
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

cmd_up() {
  preflight
  log "Building & starting Multigres cluster from: $MULTIGRES_DIR"
  log "  (gateway PostgreSQL will be published on localhost:${GATEWAY_PG_PORT})"

  if [ -n "$MULTIGRES_POSTGRES_IMAGE" ]; then
    log "  base image: ${MULTIGRES_POSTGRES_IMAGE} (PROVISION_PG_PACKAGES=${MULTIGRES_PROVISION_PG_PACKAGES:-true})"
  fi

  # MULTIGRES_PG_MAX_CONNECTIONS/MULTIGRES_POSTGRES_IMAGE/MULTIGRES_PROVISION_PG_PACKAGES
  # are read from the host env by the compose file; empty values fall back to
  # the compose file's own defaults.
  if ! MULTIGRES_PG_MAX_CONNECTIONS="$MULTIGRES_PG_MAX_CONNECTIONS" \
       MULTIGRES_POSTGRES_IMAGE="$MULTIGRES_POSTGRES_IMAGE" \
       MULTIGRES_PROVISION_PG_PACKAGES="$MULTIGRES_PROVISION_PG_PACKAGES" \
       compose up --build -d --wait --wait-timeout "$WAIT_TIMEOUT"; then
    warn "cluster did not become healthy within ${WAIT_TIMEOUT}s — recent logs:"
    compose logs --tail 60 || true
    die "startup failed. Inspect with: $0 logs"
  fi

  log "Cluster healthy."
  resolve_pguser
  log "  connecting superuser: ${PGUSER}"
  cmd_prep
  echo
  cmd_info
}

cmd_prep() {
  preflight
  resolve_pguser
  log "Preparing gateway PostgreSQL as a Realtime tenant DB (connecting as ${PGUSER})"

  # 1) Ensure the connecting role can drive logical replication. The bundled
  #    `postgres` superuser already has REPLICATION; this makes it explicit and
  #    keeps the script correct if the role ever changes.
  log "  ensuring '${PGUSER}' has REPLICATION"
  gw_psql -v ON_ERROR_STOP=1 -c "ALTER ROLE ${PGUSER} REPLICATION;"

  # 2) Create the Supabase roles Realtime's migrations GRANT to. Idempotent via
  #    a pg_roles guard (CREATE ROLE has no IF NOT EXISTS).
  for role in "${SUPABASE_ROLES[@]}"; do
    log "  ensuring role '${role}'"
    gw_psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') THEN
    CREATE ROLE ${role} NOLOGIN NOINHERIT;
  END IF;
END
\$\$;
SQL
  done

  # 3) Create the Supabase schemas Realtime's migrations assume already exist.
  #    `realtime` in particular must exist before Ecto's prefixed migrator runs.
  for schema in "${SUPABASE_SCHEMAS[@]}"; do
    log "  ensuring schema '${schema}'"
    gw_psql -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS ${schema};"
  done

  # 4) Create/fix up the Supabase admin login roles the ExUnit harness connects
  #    AS when routing the suite at the gateway (TENANT_DB=gateway). In
  #    supabase/postgres these ship usable (LOGIN + password); stock postgres
  #    does not have them, and Realtime's own migrations create
  #    `supabase_realtime_admin` as NOLOGIN with no password — so a connection
  #    as that role (db_user_realtime) fails with 28000 "not permitted to log
  #    in". We make both login-capable with the expected password. Idempotent:
  #    CREATE if absent, otherwise ALTER. Realtime's migration 20240401105812
  #    CREATEs supabase_realtime_admin behind an IF-NOT-EXISTS guard, so
  #    pre-creating it here is safe.
  #      - supabase_admin: SUPERUSER (used to reset the realtime schema).
  #      - supabase_realtime_admin: NOINHERIT CREATEROLE REPLICATION (matches
  #        what migration 20260606120000 grants it; used as the replication/owner
  #        role), NOT superuser.
  #      - postgres: already exists and can log in on this image, but its
  #        password isn't ours to assume — Realtime's schema_test.exs connects
  #        directly as this role (simulating the dashboard/customer role) with
  #        the same PGPASSWORD every other role uses. Discovered 2026-07-14: a
  #        mismatched password here doesn't fail gracefully — Postgrex.start_link
  #        in an ExUnit `setup` block crashes the whole SchemaTest module with a
  #        bare `** (EXIT ...) killed` on every single test, no error detail.
  #        ALTER only (never CREATE — the role is guaranteed to exist already).
  log "  ensuring role 'supabase_admin' (LOGIN SUPERUSER)"
  gw_psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin LOGIN SUPERUSER PASSWORD '${PGPASSWORD}';
  ELSE
    ALTER ROLE supabase_admin LOGIN SUPERUSER PASSWORD '${PGPASSWORD}';
  END IF;
END
\$\$;
SQL

  log "  ensuring role 'supabase_realtime_admin' (LOGIN, NOINHERIT CREATEROLE REPLICATION)"
  gw_psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_realtime_admin') THEN
    CREATE ROLE supabase_realtime_admin LOGIN NOINHERIT CREATEROLE REPLICATION PASSWORD '${PGPASSWORD}';
  ELSE
    ALTER ROLE supabase_realtime_admin LOGIN NOINHERIT CREATEROLE REPLICATION PASSWORD '${PGPASSWORD}';
  END IF;
END
\$\$;
SQL

  log "  ensuring role 'postgres' password matches PGPASSWORD"
  gw_psql -v ON_ERROR_STOP=1 -c "ALTER ROLE postgres PASSWORD '${PGPASSWORD}';"

  # 6) Create the Supabase `auth.*` helper functions the RLS policies reference.
  #    supabase/postgres ships these; stock postgres does not, so RLS policy
  #    evaluation (e.g. `auth.uid()`, `auth.role()`) errors and aborts the
  #    authorization transaction (surfaces downstream as 25P02). They are pure
  #    SQL reading the request.jwt.* GUCs that Realtime's authorization sets via
  #    set_config(...). Quoted heredoc (<<'SQL') — no shell expansion, so $$ and
  #    dollar-quoted bodies are literal.
  log "  ensuring auth.uid/role/email/jwt() helper functions"
  gw_psql -v ON_ERROR_STOP=1 <<'SQL'
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$fn$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.role', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$fn$;

CREATE OR REPLACE FUNCTION auth.email() RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.email', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$fn$;

CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim', true), ''),
    NULLIF(current_setting('request.jwt.claims', true), '')
  )::jsonb
$fn$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role, postgres;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.email(), auth.jwt()
  TO anon, authenticated, service_role, postgres;
SQL

  # The connecting superuser may not be `postgres` (e.g. supabase_admin on the
  # Supabase base image) — grant it explicitly too.
  gw_psql -v ON_ERROR_STOP=1 -c \
    "GRANT USAGE ON SCHEMA auth TO ${PGUSER}; GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.email(), auth.jwt() TO ${PGUSER};"

  # 7) Ensure the wal2json output plugin is available. Realtime's Postgres
  #    Changes (polling CDC) path decodes WAL via wal2json. Probe via SQL first
  #    (authoritative — works regardless of where the base image actually
  #    resolves its dynamic_library_path, e.g. the Supabase/Nix base already
  #    bundles it under a path a shell-level file check would miss). Only
  #    Debian bases lack it; runtime-install into the container (Debian +
  #    PGDG) so the multigres worktree/image stays untouched; it's re-applied on
  #    every `up`/`prep` and lost on `down`. Non-fatal if it can't install
  #    (Broadcast-from-DB does not need it). Idempotent: skips if already present.
  log "  checking wal2json output plugin availability"
  if gw_psql -v ON_ERROR_STOP=1 -tAc \
       "select pg_create_logical_replication_slot('multigres_wal2json_probe', 'wal2json', true)" \
       >/dev/null 2>&1; then
    gw_psql -tAc "select pg_drop_replication_slot('multigres_wal2json_probe')" >/dev/null 2>&1 || true
    log "    wal2json is available"
  else
    log "    not detected; attempting runtime install (Debian + PGDG apt) — non-fatal,"
    log "    lost on 'down', re-applied on every 'up'/'prep'; Broadcast-from-DB is unaffected"
    if ! compose exec -T -u 0 multigres sh -c '
          apt-get update -qq && apt-get install -y -qq "postgresql-$(pg_config --version | grep -oE "[0-9]+" | head -1)-wal2json"
        ' >/dev/null 2>&1; then
      warn "could not install wal2json (Postgres Changes will not work; Broadcast-from-DB is unaffected)"
    fi
  fi

  # 8) Ensure the "supabase_realtime" publication exists. Realtime's legacy
  #    Postgres Changes (postgres_cdc_rls) subscription path only ever ALTERs
  #    this publication (add/remove tables per subscription, in
  #    Subscriptions.create's query) — it never CREATEs it, unlike the newer
  #    Broadcast-from-DB path, which self-creates its own
  #    supabase_realtime_messages_publication on first connect (see the log
  #    line below). In the real stack it's provisioned by supabase/postgres's
  #    own init scripts; our stock-postgres image lacks it. Without it, every
  #    Postgres Changes subscription's INSERT INTO realtime.subscription
  #    silently matches 0 rows (its CTE joins against pg_publication_tables
  #    for this publication name) and the channel never gets its "Subscribed
  #    to PostgreSQL" system message — the client just times out waiting.
  log "  ensuring 'supabase_realtime' publication exists (for Postgres Changes)"
  if [ "$(gw_psql -tAc "select 1 from pg_publication where pubname = 'supabase_realtime'")" != "1" ]; then
    gw_psql -v ON_ERROR_STOP=1 -c "CREATE PUBLICATION supabase_realtime;"
  fi

  log "Prep complete. Realtime will create the realtime objects, publication,"
  log "and replication slot itself on first connect (this exercises the tunnel)."
}

cmd_info() {
  resolve_pguser
  cat <<INFO
Multigres gateway is ready as a Realtime tenant database.

  Connection
    host      127.0.0.1
    port      ${GATEWAY_PG_PORT}
    database  ${PGDATABASE}
    user      ${PGUSER}
    password  ${PGPASSWORD}
    sslmode   disable   (Realtime: set "ssl_enforced" => false)

  Realtime tenant extension settings (type: "postgres_cdc_rls"):
    {
      "db_host"           => "127.0.0.1",
      "db_port"           => "${GATEWAY_PG_PORT}",
      "db_name"           => "${PGDATABASE}",
      "db_user"           => "${PGUSER}",
      "db_password"       => "${PGPASSWORD}",
      "db_user_realtime"  => "${PGUSER}",
      "db_pass_realtime"  => "${PGPASSWORD}",
      "region"            => "us-east-1",
      "ssl_enforced"      => false
    }

  Smoke-test it (real Realtime code, end to end through the tunnel):
    cd ~/dev/realtime && mix run "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/realtime/broadcast_smoke.exs"

  Open psql against the gateway:
    $0 psql

  Tear down:
    $0 down        # stop & remove (keeps nothing — cluster is ephemeral)
INFO
}

cmd_psql() {
  preflight
  resolve_pguser
  # Interactive psql (no -T) so it attaches a TTY.
  compose exec -e PGPASSWORD="$PGPASSWORD" multigres \
    psql -h 127.0.0.1 -p "$GATEWAY_PG_PORT" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

cmd_logs() {
  preflight
  compose logs -f "$@"
}

cmd_down() {
  preflight
  local args=(down)
  for a in "$@"; do
    case "$a" in
      -v|--volumes) args+=(--volumes) ;;
      *) die "unknown flag for down: $a" ;;
    esac
  done
  log "Stopping & removing the Multigres cluster"
  compose "${args[@]}"
}

usage() {
  cat <<USAGE
Usage: $0 <command>

  up              Build & start the cluster, prep roles, print connection info
  prep            (Re)create the Supabase roles on an already-running cluster
  info            Print connection details and how to test
  psql [args...]  Open psql against the gateway
  logs [args...]  Follow cluster logs
  down [-v]       Stop & remove the cluster (-v also removes volumes)

Environment:
  MULTIGRES_DIR                    multigres checkout to build from
                                   (default: worktree tracking upstream/main)
  GATEWAY_PG_PORT                  published gateway PG port (default: 15432)
  MULTIGRES_PG_MAX_CONNECTIONS     PG max_connections (default: 100)
  MULTIGRES_POSTGRES_IMAGE         base image for the cluster (default:
                                   supabase/postgres:17.6.1.150-multigres;
                                   set "" for stock postgres:17.7)
  MULTIGRES_PROVISION_PG_PACKAGES  set 'false' with a non-Debian base image
                                   that already bundles pgbackrest/pgvector
                                   (default: false, matching the Supabase
                                   base image default above)
  PGUSER                           override the auto-detected superuser
                                   (default: auto-detected from the running
                                   container's POSTGRES_USER)
  WAIT_TIMEOUT                     seconds to wait for health on 'up' (default: 240)
USAGE
}

main() {
  local cmd="${1:-}"
  [ -n "$cmd" ] && shift || true
  case "$cmd" in
    up)    cmd_up "$@" ;;
    prep)  cmd_prep "$@" ;;
    info)  cmd_info "$@" ;;
    psql)  cmd_psql "$@" ;;
    logs)  cmd_logs "$@" ;;
    down)  cmd_down "$@" ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
