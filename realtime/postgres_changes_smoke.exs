# postgres_changes_smoke.exs
#
# End-to-end smoke test of Supabase Realtime's Postgres Changes (CDC) feature
# against a Multigres gateway — using REAL Realtime code
# (Extensions.PostgresCdcRls.{Replications,Subscriptions}), not the raw wire
# protocol, and NOT the replication=database tunnel exercised by
# broadcast_smoke.exs.
#
# Postgres Changes works differently from Broadcast-from-Database: instead of
# a persistent `replication=database` streaming connection, it creates a
# logical replication slot with the wal2json output plugin and periodically
# drains it via plain SQL function calls over a REGULAR (pooled) connection:
#
#   - pg_create_logical_replication_slot($1, 'wal2json', 'true')   (Replications.prepare_replication/2)
#   - realtime.list_changes($1,$2,$3,$4)                            (Replications.list_changes/5,
#     which wraps pg_logical_slot_get_changes internally)
#   - pg_drop_replication_slot($1)                                  (Replications.drop_replication_slot/2)
#
# This exercises a genuinely different code path through Multigres than the
# tunnel: does the regular multigateway -> multipooler -> postgres query path
# correctly proxy WAL-decoding SQL functions (as opposed to the specially
# recognized `replication=database` startup parameter)?
#
# Prerequisites:
#   - Multigres cluster up & prepped:  ~/dev/integration-scripts/multigres-realtime.sh up
#   - The `postgres` database already has the `realtime` schema migrated
#     (broadcast_smoke.exs, run at least once, does this).
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/postgres_changes_smoke.exs
#
# Override the gateway target via env: GATEWAY_HOST, GATEWAY_PORT, GATEWAY_USER,
# GATEWAY_PASSWORD, GATEWAY_DB.

alias Extensions.PostgresCdcRls.Replications
alias Extensions.PostgresCdcRls.Subscriptions

defmodule Smoke do
  def step(msg), do: IO.puts(IO.ANSI.cyan() <> "==> " <> msg <> IO.ANSI.reset())
  def ok(msg), do: IO.puts(IO.ANSI.green() <> "    ok: " <> msg <> IO.ANSI.reset())
  def note(msg), do: IO.puts("    " <> msg)

  def die(msg) do
    IO.puts(IO.ANSI.red() <> "FAIL: " <> msg <> IO.ANSI.reset())
    System.halt(1)
  end
end

host = System.get_env("GATEWAY_HOST", "127.0.0.1")
port = String.to_integer(System.get_env("GATEWAY_PORT", "15432"))
user = System.get_env("GATEWAY_USER", "postgres")
pass = System.get_env("GATEWAY_PASSWORD", "postgres")
db = System.get_env("GATEWAY_DB", "postgres")
publication = "supabase_realtime_smoke_changes"
slot_name = "supabase_realtime_smoke_changes_slot_#{System.unique_integer([:positive])}"

Smoke.step("Target gateway: #{user}@#{host}:#{port}/#{db}  (publication: #{publication})")

# --- 1. Connect directly to the gateway (regular query path, no replication=database) ---
Smoke.step("Opening a regular (non-replication) connection to the gateway")

{:ok, conn} =
  Postgrex.start_link(
    hostname: host,
    port: port,
    username: user,
    password: pass,
    database: db,
    ssl: false
  )

Smoke.ok("connected")

# --- 2. Create a test table + publication (mirrors test/support/integrations.ex) ---
Smoke.step("Creating public.test table and publication #{publication}")

Postgrex.query!(conn, "DROP PUBLICATION IF EXISTS #{publication}", [])
Postgrex.query!(conn, "DROP TABLE IF EXISTS public.pg_changes_smoke", [])

Postgrex.query!(
  conn,
  """
  create table public.pg_changes_smoke (
    id serial primary key,
    details text
  )
  """,
  []
)

Postgrex.query!(conn, "grant all on table public.pg_changes_smoke to anon", [])
Postgrex.query!(conn, "grant all on table public.pg_changes_smoke to authenticated", [])
Postgrex.query!(conn, "create publication #{publication} for table public.pg_changes_smoke", [])
Smoke.ok("table + publication created")

# --- 3. Register a subscription (real Realtime SQL against realtime.subscription) ---
Smoke.step("Registering a Postgres Changes subscription (realtime.subscription insert)")

{:ok, subscription_params} =
  Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public", "table" => "pg_changes_smoke"})

case Subscriptions.create(
       conn,
       publication,
       [%{id: UUID.uuid1(), claims: %{"role" => "anon"}, subscription_params: subscription_params}],
       self(),
       self()
     ) do
  {:ok, _} ->
    Smoke.ok("subscription registered")

  {:error, reason} ->
    Smoke.die("""
    subscription registration failed through the gateway: #{inspect(reason)}

    This is a real Multigres/Realtime compatibility finding in the regular query
    path (not the tunnel) — check the gateway logs (multigres-realtime.sh logs).
    """)
end

# --- 4. Create the temporary wal2json replication slot -----------------------
Smoke.step("Creating a logical replication slot with the wal2json plugin")

case Replications.prepare_replication(conn, slot_name) do
  {:ok, _} ->
    Smoke.ok("slot created (pg_create_logical_replication_slot through the gateway)")

  {:error, reason} ->
    Smoke.die("""
    pg_create_logical_replication_slot failed through the gateway: #{inspect(reason)}

    This is the core Postgres Changes path (distinct from the replication=database
    tunnel) — check the gateway logs.
    """)
end

# --- 5. Insert a row and drain the slot via realtime.list_changes ------------
Smoke.step("Inserting a row and draining the slot via realtime.list_changes")

value = "hello-from-multigres-changes"
%{rows: [[id]]} = Postgrex.query!(conn, "insert into public.pg_changes_smoke (details) values ($1) returning id", [value])
Smoke.note("inserted id=#{id} details=#{value}")

case Replications.list_changes(conn, slot_name, publication, 100, 1_048_576) do
  {:ok, %Postgrex.Result{rows: rows}} ->
    Smoke.note("list_changes returned #{length(rows)} row(s): #{inspect(rows, limit: :infinity)}")

    match =
      Enum.find(rows, fn
        ["INSERT", "public", "pg_changes_smoke", _cols, record, _old, _ts, _subs, _errs, _count] ->
          String.contains?(record || "", value)

        _ ->
          false
      end)

    if match do
      Smoke.ok("decoded INSERT observed through the gateway's regular query path")
    else
      Smoke.die("""
      slot drained without error, but no matching decoded INSERT row was found.

      Rows: #{inspect(rows, limit: :infinity)}
      """)
    end

  {:error, reason} ->
    Smoke.die("""
    realtime.list_changes (pg_logical_slot_get_changes/wal2json) failed through the gateway: #{inspect(reason)}

    Check the gateway logs (multigres-realtime.sh logs).
    """)
end

# --- 6. Clean up the slot ------------------------------------------------------
Replications.drop_replication_slot(conn, slot_name)
Postgrex.query(conn, "DROP PUBLICATION IF EXISTS #{publication}", [])
Postgrex.query(conn, "DROP TABLE IF EXISTS public.pg_changes_smoke", [])

IO.puts(
  IO.ANSI.green() <>
    "\nPASS: Realtime Postgres Changes (wal2json CDC over the regular query path) works end-to-end through Multigres." <>
    IO.ANSI.reset()
)

System.halt(0)
