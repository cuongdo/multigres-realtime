# Realtime Playground Against Multigres Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** One command (`./multigres-playground.sh up`) brings up a Multigres
cluster, a persistent Realtime server pointed at it, and the Realtime
Playground's interactive UI wired to connect — for manual, hands-on
exploration of Broadcast/Presence/Postgres Changes against Multigres.

**Architecture:** Reuse the existing `multigres-realtime.sh` for the cluster.
Add `realtime/playground_setup.exs` (an idempotent tenant-upsert + JWT-mint
script, run via `mix run`, in the style of the existing `broadcast_smoke.exs`).
Add a one-line patch to `supabase-community/realtime-playground` (applied to
a local worktree) so its hardcoded `${supabaseUrl}/realtime/v1` endpoint
prefers a `PUBLIC_REALTIME_URL` override, avoiding the need for a reverse
proxy. Add `multigres-playground.sh` to orchestrate all of it: start/stop
`mix phx.server` and `pnpm web` as background processes tracked via pidfiles
in `.run/`.

**Tech Stack:** bash, Elixir (`mix run` script using `Realtime.Api` +
`Joken`), a small patch to a Next.js/TypeScript app (`supabase-community/realtime-playground`), pnpm.

**Design doc:** `docs/plans/2026-07-27-realtime-playground-against-multigres-design.md`
— read this first for the *why* behind each decision below; this plan covers
the *how*.

---

## Before you start

This repo has no automated test suite (it's bash + one-off Elixir scripts,
same as the existing `multigres-realtime.sh` / `broadcast_smoke.exs`), so
there's no `pytest`/`mix test` to run as a baseline or after each step.
"Testing" each task below means: run the command, read the output, confirm
it matches what's expected. That's intentional and matches how the rest of
this repo already validates itself.

Work happens in the git worktree already created for this:
`/Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres`
(branch `realtime-playground-multigres`). All paths below are relative to
that worktree unless stated otherwise.

Prerequisites assumed already true (per the existing README, not this plan's
job to automate): Docker running, and Realtime's metadata DB has been set up
at least once (`cd ~/dev/realtime && mix ecto.setup`).

---

### Task 1: Patch the Playground to honor `PUBLIC_REALTIME_URL`

**Files:**
- Create (outside this repo, then copy the diff in): a worktree of
  `~/dev/realtime-playground` at
  `~/dev/realtime-playground/.worktrees/multigres-realtime-url`
- Create: `realtime-playground/0001-use-public-realtime-url.patch`

**Step 1: Clone the Playground repo and create its worktree**

```bash
git clone https://github.com/supabase-community/realtime-playground.git ~/dev/realtime-playground
cd ~/dev/realtime-playground
git worktree add .worktrees/multigres-realtime-url -b multigres-realtime-url
cd .worktrees/multigres-realtime-url
```

**Step 2: Edit the hardcoded endpoint**

Open `apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx`.

Add `PUBLIC_REALTIME_URL` to the imports (it's already exported by
`@/lib/constants`, just not imported here yet):

```typescript
import { PUBLIC_REALTIME_URL } from '@/lib/constants'
```

Change the `onSubmit` function from:

```typescript
  const onSubmit = (options: RealtimeClientFormValues) => {
    useRealtimeStore.getState().create(`${supabaseUrl}/realtime/v1`, {
      ...realtimeOptions(options, supabaseKey),
      logger,
    })
  }
```

to:

```typescript
  const onSubmit = (options: RealtimeClientFormValues) => {
    const endpoint = PUBLIC_REALTIME_URL || `${supabaseUrl}/realtime/v1`
    useRealtimeStore.getState().create(endpoint, {
      ...realtimeOptions(options, supabaseKey),
      logger,
    })
  }
```

**Step 3: Verify the change**

Run: `grep -n "PUBLIC_REALTIME_URL" apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx`

Expected: two matches — the new import line, and the new `endpoint` line.

**Step 4: Commit it in the Playground worktree**

```bash
git add apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx
git commit -m "Prefer PUBLIC_REALTIME_URL for the interactive client when set"
```

**Step 5: Generate the patch file**

```bash
git diff main -- apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx \
  > /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime-playground/0001-use-public-realtime-url.patch
```

(Create the `realtime-playground/` directory first if `git diff` complains —
`mkdir -p /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime-playground`.)

**Step 6: Verify the patch applies cleanly to an unpatched checkout**

```bash
cd ~/dev/realtime-playground
git apply --check /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime-playground/0001-use-public-realtime-url.patch
```

Expected: no output, exit code 0 (run `echo $?` to confirm — this is `git
apply`'s way of saying "would apply cleanly"). The main worktree of
`realtime-playground` is still unpatched, so this proves the patch is
self-contained and doesn't depend on any other uncommitted state.

**Step 7: Commit in integration-scripts**

```bash
cd /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres
git add realtime-playground/0001-use-public-realtime-url.patch
git commit -m "Add patch: prefer PUBLIC_REALTIME_URL in the Playground's client form"
```

---

### Task 2: Write and verify `playground_setup.exs`

**Files:**
- Create: `realtime/playground_setup.exs`

**Step 1: Write the script**

```elixir
# playground_setup.exs
#
# Registers (or updates) a persistent Realtime tenant pointed at the
# Multigres gateway, runs its migrations, and prints a freshly-minted anon
# JWT signed with the tenant's jwt_secret — for the Realtime Playground's
# PUBLIC_SUPABASE_KEY.
#
# Unlike broadcast_smoke.exs, this tenant is meant to persist across runs (a
# long-lived `mix phx.server` needs it to still be there), so this script
# upserts instead of delete+recreate, and never tears anything down. Safe to
# re-run any number of times.
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/playground_setup.exs
#
# Prints ONLY the minted JWT on the last line of stdout — callers should
# capture it with `| tail -1`. All other output goes to stderr.
#
# Override via env: GATEWAY_HOST, GATEWAY_PORT, GATEWAY_USER, GATEWAY_PASSWORD,
# GATEWAY_DB, PLAYGROUND_TENANT_ID, PLAYGROUND_JWT_SECRET.

alias Realtime.Api
alias Realtime.Tenants.Migrations

defmodule PlaygroundSetup do
  def log(msg), do: IO.puts(:stderr, IO.ANSI.cyan() <> "==> " <> msg <> IO.ANSI.reset())

  def die(msg) do
    IO.puts(:stderr, IO.ANSI.red() <> "FAIL: " <> msg <> IO.ANSI.reset())
    System.halt(1)
  end
end

host = System.get_env("GATEWAY_HOST", "127.0.0.1")
port = System.get_env("GATEWAY_PORT", "15432")
user = System.get_env("GATEWAY_USER", "postgres")
pass = System.get_env("GATEWAY_PASSWORD", "postgres")
db = System.get_env("GATEWAY_DB", "postgres")
external_id = System.get_env("PLAYGROUND_TENANT_ID", "localhost")
secret = System.get_env("PLAYGROUND_JWT_SECRET", "multigres-playground-secret")

PlaygroundSetup.log("Target gateway: #{user}@#{host}:#{port}/#{db}  (tenant: #{external_id})")

tenant_attrs = %{
  "external_id" => external_id,
  "name" => "multigres-playground",
  "postgres_cdc_default" => "postgres_cdc_rls",
  "jwt_secret" => secret,
  "extensions" => [
    %{
      "type" => "postgres_cdc_rls",
      "settings" => %{
        "db_host" => host,
        "db_port" => port,
        "db_name" => db,
        "db_user" => user,
        "db_password" => pass,
        "db_user_realtime" => user,
        "db_pass_realtime" => pass,
        "poll_interval_ms" => 100,
        "poll_max_changes" => 100,
        "poll_max_record_bytes" => 1_048_576,
        "region" => "us-east-1",
        "ssl_enforced" => false
      }
    }
  ]
}

tenant =
  case Api.get_tenant_by_external_id(external_id) do
    nil ->
      PlaygroundSetup.log("Registering new tenant '#{external_id}'")

      case Api.create_tenant(tenant_attrs) do
        {:ok, tenant} -> tenant
        {:error, reason} -> PlaygroundSetup.die("could not create tenant: #{inspect(reason)}")
      end

    _existing ->
      PlaygroundSetup.log("Updating existing tenant '#{external_id}'")

      case Api.update_tenant_by_external_id(external_id, tenant_attrs) do
        {:ok, tenant} -> tenant
        {:error, reason} -> PlaygroundSetup.die("could not update tenant: #{inspect(reason)}")
      end
  end

# Reload so the extensions association is populated for the migration helpers.
tenant = Api.get_tenant_by_external_id(external_id) || tenant

PlaygroundSetup.log("Running tenant migrations through the gateway")

case Migrations.run_migrations(tenant) do
  res when res in [:ok, :noop] ->
    PlaygroundSetup.log("migrations applied (#{res})")

  {:error, reason} ->
    PlaygroundSetup.die("""
    tenant migrations failed through the gateway: #{inspect(reason)}
    Check the gateway logs: multigres-realtime.sh logs
    """)
end

signer = Joken.Signer.create("HS256", secret)
{:ok, claims} = Joken.generate_claims(%{}, %{role: "anon", exp: System.system_time(:second) + 3600})
{:ok, jwt, _} = Joken.encode_and_sign(claims, signer)

PlaygroundSetup.log("Minted anon JWT (role=anon, exp=1h)")
IO.puts(jwt)
```

**Step 2: Bring up prerequisites**

```bash
cd /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres
./multigres-realtime.sh up
cd ~/dev/realtime && mise run db-start
```

Expected: both commands finish without error (both are idempotent — safe if
already up from earlier work).

**Step 3: Run the script and verify output**

```bash
cd ~/dev/realtime
mix run /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime/playground_setup.exs
```

Expected: stderr lines starting with `==>` ending in "Minted anon JWT
(role=anon, exp=1h)", then stdout has exactly one line — a JWT (three
`.`-separated base64url segments, starting with `eyJ`). The first run should
log "Registering new tenant 'localhost'".

**Step 4: Verify idempotency (run it again)**

```bash
mix run /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime/playground_setup.exs
```

Expected: same shape of output, but this time logs "Updating existing tenant
'localhost'" instead of "Registering new tenant" — and still ends with a
(different, since `exp` moved forward) JWT on the last stdout line, no
errors.

**Step 5: Commit**

```bash
cd /Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres
git add realtime/playground_setup.exs
git commit -m "Add playground_setup.exs: idempotent tenant + anon JWT for the Playground"
```

---

### Task 3: `multigres-playground.sh` skeleton

**Files:**
- Create: `multigres-playground.sh` (executable)

**Step 1: Write the skeleton**

```bash
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
```

**Step 2: Make it executable and verify the skeleton runs**

```bash
chmod +x multigres-playground.sh
./multigres-playground.sh
./multigres-playground.sh bogus
./multigres-playground.sh up
```

Expected: first call prints usage (no error, `up`/`info`/`logs`/`down`
listed). Second call prints usage then `error: unknown command: bogus` and
exits 1. Third call exits 1 with `error: cmd_up not yet implemented`.

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "Add multigres-playground.sh skeleton (commands stubbed)"
```

---

### Task 4: Implement `cmd_up` part 1 — Realtime server

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Replace the `cmd_up` stub**

```bash
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
}
```

**Step 2: Run it and verify**

```bash
./multigres-playground.sh up
```

Expected: cluster comes up (or is already up), `mise run db-start` reports
the dev DBs are up, Realtime starts, and you see "Realtime is up". If it
instead dies with the ecto.setup hint, run `cd ~/dev/realtime && mix
ecto.setup` once and re-run.

Sanity-check the server is actually listening:

```bash
curl -sf http://localhost:4000/status && echo OK
```

Expected: `OK` printed (the endpoint itself doesn't need to return anything
meaningful — `-f` just checks for a non-error HTTP status).

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "cmd_up: start Realtime as a persistent background server"
```

---

### Task 5: Implement `cmd_up` part 2 — tenant + JWT

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Append to `cmd_up`, right after "Realtime is up" log line**

```bash
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
```

**Why not `2>&1 | tee ... | tail -1`:** merging stderr into the same stream
as stdout before `tail -1` means that on failure, the last "line" captured
would be `playground_setup.exs`'s own red `FAIL: ...` message (written to
what was originally stderr) — which is non-empty, so a naive `[ -n "$jwt" ]`
check would pass and silently write that error text into
`PUBLIC_SUPABASE_KEY` in `.env` instead of catching the failure. Redirecting
stderr straight to the log file (`2>"$RUN_DIR/playground_setup.log"`, no
`tee`) keeps it out of the captured stdout entirely, and `if ! jwt=$(...); then`
relies on this script's `set -o pipefail` (already set at the top of the
file) to catch a nonzero exit from `mix run` even though `tail` — the
rightmost command in the pipe — exits 0. This mirrors the existing
`if ! compose up ...; then ... die ...` pattern already used in
`multigres-realtime.sh`'s `cmd_up`.

**Why `GEN_RPC_TCP_SERVER_PORT=0 GEN_RPC_TCP_CLIENT_PORT=0`:** `mix run`
boots the entire `:realtime` OTP application (same as `mix phx.server`
does), including `gen_rpc`, which binds a fixed TCP port
(`config/runtime.exs`, default 5369 via those same env vars) — the exact
port Task 4's long-running `mix phx.server` already owns by this point in
`cmd_up`. Without this override, `mix run "$SETUP_SCRIPT"` fails to boot at
all (`:eaddrinuse` on `gen_rpc_server_tcp`) whenever Realtime is already
running, which is always true here since this step runs right after
"Realtime is up". Setting both to `0` tells `gen_rpc` to bind ephemeral,
OS-assigned ports instead of the fixed default, avoiding the collision;
`playground_setup.exs` never actually needs `gen_rpc` (it's a one-shot local
script with no clustering), so which port it lands on doesn't matter. This
only affects the short-lived `mix run` invocation — Task 4's `phx.server`
keeps using the real fixed port for its own inter-node RPC needs.

Also update the top-of-function comment area: no changes needed elsewhere.

**Step 2: Run it and verify**

```bash
./multigres-playground.sh up
```

Expected: continues past "Realtime is up" to "Minted anon JWT for tenant
'localhost'", no errors. Check `cat .run/playground_setup.log` — should show
just the `==>` stderr log lines from Task 2 (registering/updating the tenant,
running migrations, minting the JWT); the JWT itself is *not* in this file
(it went to stdout, captured directly into the `jwt` shell variable instead).

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "cmd_up: register tenant and capture a fresh anon JWT"
```

---

### Task 6: Implement `cmd_up` part 3 — the Playground app

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Add an `ensure_playground_worktree` helper**, above `cmd_up`:

```bash
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
```

**Step 2: Append to `cmd_up`, right after "Minted anon JWT..." log line**

```bash
  ensure_playground_worktree

  log "Writing $PLAYGROUND_WORKTREE_DIR/.env"
  cat > "$PLAYGROUND_WORKTREE_DIR/.env" <<ENV
PUBLIC_REALTIME_URL=ws://localhost:${REALTIME_PORT}/socket
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
```

**Step 3: Run it and verify**

```bash
./multigres-playground.sh up
```

Expected: full run through to a printed `cmd_info` block (which will error
"cmd_info not yet implemented" at this point — that's expected, fix it in
Task 7). Everything *before* that line should succeed: clone, worktree,
patch applied, `.env` written, `pnpm install` (only on first run — can take
a minute or two), Playground started, port 3000 responding.

Confirm the `.env` looks right:

```bash
cat ~/dev/realtime-playground/.worktrees/multigres-realtime-url/.env
```

Expected: all four vars set, `PUBLIC_SUPABASE_KEY` a JWT string,
`ENABLE_PLAYGROUND=true`.

**Step 4: Commit**

```bash
git add multigres-playground.sh
git commit -m "cmd_up: clone/patch the Playground, write .env, start pnpm web"
```

---

### Task 7: Implement `cmd_down`, `cmd_logs`, `cmd_info`

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Replace the three remaining stubs**

```bash
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
  Realtime     http://localhost:${REALTIME_PORT}  (tenant: ${PLAYGROUND_TENANT_ID})
  Gateway      ${GATEWAY_USER}@${GATEWAY_HOST}:${GATEWAY_PORT}/${GATEWAY_DB}

  A fresh anon JWT is minted on every 'up' and written into
  ${PLAYGROUND_WORKTREE_DIR}/.env — no manual copying needed.

  Logs:
    $0 logs             # both
    $0 logs realtime
    $0 logs playground

  Tear down:
    $0 down                 # stop Realtime + Playground, leave the cluster up
    $0 down --with-cluster  # also stop the Multigres cluster
INFO
}
```

**Step 2: Full run-through**

```bash
./multigres-playground.sh down       # clean slate
./multigres-playground.sh up
```

Expected: completes end-to-end, ending in the `cmd_info` block above with
real port numbers and the tenant id filled in.

```bash
./multigres-playground.sh info       # same block, without restarting anything
```

```bash
./multigres-playground.sh down
ps -p "$(cat .run/realtime.pid 2>/dev/null)" 2>/dev/null && echo "still running (BAD)" || echo "stopped (good)"
```

Expected: "stopped (good)" — and the Multigres cluster is still up (check
with `docker ps` — the multigres containers should still be listed, since
plain `down` doesn't pass `--with-cluster`).

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "Implement cmd_down, cmd_logs, cmd_info"
```

---

### Task 8: End-to-end browser verification

**Step 1: Bring it up**

```bash
./multigres-playground.sh up
```

**Step 2: Drive the Playground in a real browser**

Use the `claude-in-chrome` skill/tool to:
1. Open `http://localhost:3000/playground`.
2. Confirm the "No Supabase project configured" gate is *not* shown (since
   `.env` already has a valid key) — the Client Creation card should be
   visible instead.
3. Click "Create Client", then create a channel (any name, e.g. `smoke`).
4. Send a Broadcast message on that channel from the UI.
5. Confirm the message appears in the Broadcast Messages table on the right
   within a couple seconds — this is the same Broadcast-from-Database path
   `broadcast_smoke.exs` already validates, just observed interactively.

If it doesn't show up within ~15s, check `./multigres-playground.sh logs
realtime` for errors (same failure modes as `broadcast_smoke.exs`'s PARTIAL
outcome — migrations/replication succeeded but the dispatcher path has an
issue).

**Step 3: Tear down and confirm cleanup**

```bash
./multigres-playground.sh down --with-cluster
docker ps --filter "name=multigres" # expect empty
```

**Step 4: Final commit (if any doc/script tweaks came out of this pass)**

```bash
git add -A
git commit -m "Fix issues found during end-to-end Playground verification"
```

(Skip this commit if nothing needed changing.)

---

## After this plan

Use `superpowers:finishing-a-development-branch` to decide how to land the
`realtime-playground-multigres` branch (merge, PR-equivalent for a personal
repo, or just keep working on `main` directly — this repo has no remote yet).
