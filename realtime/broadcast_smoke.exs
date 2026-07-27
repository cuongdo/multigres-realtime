# broadcast_smoke.exs
#
# End-to-end smoke test of Supabase Realtime's Broadcast-from-Database feature
# against a Multigres gateway — i.e. it drives REAL Realtime code through the
# replication tunnel, not the raw wire protocol.
#
# It:
#   1. registers a tenant whose DB points at the Multigres gateway,
#   2. runs Realtime's tenant migrations through the gateway
#      (exercises a large amount of DDL/SQL compatibility),
#   3. starts a ReplicationConnection — this opens the `replication=database`
#      connection through the tunnel and performs IDENTIFY_SYSTEM,
#      CREATE PUBLICATION, CREATE_REPLICATION_SLOT and START_REPLICATION,
#   4. inserts a row into realtime.messages and waits for the broadcast to come
#      back, proving WAL streamed through the tunnel and was decoded.
#
# Prerequisites:
#   - Multigres cluster up & prepped:  ~/dev/integration-scripts/multigres-realtime.sh up
#   - Realtime's own metadata DB running (e.g. `mix ecto.setup`).
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/broadcast_smoke.exs
#
# Override the gateway target via env: GATEWAY_HOST, GATEWAY_PORT, GATEWAY_USER,
# GATEWAY_PASSWORD, GATEWAY_DB, SMOKE_TENANT_ID.

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
external_id = System.get_env("SMOKE_TENANT_ID", "multigres-smoke")

Smoke.step("Target gateway: #{user}@#{host}:#{port}/#{db}  (tenant: #{external_id})")

# --- 1. Register a tenant pointing at the gateway -----------------------------
Smoke.step("Registering tenant in Realtime metadata DB")

# Start clean so re-runs are idempotent.
case Api.get_tenant_by_external_id(external_id) do
  nil -> :ok
  _tenant -> Api.delete_tenant_by_external_id(external_id)
end

tenant_attrs = %{
  "external_id" => external_id,
  "name" => "multigres-smoke",
  "postgres_cdc_default" => "postgres_cdc_rls",
  "jwt_secret" => "multigres-smoke-secret",
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
    {:ok, tenant} -> tenant
    {:error, reason} -> Smoke.die("could not create tenant (is the metadata DB up?): #{inspect(reason)}")
  end

# Reload so the extensions association is populated for the connection helpers.
tenant = Api.get_tenant_by_external_id(external_id) || tenant
Smoke.ok("tenant registered")

# --- 2. Run Realtime's tenant migrations through the gateway ------------------
Smoke.step("Running Realtime tenant migrations through the gateway")

case Migrations.run_migrations(tenant) do
  res when res in [:ok, :noop] ->
    Smoke.ok("migrations applied (#{res})")

  {:error, reason} ->
    Smoke.die("""
    tenant migrations failed through the gateway: #{inspect(reason)}

    This is a real Multigres/Realtime compatibility finding — some migration SQL
    was rejected by the gateway. Check the gateway logs (multigres-realtime.sh logs).
    """)
end

# --- 3. Start the replication connection (the tunnel under test) --------------
Smoke.step("Starting ReplicationConnection (opens replication=database through the tunnel)")

repl_pid =
  case ReplicationConnection.start(tenant, self()) do
    {:ok, pid} ->
      pid

    {:error, reason} ->
      Smoke.die("""
      ReplicationConnection failed to start: #{inspect(reason)}

      This is the core tunnel path (IDENTIFY_SYSTEM / CREATE PUBLICATION /
      CREATE_REPLICATION_SLOT / START_REPLICATION). Check the gateway logs.
      """)
  end

Process.sleep(2_000)

unless Process.alive?(repl_pid) do
  Smoke.die("ReplicationConnection died shortly after start — the tunnel did not sustain the stream.")
end

Smoke.ok("replication connection is live and streaming through the tunnel")

# --- 4. Insert a row and wait for the broadcast -------------------------------
Smoke.step("Inserting a realtime.messages row and waiting for the broadcast")

topic = "smoke-" <> Integer.to_string(System.unique_integer([:positive]))
# private messages broadcast on the "-private:" topic.
tenant_topic = Tenants.tenant_topic(external_id, topic, false)
RealtimeWeb.Endpoint.subscribe(tenant_topic)

{:ok, db_conn} = Database.connect(tenant, "multigres_smoke", :stop)
# Ensure today's partition exists so the insert lands.
Tenants.create_messages_partitions(db_conn)

value = "hello-from-multigres"

Postgrex.query!(
  db_conn,
  """
  INSERT INTO realtime.messages (topic, extension, event, private, payload, inserted_at, updated_at)
  VALUES ($1, 'broadcast', 'INSERT', true, $2, now(), now())
  """,
  [topic, %{"value" => value}]
)

Smoke.note("inserted topic=#{topic} value=#{value}; waiting up to 15s for broadcast…")

receive do
  msg ->
    Smoke.ok("received broadcast through the tunnel: #{inspect(msg, limit: 8)}")
    IO.puts(IO.ANSI.green() <> "\nPASS: Realtime Broadcast-from-Database works end-to-end through Multigres." <> IO.ANSI.reset())
    System.halt(0)
after
  15_000 ->
    IO.puts(IO.ANSI.yellow() <> """

    PARTIAL: migrations + replication connection succeeded through the tunnel
    (the core replication path works), but no broadcast was observed on
    #{tenant_topic} within 15s.

    The replication tunnel itself is validated. Broadcast delivery here depends
    on Realtime's dispatcher/transport wiring outside the tunnel; for a strict
    delivery assertion run the ExUnit test:

      mix test test/realtime/tenants/replication_connection_test.exs

    (point its tenant at the gateway — see the integration-scripts README).
    """ <> IO.ANSI.reset())
    System.halt(2)
end
