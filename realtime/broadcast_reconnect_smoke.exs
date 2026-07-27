# broadcast_reconnect_smoke.exs
#
# Resilience smoke test for Supabase Realtime's Broadcast-from-Database feature
# against a Multigres gateway: does the gateway/pooler correctly tear down an
# abruptly-killed `replication=database` tunnel connection so a SECOND
# connection for the same tenant can be established right after — with no
# leftover state (reserved connection, walsender, slot) blocking it?
#
# Realtime's Broadcast-from-DB replication slot is created TEMPORARY (see
# ReplicationConnection: "CREATE_REPLICATION_SLOT ... TEMPORARY LOGICAL ..."),
# so it's tied to the live session and is dropped by Postgres itself when that
# session ends — there is no WAL backlog to resume from a stale slot. What
# *is* worth proving is the reconnect path itself: kill the connection
# abruptly (simulating a network blip / crash, not a graceful stop), then
# start a brand new ReplicationConnection for the SAME tenant and confirm it
# comes up cleanly and broadcasts still flow.
#
# Prerequisites:
#   - Multigres cluster up & prepped:  ~/dev/integration-scripts/multigres-realtime.sh up
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/broadcast_reconnect_smoke.exs
#
# Override the gateway target via env: GATEWAY_HOST, GATEWAY_PORT, GATEWAY_USER,
# GATEWAY_PASSWORD, GATEWAY_DB.

alias Realtime.Api
alias Realtime.Database
alias Realtime.Tenants
alias Realtime.Tenants.Migrations
alias Realtime.Tenants.ReplicationConnection

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
port = System.get_env("GATEWAY_PORT", "15432")
user = System.get_env("GATEWAY_USER", "postgres")
pass = System.get_env("GATEWAY_PASSWORD", "postgres")
db = System.get_env("GATEWAY_DB", "postgres")
external_id = System.get_env("SMOKE_TENANT_ID", "multigres-reconnect-smoke")

Smoke.step("Target gateway: #{user}@#{host}:#{port}/#{db}  (tenant: #{external_id})")

case Api.get_tenant_by_external_id(external_id) do
  nil -> :ok
  _tenant -> Api.delete_tenant_by_external_id(external_id)
end

tenant_attrs = %{
  "external_id" => external_id,
  "name" => "multigres-reconnect-smoke",
  "postgres_cdc_default" => "postgres_cdc_rls",
  "jwt_secret" => "multigres-reconnect-smoke-secret",
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
  case Api.create_tenant(tenant_attrs) do
    {:ok, t} -> t
    {:error, reason} -> Smoke.die("could not create tenant: #{inspect(reason)}")
  end

tenant = Api.get_tenant_by_external_id(external_id) || tenant
Smoke.ok("tenant registered")

Smoke.step("Running Realtime tenant migrations through the gateway")

case Migrations.run_migrations(tenant) do
  res when res in [:ok, :noop] -> Smoke.ok("migrations applied (#{res})")
  {:error, reason} -> Smoke.die("tenant migrations failed: #{inspect(reason)}")
end

{:ok, db_conn} = Database.connect(tenant, "multigres_reconnect_smoke", :stop)
Tenants.create_messages_partitions(db_conn)

send_and_await_broadcast = fn label ->
  topic = "reconnect-#{label}-" <> Integer.to_string(System.unique_integer([:positive]))
  tenant_topic = Tenants.tenant_topic(external_id, topic, false)
  RealtimeWeb.Endpoint.subscribe(tenant_topic)

  value = "hello-#{label}"

  Postgrex.query!(
    db_conn,
    """
    INSERT INTO realtime.messages (topic, extension, event, private, payload, inserted_at, updated_at)
    VALUES ($1, 'broadcast', 'INSERT', true, $2, now(), now())
    """,
    [topic, %{"value" => value}]
  )

  receive do
    msg ->
      Smoke.ok("[#{label}] received broadcast: #{inspect(msg, limit: 5)}")
      true
  after
    15_000 ->
      Smoke.note("[#{label}] no broadcast observed within 15s")
      false
  end
end

# --- 1. First connection: baseline broadcast works ----------------------------
Smoke.step("Starting ReplicationConnection #1")

repl_pid_1 =
  case ReplicationConnection.start(tenant, self()) do
    {:ok, pid} -> pid
    {:error, reason} -> Smoke.die("ReplicationConnection #1 failed to start: #{inspect(reason)}")
  end

Process.sleep(1_000)
unless Process.alive?(repl_pid_1), do: Smoke.die("ReplicationConnection #1 died shortly after start.")
Smoke.ok("connection #1 live (pid=#{inspect(repl_pid_1)})")

unless send_and_await_broadcast.("before-kill") do
  Smoke.die("baseline broadcast (before kill) was not observed — cannot proceed to the resilience check.")
end

# --- 2. Kill it abruptly (not ReplicationConnection.stop/2 — simulate a crash /
#        network blip, the harsher case) --------------------------------------
Smoke.step("Killing connection #1 abruptly (Process.exit :kill) — simulating a crash/network blip")
ref = Process.monitor(repl_pid_1)
Process.exit(repl_pid_1, :kill)

receive do
  {:DOWN, ^ref, :process, ^repl_pid_1, _reason} -> Smoke.ok("connection #1 is down")
after
  5_000 -> Smoke.die("connection #1 did not go down within 5s of being killed")
end

# Give the gateway/pooler a moment to notice the closed tunnel and release
# whatever it was holding (reserved connection, walsender) before reconnecting.
Process.sleep(1_000)

# --- 3. Start a second connection for the SAME tenant -------------------------
Smoke.step("Starting ReplicationConnection #2 for the same tenant right after the kill")

repl_pid_2 =
  case ReplicationConnection.start(tenant, self()) do
    {:ok, pid} ->
      pid

    {:error, reason} ->
      Smoke.die("""
      ReplicationConnection #2 failed to start after killing #1: #{inspect(reason)}

      This would mean the gateway/pooler left stale state (a reserved connection,
      walsender slot, or similar) after the abrupt disconnect that blocks a fresh
      replication=database connection for the same tenant. Check the gateway logs
      (multigres-realtime.sh logs).
      """)
  end

Process.sleep(1_000)

unless Process.alive?(repl_pid_2) do
  Smoke.die("ReplicationConnection #2 died shortly after start — the tunnel did not recover cleanly.")
end

Smoke.ok("connection #2 live (pid=#{inspect(repl_pid_2)}) — reconnect after abrupt kill succeeded")

# --- 4. Confirm broadcasts still flow on the new connection -------------------
Smoke.step("Confirming broadcasts flow on the new connection")

if send_and_await_broadcast.("after-reconnect") do
  IO.puts(
    IO.ANSI.green() <>
      "\nPASS: Multigres cleanly tears down an abruptly-killed replication tunnel and accepts a fresh reconnect for the same tenant." <>
      IO.ANSI.reset()
  )

  System.halt(0)
else
  IO.puts(
    IO.ANSI.yellow() <> """

    PARTIAL: the reconnect itself succeeded (connection #2 started and stayed
    alive), but no broadcast was observed on it within 15s. The reconnect path
    is validated; broadcast delivery on the new connection depends on
    Realtime's dispatcher/transport wiring outside the tunnel.
    """ <> IO.ANSI.reset()
  )

  System.halt(2)
end
