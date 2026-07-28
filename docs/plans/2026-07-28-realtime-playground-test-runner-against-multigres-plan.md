# Realtime Playground Test Runner Against Multigres Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend `multigres-playground.sh` so `./multigres-playground.sh up` brings up
GoTrue, PostgREST, and Kong (in addition to the existing gateway + Realtime + Playground),
so that both `http://localhost:3000/playground` (unchanged) and
`http://localhost:3000/test` (new — the Playground's Test Runner tab, all 12 suites)
work end-to-end against the Multigres gateway.

**Architecture:** Three new Docker containers (GoTrue, PostgREST, Kong) on a dedicated
bridge network, all reaching the gateway and Realtime via `host.docker.internal`. Kong is
the single origin `supabase-js` expects (`/auth/v1`, `/rest/v1`, `/realtime/v1`), replacing
the need for the old design's Playground URL patch. Fixture tables/RLS/triggers are
created by shelling out **in place** to `~/dev/realtime/test/e2e/realtime-check.ts`
(already-maintained, generic — nothing to copy). A persistent test user is minted via
GoTrue's admin API (new, Multigres-specific glue).

**Tech Stack:** bash, Docker, a Kong declarative config template, Elixir (`mix run`
extensions to the existing `playground_setup.exs`), `bun` (for `realtime-check.ts`).

**Design doc:** `docs/plans/2026-07-28-realtime-playground-test-runner-against-multigres-design.md`
— read this first for the *why*; this plan covers the *how*. It supersedes
`docs/plans/2026-07-27-realtime-playground-against-multigres-design.md`.

---

## Refinements found during planning (not yet in the design doc)

These came up while turning the design into concrete steps — worth knowing before you
start:

1. **Patch #2 stays.** The design doc's "no Playground repo changes" is about the
   *worktree + URL patch* specifically. `realtime-playground/0002-fix-broadcast-send-schema-nonoptional.patch`
   (already in this worktree) fixes a real Playground crash (`z.string()...default('message').nonoptional()`
   is a contradictory zod chain) that's unrelated to Kong/routing and still needed. It's
   generic — worth a follow-up upstream PR — but out of scope for this plan; for now we
   keep applying it locally, directly to a plain clone (no worktree needed anymore, since
   there's only one small patch left and no branch-worthy divergence).
2. **New gateway roles needed**, beyond what `multigres-realtime.sh` already creates:
   `authenticator` (the role PostgREST connects as, then `SET ROLE` per request) and
   `supabase_auth_admin` (the role GoTrue connects as to run its own `auth.*` migrations).
   These are specific to the GoTrue/PostgREST addition, not the base Realtime-compat
   surface `multigres-realtime.sh` serves — so they're created by `multigres-playground.sh`
   itself, not added to `multigres-realtime.sh`.
3. **Docker networking:** GoTrue/PostgREST/Kong run in their own dedicated bridge network
   (`multigres-playground-net`), reaching the gateway (`localhost:15432`) and Realtime
   (`localhost:4000`) via `host.docker.internal` (native on Docker Desktop for Mac; the
   `--add-host` flag below also makes it work on Linux Docker). Only Kong publishes a
   host port (8000) — GoTrue and PostgREST are only reachable through Kong, matching how
   the real self-hosted stack does it.
4. **Version pins**, taken directly from supabase/supabase's own self-hosted
   `docker/docker-compose.yml` (checked out at `~/dev/supabase`): `kong:3.9.1`,
   `supabase/gotrue:v2.186.0`, `postgrest/postgrest:v14.8`.

---

## Before you start

This repo has no automated test suite — "testing" each task means: run the command,
read the output, confirm it matches what's expected (same convention as the rest of this
repo).

Work happens in `/Users/cdo/dev/integration-scripts/.worktrees/realtime-playground-multigres`
(branch `realtime-playground-multigres`, already created and containing the prior design's
implementation). All paths below are relative to that worktree unless stated otherwise.

Prerequisites assumed true (same as existing README, plus new ones):
- Docker running, Multigres worktree available, Realtime metadata DB set up
  (`cd ~/dev/realtime && mix ecto.setup`) — all pre-existing.
- **New:** `bun` installed (`curl -fsSL https://bun.sh/install | bash`, or `brew install oven-sh/bun/bun`)
  — needed to run `~/dev/realtime/test/e2e/realtime-check.ts` in place.

---

### Task 1: Add `authenticator` and `supabase_auth_admin` roles to the gateway

**Files:**
- Modify: `multigres-playground.sh`

Add a new function that runs once during `cmd_up`, before the GoTrue/PostgREST
containers start. It connects to the gateway the same way `playground_setup.exs` does
(same `GATEWAY_*` env vars), using `psql` directly (the gateway already publishes
`localhost:15432`; no new dependency — `psql` is already required by
`multigres-realtime.sh`'s own `gw_psql` helper, but that helper lives in the other
script, so add a small local equivalent here).

**Step 1: Add the function**

```bash
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
SQL
}
```

Add the call `prepare_gateway_roles` near the top of `cmd_up`, right after
`"$SCRIPT_DIR/multigres-realtime.sh" up`.

**Step 2: Verify manually**

Run:
```bash
./multigres-realtime.sh up   # if not already up
PGPASSWORD=postgres psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -c "\du authenticator" -c "\du supabase_auth_admin"
```
Expected: both roles listed (run `prepare_gateway_roles` manually first, e.g. by
temporarily calling it from a scratch shell, since Task 4 wires it into `cmd_up` for real).

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "Add authenticator and supabase_auth_admin roles for GoTrue/PostgREST"
```

---

### Task 2: Mint a service_role JWT alongside the anon JWT

**Files:**
- Modify: `realtime/playground_setup.exs`

Currently the script prints exactly one line (the anon JWT) on stdout. GoTrue's admin
API, PostgREST, and Kong's service-key consumer all need a `service_role` JWT too. Change
the output contract to two labeled lines instead of one bare line, so callers can parse
either without ambiguity.

**Step 1: Replace the JWT-minting section**

Replace (around line 105-110):
```elixir
signer = Joken.Signer.create("HS256", secret)
{:ok, claims} = Joken.generate_claims(%{}, %{role: "anon", exp: System.system_time(:second) + 3600})
{:ok, jwt, _} = Joken.encode_and_sign(claims, signer)

PlaygroundSetup.log("Minted anon JWT (role=anon, exp=1h)")
IO.puts(jwt)
```

with:
```elixir
signer = Joken.Signer.create("HS256", secret)
exp = System.system_time(:second) + 3600

mint = fn role ->
  {:ok, claims} = Joken.generate_claims(%{}, %{role: role, exp: exp})
  {:ok, jwt, _} = Joken.encode_and_sign(claims, signer)
  jwt
end

anon_jwt = mint.("anon")
service_jwt = mint.("service_role")

PlaygroundSetup.log("Minted anon + service_role JWTs (exp=1h)")
IO.puts("ANON_JWT=#{anon_jwt}")
IO.puts("SERVICE_JWT=#{service_jwt}")
```

Also update the module doc comment (lines 16-17) to reflect the new two-line contract:
```elixir
# Prints two labeled lines on the last two lines of stdout — ANON_JWT=... and
# SERVICE_JWT=.... Callers should capture with `| tail -2` and parse by prefix.
# All other output goes to stderr.
```

**Step 2: Verify manually**

Run:
```bash
cd ~/dev/realtime && GATEWAY_HOST=127.0.0.1 GATEWAY_PORT=15432 GATEWAY_USER=postgres \
  GATEWAY_PASSWORD=postgres GATEWAY_DB=postgres GEN_RPC_TCP_SERVER_PORT=0 GEN_RPC_TCP_CLIENT_PORT=0 \
  mix run ~/dev/integration-scripts/.worktrees/realtime-playground-multigres/realtime/playground_setup.exs
```
Expected: stderr shows the log lines, stdout's last two lines are `ANON_JWT=...` and
`SERVICE_JWT=...` (both valid-looking JWTs, three dot-separated base64 segments each).

**Step 3: Commit**

```bash
git add realtime/playground_setup.exs
git commit -m "Mint a service_role JWT alongside the anon JWT"
```

---

### Task 3: Write the Kong declarative config template

**Files:**
- Create: `kong/kong.yml`

Adapted from the real self-hosted routing pattern (`/rest/v1/`, `/auth/v1/`, `/realtime/v1/`,
each `strip_path: true`, `key-auth` plugin checking the `apikey` header against a
consumer). `${ANON_JWT}` / `${SERVICE_JWT}` are placeholders — Task 6 renders this file
with `envsubst` before mounting it into the Kong container, since our JWTs are freshly
minted on every `up` (same pattern the old design already uses for `.env`).

```yaml
_format_version: "1.1"

services:
  - name: auth-v1
    url: http://gotrue:9999/
    routes:
      - name: auth-v1-all
        strip_path: true
        paths:
          - /auth/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: true

  - name: rest-v1
    url: http://postgrest:3000/
    routes:
      - name: rest-v1-all
        strip_path: true
        paths:
          - /rest/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: true

  - name: realtime-v1
    url: http://host.docker.internal:4000/socket/
    routes:
      - name: realtime-v1-all
        strip_path: true
        paths:
          - /realtime/v1/
    plugins:
      - name: cors
      - name: key-auth
        config:
          hide_credentials: true

consumers:
  - username: anon-key
    keyauth_credentials:
      - key: ${ANON_JWT}
  - username: service-key
    keyauth_credentials:
      - key: ${SERVICE_JWT}
```

Note `gotrue`/`postgrest` are addressed by container name (same Docker network, Task 6),
while `realtime-v1` reaches the host process via `host.docker.internal`.

**Step 2: Commit**

```bash
mkdir -p kong
git add kong/kong.yml
git commit -m "Add Kong declarative config template for GoTrue/PostgREST/Realtime routing"
```

(No standalone verification step — this file is inert until Task 6 renders and mounts it.)

---

### Task 4: Simplify the Playground clone (drop the worktree + URL patch)

**Files:**
- Modify: `multigres-playground.sh`

Replace `ensure_playground_worktree` (which clones, creates a worktree/branch, and
applies both patches) with a simpler `ensure_playground_clone` that clones `main` directly
and applies only patch #2 (the crash fix) to the working tree — idempotent, same
guard-then-apply style as before.

**Step 1: Replace the function**

Replace the whole `ensure_playground_worktree` function (and remove
`PLAYGROUND_WORKTREE_BRANCH`/`PLAYGROUND_WORKTREE_DIR`/`PATCH_FILE` from the config
section — keep `PATCH_FILE_2`, renamed `PATCH_FILE`) with:

```bash
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
```

Update the config section: remove the `PLAYGROUND_WORKTREE_*` lines, rename
`PATCH_FILE` (was pointing at patch #1) so only patch #2 remains:

```bash
PATCH_FILE="${SCRIPT_DIR}/realtime-playground/0002-fix-broadcast-send-schema-nonoptional.patch"
```

Delete `PATCH_FILE_2` (no longer needed as a separate variable) and delete
`realtime-playground/0001-use-public-realtime-url.patch` from the repo (it's dead code —
Kong replaces what it did).

**Step 2: Update the one caller**

In `cmd_up`, replace the call `ensure_playground_worktree` with `ensure_playground_clone`,
and replace every remaining reference to `$PLAYGROUND_WORKTREE_DIR` in `cmd_up` with
`$PLAYGROUND_DIR` (the `.env` write, the `pnpm install` check, the `pnpm web` start — all
three currently reference the worktree path; Task 7 rewrites the `.env` contents anyway,
but the path itself changes here).

**Step 3: Verify manually**

Run:
```bash
rm -rf ~/dev/realtime-playground   # start from scratch to exercise the clone path
git -C /path/to/this/worktree diff --stat   # sanity check the diff looks like the above
```
(Full end-to-end verification happens in Task 8 once `cmd_up` is wired together again —
this task alone isn't independently runnable since `cmd_up` still references things Task
5-7 haven't added yet. That's fine; commit now, keep going.)

**Step 4: Commit**

```bash
git add multigres-playground.sh
git rm realtime-playground/0001-use-public-realtime-url.patch
git commit -m "Drop Playground worktree + URL patch; Kong makes it unnecessary"
```

---

### Task 5: Start GoTrue, PostgREST, and Kong

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Add config variables**

Add near the existing `GATEWAY_*` block:

```bash
KONG_PORT="${KONG_PORT:-8000}"
PLAYGROUND_NETWORK="multigres-playground-net"
GOTRUE_IMAGE="${GOTRUE_IMAGE:-supabase/gotrue:v2.186.0}"
POSTGREST_IMAGE="${POSTGREST_IMAGE:-postgrest/postgrest:v14.8}"
KONG_IMAGE="${KONG_IMAGE:-kong:3.9.1}"
```

**Step 2: Add a container-health-wait helper**

Alongside the existing `wait_for_http`:

```bash
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
```

**Step 3: Add the start function**

```bash
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
    --network "$PLAYGROUND_NETWORK" \
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
    --network "$PLAYGROUND_NETWORK" \
    --add-host host.docker.internal:host-gateway \
    -e PGRST_DB_URI="postgres://authenticator:${GATEWAY_PASSWORD}@host.docker.internal:${GATEWAY_PORT}/${GATEWAY_DB}" \
    -e PGRST_DB_SCHEMAS=public \
    -e PGRST_DB_ANON_ROLE=anon \
    -e PGRST_JWT_SECRET="$PLAYGROUND_JWT_SECRET" \
    "$POSTGREST_IMAGE" >/dev/null

  wait_for_healthy playground-gotrue
  log "GoTrue is up"
}
```

(PostgREST has no built-in healthcheck endpoint as reliable as GoTrue's `/health`; its
readiness is verified indirectly in Task 7 when Kong's `/rest/v1/` route is smoke-tested.)

**Step 4: Add the Kong start, called after JWTs exist**

Kong needs the rendered config (which embeds the anon/service JWTs), so it starts later
in `cmd_up`, after Task 2's JWTs are minted. Add:

```bash
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
```

**Step 5: Verify manually**

These two functions aren't callable standalone yet (Kong needs JWTs from Task 2's flow) —
full verification happens in Task 8. For now, sanity-check syntax:

```bash
bash -n multigres-playground.sh
```
Expected: no output (no syntax errors).

**Step 6: Commit**

```bash
git add multigres-playground.sh
git commit -m "Add GoTrue/PostgREST/Kong container orchestration"
```

---

### Task 6: Fixture setup via realtime-check.ts, in place

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Add the function**

```bash
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
```

Note this deliberately doesn't `die` on failure the way other steps do: the one
`authorization` test it runs end-to-end is itself a compatibility probe that could
legitimately fail against Multigres without the fixture setup having failed. Surface the
warning and let the operator check the log.

**Step 2: Add persistent test user creation**

```bash
# Create a persistent test user via GoTrue's admin API — separate from
# realtime-check.ts's own ephemeral user (which it deletes after its run) —
# so the Playground's .env can reference a stable email/password for a real
# browser session.
PLAYGROUND_TEST_USER_EMAIL="${PLAYGROUND_TEST_USER_EMAIL:-playground@localhost}"
PLAYGROUND_TEST_USER_PASSWORD="${PLAYGROUND_TEST_USER_PASSWORD:-multigres-playground-password}"

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
```

(Add the two `PLAYGROUND_TEST_USER_*` variable defaults next to the other config
variables at the top of the file, not inline in the function, matching the file's
existing style — shown inline above for readability.)

**Step 3: Verify manually**

Not standalone-runnable yet (needs Kong + JWTs up) — verified together in Task 8.

**Step 4: Commit**

```bash
git add multigres-playground.sh
git commit -m "Add fixture setup (in-place realtime-check.ts) and persistent test user creation"
```

---

### Task 7: Wire it all together in `cmd_up`, update `.env`

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Rewrite `cmd_up`**

Replace the existing `cmd_up` body with (building on the existing structure — cluster,
Realtime, tenant setup — and inserting the new steps):

```bash
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
```

**Step 2: Verify manually — full end-to-end run**

```bash
./multigres-playground.sh down --with-cluster 2>/dev/null || true
./multigres-playground.sh up
```
Expected: completes without `die`, prints the final `cmd_info` block. Then:

```bash
curl -s http://localhost:8000/rest/v1/ | head -c 200; echo
curl -s -X POST http://localhost:8000/auth/v1/token?grant_type=password \
  -H "apikey: $(grep PUBLIC_SUPABASE_KEY ~/dev/realtime-playground/.env | cut -d= -f2)" \
  -H "Content-Type: application/json" \
  -d '{"email":"playground@localhost","password":"multigres-playground-password"}'
```
Expected: first command returns PostgREST's OpenAPI root (some JSON), second returns a
session object with an `access_token`.

Then open `http://localhost:3000/test` in a browser, click **Run**: expect all 12 suites
green.

**Step 3: Commit**

```bash
git add multigres-playground.sh
git commit -m "Wire GoTrue/PostgREST/Kong/fixtures/test-user into cmd_up"
```

---

### Task 8: Update `cmd_down`, `cmd_info`, `usage`

**Files:**
- Modify: `multigres-playground.sh`

**Step 1: Update `cmd_down`**

Add container teardown after the existing pidfile kills:

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

  log "Stopping GoTrue/PostgREST/Kong"
  docker rm -f playground-kong playground-postgrest playground-gotrue >/dev/null 2>&1 || true

  if [ "$with_cluster" = true ]; then
    "$SCRIPT_DIR/multigres-realtime.sh" down
  else
    log "Multigres cluster left running (pass --with-cluster to also stop it)"
  fi
}
```

**Step 2: Update `cmd_info`**

Add a line about Kong/Test Runner:

```bash
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
```

**Step 3: Update `usage`**

Add the new env vars to the `Environment:` section: `KONG_PORT`, `PLAYGROUND_TEST_USER_EMAIL`,
`PLAYGROUND_TEST_USER_PASSWORD`.

**Step 4: Verify manually**

```bash
./multigres-playground.sh info
./multigres-playground.sh down
docker ps --format '{{.Names}}' | grep -c playground- # expect 0
./multigres-playground.sh down --with-cluster
```

**Step 5: Commit**

```bash
git add multigres-playground.sh
git commit -m "Update down/info/usage for the new GoTrue/PostgREST/Kong containers"
```

---

### Task 9: Update the README

**Files:**
- Modify: `README.md`

Add a short section after the existing Playground-related content (if any — check
current README state, since the prior design's README updates may or may not have landed
in this worktree yet) documenting: the new `bun` prerequisite, what `./multigres-playground.sh up`
now brings up, and the Test Runner URL. Keep it brief — this repo's README style is
terse and command-focused (see the existing Step 1/Step 2 sections).

**Step 1: Add the section, verify by reading it back for accuracy against the actual
script behavior.**

**Step 2: Commit**

```bash
git add README.md
git commit -m "Document the Test Runner stack in the README"
```
