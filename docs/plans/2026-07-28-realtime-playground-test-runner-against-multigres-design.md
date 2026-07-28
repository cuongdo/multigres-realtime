# Running the Realtime Playground's Test Runner against Multigres

**Date:** 2026-07-28
**Status:** Design — not yet implemented
**Supersedes:** `docs/plans/2026-07-27-realtime-playground-against-multigres-design.md`

## Context

The prior design got the Playground's interactive page (Broadcast-from-Database only,
anon JWT, no login) working against Multigres. The Playground repo also ships a second
mode, **Test Runner** (`/test`), which runs `packages/tests`' 12 suites in-browser. Of
those, 5 are anon-only (already covered by the prior design) and 8 require real Supabase
Auth (`signInWithPassword`) plus PostgREST (`supabase.from(table)...`) against fixture
tables with RLS policies. This design extends the (still unimplemented) prior design so
`multigres-playground.sh up` gets both modes fully working.

## Goal

One command, `./multigres-playground.sh up`, brings up a stack where both
`http://localhost:3000/playground` and `http://localhost:3000/test` work end-to-end
against the Multigres gateway — including the 8 auth-gated Test Runner suites.

## Non-goals

- CI/automated E2E (still a possible follow-up; the headless `realtime-check.ts` tool
  described below already gives most of this for free, but wiring it into CI is out of
  scope here).
- Upstream contribution of the fixture schema. It's already generic and already lives
  upstream (see "Fixture setup" below) — nothing to author or contribute there.
  (One small local Playground patch does still remain, unrelated to this design: a
  pre-existing zod-schema crash fix, `0002-fix-broadcast-send-schema-nonoptional.patch`,
  carried over from the prior design. It's a genuine upstream bug, worth a follow-up PR,
  but out of scope here — see the implementation plan's "Refinements found during
  planning.")

## What this removes from the prior design

The prior design carried a one-line patch to the Playground
(`0001-use-public-realtime-url.patch`) plus a clone/worktree to apply it, because the
Playground hardcodes its websocket endpoint as `` `${supabaseUrl}/realtime/v1` `` and
that path only resolves in a real Supabase stack, where Kong strips the prefix before
forwarding to Realtime. Since Test Runner needs Kong anyway (see below), that hardcoded
assumption is now satisfied for free. **The patch, worktree, and clone-with-modifications
step are dropped entirely** — the Playground runs unmodified, straight from its own
`main`.

## Architecture

Six components, all local:

1. **Multigres cluster + gateway** — unchanged, via `./multigres-realtime.sh up`.
   `localhost:15432`.
2. **Realtime** — `mix phx.server` from `~/dev/realtime`, tenant registered against the
   gateway with `external_id = "localhost"` (unchanged from the prior design).
   `localhost:4000`.
3. **GoTrue** (NEW) — `supabase/gotrue` container. `GOTRUE_DB_DATABASE_URL` points at
   the gateway; on first start it runs its own `auth.*` schema migrations there — a new
   Postgres-wire compatibility surface for the gateway.
4. **PostgREST** (NEW) — `postgrest/postgrest` container. `PGRST_DB_URI` points at the
   gateway, `db-schemas = public`. Another new compatibility surface (heavy
   `pg_catalog` introspection).
5. **Kong** (NEW) — `kong` container with a minimal declarative `kong/kong.yml`
   (adapted from supabase/supabase's self-hosted `docker/kong.yml`), routing
   `/auth/v1` → GoTrue, `/rest/v1` → PostgREST, `/realtime/v1` (prefix stripped) →
   Realtime. Single public port, `localhost:8000` — this is `PUBLIC_SUPABASE_URL`.
6. **Playground** — unchanged Next.js app, `pnpm web` on port 3000.

**Shared JWT secret:** GoTrue, PostgREST, Realtime's tenant, and Kong's consumer config
all need to agree on one JWT secret (`PLAYGROUND_JWT_SECRET`, same env var as the prior
design) — otherwise a session JWT minted by GoTrue after login won't validate against
Realtime or PostgREST.

## Fixture setup (tables, RLS, triggers, publication)

The fixture schema the 8 auth-gated suites need — `public.pg_changes`, `public.dummy`,
`public.authorization`, `public.broadcast_changes`, `public.wallet`,
`public.replay_check`, RLS policies on those and on `realtime.messages`, the
`broadcast_changes_for_table_trigger`/`replay_check_trigger` triggers, and
`supabase_realtime` publication entries — already exists as actively-maintained,
generic logic in `~/dev/realtime/test/e2e/realtime-check.ts`'s `setup()` function. It is
more current than the stale copy embedded in the Playground's `SettingsModal.tsx` (which
is missing a `topic` column `broadcast_changes` upstream already has).

`setup()` is idempotent (`CREATE TABLE IF NOT EXISTS`, guarded policy/trigger creation)
and only its `cleanup(userId)` counterpart runs afterward, which deletes just the
ephemeral test user it created for its own run (`DELETE FROM auth.users WHERE id = ...`)
— the fixture schema itself is left intact. So there's no need to copy or fork any SQL:
`up` shells out to the script **in place**,

```bash
bun run ~/dev/realtime/test/e2e/realtime-check.ts \
  --env local --url http://localhost:8000 --db-url postgresql://postgres:postgres@localhost:15432/postgres \
  --publishable-key <anon-jwt> --secret-key <service-role-jwt> --test authorization
```

picking `authorization` (a cheap DB-required category) purely to trigger the fixture
setup. This also runs one real test end-to-end as a bonus compatibility check, in the
same spirit as `broadcast_smoke.exs`. Requires `bun` as a new prerequisite (already a
dependency of Realtime's own e2e tooling).

## Persistent test user

Separately — genuinely new, Multigres-specific glue — `up` idempotently creates a
**persistent** test user via GoTrue's admin API (`POST /auth/v1/admin/users`, tolerating
"already registered"), since `realtime-check.ts`'s own ephemeral user gets deleted and
can't be wired into a live browser session. Fixed email/password via
`PLAYGROUND_TEST_USER_EMAIL`/`PLAYGROUND_TEST_USER_PASSWORD` env vars (sensible
defaults, overridable).

## Orchestration script (`multigres-playground.sh`)

`up` sequence:

1. `./multigres-realtime.sh up` — cluster + gateway.
2. Start GoTrue, PostgREST, Kong containers pointed at the gateway, sharing
   `PLAYGROUND_JWT_SECRET`. Poll each until healthy (same `WAIT_TIMEOUT` pattern as the
   existing script).
3. `mix run realtime/playground_setup.exs` (unchanged from the prior design) — upserts
   the Realtime tenant, runs tenant migrations, mints the anon JWT.
4. Run `realtime-check.ts` in place against the new stack (fixture setup, above).
5. Create the persistent test user via GoTrue's admin API.
6. Ensure `~/dev/realtime-playground` is cloned (no worktree, no patch — runs on its
   own `main`).
7. Write `.env`: `PUBLIC_SUPABASE_URL=http://localhost:8000`,
   `PUBLIC_SUPABASE_KEY=<anon JWT>`, `PUBLIC_TEST_USER_EMAIL`/`PASSWORD`,
   `ENABLE_PLAYGROUND=true`. No `PUBLIC_REALTIME_URL` (Kong makes it unnecessary).
8. Start `pnpm web`.

`down` stops Realtime/Playground processes (pidfiles, as before) plus the 3 new
containers; `--with-cluster` still tears down the gateway too. `logs`/`info` extended to
cover the new containers.

Env var overrides, matching existing conventions: `KONG_PORT` (8000), `GOTRUE_PORT`,
`POSTGREST_PORT` (internal), `PLAYGROUND_JWT_SECRET`, `PLAYGROUND_TEST_USER_EMAIL`,
`PLAYGROUND_TEST_USER_PASSWORD`.

## Validating it works

After `up`, `http://localhost:3000/test` should show "configured" with no settings-modal
prompt; clicking **Run** should execute all 12 suites and turn green, including the 8
auth-gated ones. The `#ci-result` div should report `data-status="200"`.
`http://localhost:3000/playground` should keep working exactly as in the prior design.

As a faster headless pre-check: run `realtime-check.ts` with no `--test` filter (all
categories) — the same tool `up` already runs a subset of.

## Failure modes to handle explicitly

- `bun` not installed — clear error, same style as the existing Docker preflight check.
- GoTrue/PostgREST containers failing health checks — likely a real Postgres-wire
  compatibility finding in the gateway, not just a setup bug.
- Kong misrouting, especially websocket upgrade for `/realtime/v1` — `up` should smoke
  check `/auth/v1/health`, `/rest/v1/`, and a test websocket connect to `/realtime/v1`
  before declaring success.

## File layout added to this repo

```
multigres-playground.sh          # extended: +GoTrue/PostgREST/Kong, +fixtures, +test user
kong/kong.yml                     # new: minimal declarative Kong config
realtime/playground_setup.exs    # unchanged from prior design
.run/                              # gitignored: pidfiles + logs (unchanged)
```

## Open items for implementation

- Exact health-check endpoints/timeouts for GoTrue, PostgREST, and Kong during `up`'s
  polling step.
- Whether Kong's default config needs any tuning for websocket upgrade proxying of
  `/realtime/v1`, or the stock self-hosted `docker/kong.yml` routing works unmodified.
- Exact `kong.yml` service/route definitions (can be trimmed from supabase/supabase's
  full self-hosted config, since Storage/Studio/etc. aren't needed here).
