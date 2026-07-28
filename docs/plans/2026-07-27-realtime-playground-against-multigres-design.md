# Running the Realtime Playground against Multigres

**Date:** 2026-07-27
**Status:** Design — not yet implemented

## Context

Following up on [this Slack thread](https://supabase.slack.com/archives/C09HZMQDAKD/p1783454321517969):
Filipe suggested using `supabase-community/realtime-playground` (deployed at
`realtime-playground-next.vercel.app`) to interactively explore Supabase
Realtime features against a project. This design covers running that
Playground locally, pointed at a Multigres gateway instead of a normal
Postgres, for **manual interactive exploration** (not automated E2E/CI —
that's a possible follow-up, out of scope here).

## Goal

Get `http://localhost:3000/playground` up, connected to a Realtime server
whose tenant database is the Multigres gateway, with zero manual JWT-copying
or `.env` editing — one command (`./multigres-playground.sh up`) to a working
browser tab.

## Non-goals

- **Auth/RLS testing.** The Playground's login flow calls real Supabase Auth
  (`signInWithPassword`), which would require a full local Auth+PostgREST
  stack pointed at Multigres. We're skipping login entirely and using an
  anon-role JWT directly — mirroring how `broadcast_smoke.exs` already talks
  to Realtime with no Auth layer involved. RLS/`auth.uid()`-scoped features in
  the Playground won't work under this design.
- **CI/automated E2E.** Filipe also pointed at `test/e2e` in the Realtime repo
  and the Playground's separate "Test Runner" mode for that; not covered here.
- **Upstreaming the patch.** The one-line fix described below stays local for
  now (see "Playground code patch").

## Architecture

Three components, run locally:

1. **Multigres cluster + gateway** — unchanged, via the existing
   `./multigres-realtime.sh up`.
2. **Realtime**, run as a persistent `mix phx.server` from `~/dev/realtime`
   (its own metadata DB up via `mise run db-start`/`mix ecto.setup`, per the
   existing README's prerequisites), with a tenant registered pointing at the
   Multigres gateway — same registration shape as `broadcast_smoke.exs`, but
   left in place since a long-running server needs it to persist across
   requests.
3. **The Playground app**, cloned to `~/dev/realtime-playground`, with a
   `.worktrees/multigres-realtime-url` worktree/branch carrying a one-line
   patch (see below). Run via `pnpm web` (Next.js dev server, port 3000).

### Why no reverse proxy

The Playground's interactive page hardcodes its WebSocket endpoint as
`` `${supabaseUrl}/realtime/v1` `` in
`apps/next/src/app/playground/_components/forms/RealtimeClientForm.tsx:40`,
ignoring `PUBLIC_REALTIME_URL` even though that env var is wired all the way
through `constants.ts` and `next.config.ts` — it's just never read at the one
call site that builds the socket URL. That `/realtime/v1` prefix only exists
in a real Supabase stack because Kong strips it before forwarding to the
Realtime container; Realtime's own router (`lib/realtime_web/router.ex`) has
no such route — only `/`, `/api`, `/admin`, `/metrics`, `/swaggerui`.

Rather than building a path-rewriting/WebSocket-proxying shim to satisfy that
hardcoded assumption, patch the one line to prefer `PUBLIC_REALTIME_URL` when
set, falling back to the original `${supabaseUrl}/realtime/v1` otherwise.
This is very likely an oversight in the upstream repo (their team presumably
always runs it against a real Kong-fronted project), and the fix is small
enough to carry as a local patch.

### Why `external_id = "localhost"`

Realtime resolves a request's tenant from the first label of the HTTP `Host`
header (`Database.get_external_id/1` in `lib/realtime/database.ex:319`,
`String.split(host, ".", parts: 2)`). Since the Playground, Realtime, and
(browser) are all addressed via `localhost` — just different ports — the
`Host` header's hostname is always `localhost` regardless of port. Setting
the tenant's `external_id` to `"localhost"` means no subdomain tricks or
`/etc/hosts` edits are needed anywhere in this setup.

## Tenant registration & JWT minting

A new script, `realtime/playground_setup.exs` (run the same way as the
existing smoke scripts: `cd ~/dev/realtime && mix run
~/dev/integration-scripts/realtime/playground_setup.exs`), idempotent rather
than create/test/teardown:

1. **Upsert the tenant** — same shape as `broadcast_smoke.exs`'s
   `tenant_attrs` (gateway host/port/user/pass via `GATEWAY_HOST`/
   `GATEWAY_PORT`/etc. env overrides, `postgres_cdc_rls` extension), but
   `external_id = "localhost"` and a fixed `jwt_secret` (default
   `"multigres-playground-secret"`, overridable via `PLAYGROUND_JWT_SECRET`).
   If a tenant with that external_id already exists, update it in place
   rather than delete+recreate.
2. **Run tenant migrations proactively** via `Migrations.run_migrations/1`,
   same call as `broadcast_smoke.exs` — avoids the first browser interaction
   racing a cold-start migration.
3. **Mint an anon JWT**: `Joken.Signer.create("HS256", secret)` +
   `Joken.generate_claims(%{}, %{role: "anon", exp: <short TTL>})` +
   `Joken.encode_and_sign/2` — the same 4-line pattern already used in
   `test/support/generators.ex:generate_jwt_token/2`, inlined here since
   `test/support` isn't loaded under a plain `mix run`. Joken is a normal
   runtime dependency (`mix.exs:81`), so this works outside `:test` env.
4. Print **only the JWT** as the last line of output, so the orchestration
   script can capture it via `mix run ... | tail -1`.

The JWT is minted fresh on every `up` rather than persisted/reused — no
staleness to manage, at the cost of re-running this script on every `up`
(cheap: idempotent upsert + `Joken.encode_and_sign`).

## Playground clone, worktree, and patch

On first `up`, if `~/dev/realtime-playground` doesn't exist, clone
`supabase-community/realtime-playground` there (matching how `~/dev/realtime`
and `~/dev/multigres` are laid out). Then create
`~/dev/realtime-playground/.worktrees/multigres-realtime-url`, a worktree on a
same-named branch off `main` — matching the `.worktrees/` convention already
used in both `~/dev/realtime` and `~/dev/multigres`.

The patch is stored as a checked-in diff in this repo,
`realtime-playground/0001-use-public-realtime-url.patch`, applied via `git
apply`. The orchestration script checks whether it's already applied (e.g.
`grep -q PUBLIC_REALTIME_URL RealtimeClientForm.tsx`) before applying, so
re-running `up` is a no-op here.

Setup steps in the worktree, each skipped if already satisfied:
- `pnpm install` if `node_modules` is missing or `pnpm-lock.yaml` is newer
  than `node_modules/.modules.yaml`.
- Write `.env` at the worktree root (always rewritten on `up`, since the JWT
  is fresh each time):
  ```
  PUBLIC_REALTIME_URL=ws://localhost:4000/socket
  PUBLIC_SUPABASE_KEY=<freshly minted anon JWT>
  PUBLIC_SUPABASE_URL=http://localhost:4000   # placeholder; only read for the skipped login flow and a non-empty check
  ENABLE_PLAYGROUND=true                       # without this, "/" redirects to "/test" (Test Runner) and the Playground nav link doesn't render
  ```
- Start `pnpm web` (Next dev, port 3000 by default).

Failure modes to handle explicitly: `pnpm` not installed (clear error, same
style as the existing script's Docker preflight check), and port 3000 already
in use by something else (detect and fail fast, rather than letting Next
silently pick a different port and desync the printed URL from reality).

## Orchestration script

A new script, `multigres-playground.sh`, sibling to `multigres-realtime.sh`,
matching its conventions (bash, `set -euo pipefail`, `step`/`ok`/`die`-style
logging, env-var overrides, subcommands). It composes with the existing
script — `cmd_up` starts by shelling out to `./multigres-realtime.sh up`.

`mix phx.server` and `pnpm web` are long-running foreground processes (unlike
the Docker containers `multigres-realtime.sh` manages, which detach on their
own), so this script tracks them itself: a `.run/` directory (gitignored)
holds `realtime.pid`/`realtime.log` and `playground.pid`/`playground.log`.
`up` starts each via `nohup ... > log 2>&1 & echo $! > pidfile`, then polls
the relevant port (`4000/status` for Realtime, `3000` for the Playground)
with a timeout before declaring success — mirroring the existing script's
`WAIT_TIMEOUT` pattern.

Commands:
- **`up`** — cluster (`multigres-realtime.sh up`) → Realtime metadata DB
  (`mise run db-start` in `~/dev/realtime`, idempotent) → start `mix
  phx.server` → run `playground_setup.exs`, capture JWT → ensure playground
  clone/worktree/patch/`pnpm install` → write `.env` → start `pnpm web` →
  print the `/playground` URL. Safe to re-run while already up: restarts both
  processes to pick up a fresh JWT rather than erroring "port in use".
- **`down`** — kill the two PIDs via their pidfiles (tolerates an
  already-dead PID). **Leaves the Multigres cluster running** by default
  (other tooling, e.g. the smoke scripts, may still want it); a
  `--with-cluster` flag also runs `multigres-realtime.sh down`.
- **`logs`** — tail both log files, or one if given `realtime`/`playground`
  as an argument.
- **`info`** — reprint the current Playground URL, tenant/JWT info, and
  teardown instructions, like `multigres-realtime.sh info` does today.

Env var overrides, matching existing conventions: `REALTIME_DIR`
(`~/dev/realtime`), `PLAYGROUND_DIR` (`~/dev/realtime-playground`),
`REALTIME_PORT` (4000), `PLAYGROUND_PORT` (3000), `PLAYGROUND_JWT_SECRET`.

## Validating it works

After `up`, opening `http://localhost:3000/playground` should show the
"Configure project" gate already cleared (since `.env` has a valid key), the
Client Creation card connectable, and creating a channel + sending a
Broadcast message should round-trip through Multigres exactly like
`broadcast_smoke.exs` proves today — just interactively, with the
Logs/Broadcast/Presence/Postgres-Changes tables in the UI populating live.

## File layout added to this repo

```
multigres-playground.sh
realtime/playground_setup.exs
realtime-playground/0001-use-public-realtime-url.patch
.run/                          (gitignored: pidfiles + logs)
```

## Open items for implementation

- Exact health-check endpoint/timeout values for Realtime and the Playground
  during `up`'s polling step.
- Whether `mise run db-start` needs any Multigres-specific env overrides, or
  whether it's fully independent of which tenant DB Realtime ends up pointed
  at (expected: independent — it's Realtime's own metadata DB, unrelated to
  the tenant's data DB).
