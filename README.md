# Multigres ↔ Realtime integration scripts

Bring up a **Multigres** cluster in Docker and test **Supabase Realtime**'s
Broadcast-from-Database (logical replication) feature against it. Realtime points
its replication connection at the Multigres gateway exactly as it would at a
normal PostgreSQL server; the gateway tunnels the `replication=database`
connection through to PostgreSQL.

## Prerequisites

- Docker Desktop running.
- A Multigres checkout to build from (defaults to the tunnel worktree
  `~/dev/multigres/.worktrees/realtime-broadcast-tunnel`). Building from a
  worktree compiles **that branch**, so this tests unmerged work.
- The Realtime repo at `~/dev/realtime` with its own metadata DB running
  (`mix ecto.setup`) — only needed for the smoke script in step 2.

## Step 1 — start Multigres and prepare it as a Realtime tenant DB

```bash
./multigres-realtime.sh up
```

This builds the cluster image from the worktree, starts it (full cluster in one
container), waits for health, then creates the Supabase roles Realtime's
migrations expect (`anon`, `authenticated`, `service_role`) on the gateway's
PostgreSQL. It prints the connection details when done.

The gateway PostgreSQL is published on **`localhost:15432`**, user/password/db
**`postgres`/`postgres`/`postgres`**.

Other commands:

```bash
./multigres-realtime.sh info     # reprint connection details + how to test
./multigres-realtime.sh psql     # open psql against the gateway
./multigres-realtime.sh logs     # follow cluster logs
./multigres-realtime.sh down     # stop & remove (add -v to also drop volumes)
./multigres-realtime.sh prep     # re-create the roles on a running cluster
```

Configuration via env vars (see `--help`): `MULTIGRES_DIR`, `GATEWAY_PG_PORT`,
`MULTIGRES_PG_MAX_CONNECTIONS`, `WAIT_TIMEOUT`.

> **Note:** the cluster image bundles **stock `postgres:17.7`**, not
> `supabase/postgres`. The role prep covers what Realtime's migrations need;
> Realtime then creates the `realtime` schema, the publication, and the
> replication slot itself on first connect (which is part of what's being
> tested).

## Step 2 — run Realtime against it

The easiest end-to-end check uses real Realtime code (migrations +
`ReplicationConnection` + broadcast) through the tunnel, in one command:

```bash
cd ~/dev/realtime
mix run ~/dev/integration-scripts/realtime/broadcast_smoke.exs
```

It registers a tenant pointed at the gateway, runs Realtime's tenant migrations
through the gateway, starts a replication connection (IDENTIFY_SYSTEM →
CREATE PUBLICATION → CREATE_REPLICATION_SLOT → START_REPLICATION, all tunneled),
inserts a `realtime.messages` row, and waits for the broadcast.

Outcomes:

- **PASS** — broadcast received end-to-end through the tunnel.
- **PARTIAL** (exit 2) — migrations + replication connection succeeded (the core
  tunnel path works) but no broadcast was observed within 15s. The tunnel is
  validated; broadcast delivery depends on Realtime's dispatcher/transport wiring
  outside the tunnel.
- **FAIL** (exit 1) — a migration or the replication connection was rejected by
  the gateway. That's a real compatibility finding — check
  `./multigres-realtime.sh logs`.

Override the target with env vars: `GATEWAY_HOST`, `GATEWAY_PORT`,
`GATEWAY_USER`, `GATEWAY_PASSWORD`, `GATEWAY_DB`, `SMOKE_TENANT_ID`.

### Running the full ExUnit suite against the gateway

Realtime's ExUnit harness provisions its own per-tenant PostgreSQL containers
(`test/support/containers.ex`) and hardcodes their host/port, so there's no
single switch to route the whole suite through the gateway. To run, say,
`test/realtime/tenants/replication_connection_test.exs` against it, point that
test's tenant fixture (`test/support/generators.ex`) at `127.0.0.1:15432` with
user/password `postgres`/`postgres` and `ssl_enforced: false`. The smoke script
above is the lower-friction path and covers the same tunnel behavior.

## Also validate the tunnel without Realtime

The Multigres repo ships a Go test that drives the raw replication wire sequence
through the gateway (the same sequence Realtime uses):

```bash
cd ~/dev/multigres/.worktrees/realtime-broadcast-tunnel
make build   # integration tests need the built binaries
go test ./go/test/endtoend/shardsetup/ -run TestGatewayReplicationStream -v -count=1
```
