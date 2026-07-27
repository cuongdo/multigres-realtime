# postgres_changes_poller_smoke.exs
#
# End-to-end smoke test of Supabase Realtime's REAL Postgres Changes (CDC)
# supervision tree — Extensions.PostgresCdcRls.WorkerSupervisor, spawning the
# actual ReplicationPoller and SubscriptionManager GenServers exactly as
# production does on a channel join — against a Multigres gateway.
#
# This goes one level deeper than postgres_changes_smoke.exs, which drove the
# underlying SQL functions (Replications.prepare_replication/list_changes)
# manually. Here we let Realtime's own GenServer supervision tree do
# everything on its own schedule: publication-oid discovery, slot creation,
# the poll loop (with backoff/jitter), and subscription registration — the
# same code path a real client's channel join triggers via
# Realtime.PostgresCdc.connect/after_connect.
#
# Success signal: rather than reimplementing Phoenix's fastlane dispatch (which
# requires a live Phoenix.Channel process) to catch the decoded change
# ourselves, we watch the replication slot's confirmed_flush_lsn in
# pg_replication_slots. It only advances when something actually calls
# pg_logical_slot_get_changes (i.e. realtime.list_changes) and consumes past
# our insert — proof the real ReplicationPoller polled, decoded, and advanced
# the slot through the Multigres gateway/pooler on its own.
#
# Prerequisites:
#   - Multigres cluster up & prepped:  ~/dev/integration-scripts/multigres-realtime.sh up
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/postgres_changes_poller_smoke.exs
#
# Override the gateway target via env: GATEWAY_HOST, GATEWAY_PORT, GATEWAY_USER,
# GATEWAY_PASSWORD, GATEWAY_DB.

alias Extensions.PostgresCdcRls
alias Extensions.PostgresCdcRls.Subscriptions
alias Realtime.Api
alias Realtime.Tenants.Migrations

defmodule Smoke do
  def step(msg), do: IO.puts(IO.ANSI.cyan() <> "==> " <> msg <> IO.ANSI.reset())
  def ok(msg), do: IO.puts(IO.ANSI.green() <> "    ok: " <> msg <> IO.ANSI.reset())
  def note(msg), do: IO.puts("    " <> msg)

  def die(msg) do
    IO.puts(IO.ANSI.red() <> "FAIL: " <> msg <> IO.ANSI.reset())
    System.halt(1)
  end

  def partial(msg) do
    IO.puts(IO.ANSI.yellow() <> "PARTIAL: " <> msg <> IO.ANSI.reset())
    System.halt(2)
  end
end

host = System.get_env("GATEWAY_HOST", "127.0.0.1")
port = System.get_env("GATEWAY_PORT", "15432")
user = System.get_env("GATEWAY_USER", "postgres")
pass = System.get_env("GATEWAY_PASSWORD", "postgres")
db = System.get_env("GATEWAY_DB", "postgres")
external_id = "multigres-poller-smoke-" <> Integer.to_string(System.unique_integer([:positive]))
publication = "supabase_realtime_poller_smoke"
slot_name = "poller_smoke_slot_#{System.unique_integer([:positive])}"
table = "poller_smoke_changes"

Smoke.step("Target gateway: #{user}@#{host}:#{port}/#{db}  (tenant: #{external_id})")

# --- 1. Open a monitoring connection + create the table/publication BEFORE
#        starting the poller, so it sees non-empty publication oids on init
#        and creates the slot immediately instead of waiting on the 60s
#        check_oids cycle. -----------------------------------------------------
Smoke.step("Creating public.#{table} and publication #{publication} (pre-populated)")

{:ok, mon_conn} =
  Postgrex.start_link(
    hostname: host,
    port: String.to_integer(port),
    username: user,
    password: pass,
    database: db,
    ssl: false
  )

Postgrex.query!(mon_conn, "DROP PUBLICATION IF EXISTS #{publication}", [])
Postgrex.query!(mon_conn, "DROP TABLE IF EXISTS public.#{table}", [])

Postgrex.query!(
  mon_conn,
  """
  create table public.#{table} (
    id serial primary key,
    details text
  )
  """,
  []
)

Postgrex.query!(mon_conn, "grant all on table public.#{table} to anon", [])
Postgrex.query!(mon_conn, "grant all on table public.#{table} to authenticated", [])
Postgrex.query!(mon_conn, "create publication #{publication} for table public.#{table}", [])
Smoke.ok("table + publication created")

# --- 2. Register a tenant pointing at the gateway, with a unique slot name so
#        this run never collides with a previous one's leftover slot. ---------
Smoke.step("Registering tenant #{external_id}")

tenant_attrs = %{
  "external_id" => external_id,
  "name" => "multigres-poller-smoke",
  "postgres_cdc_default" => "postgres_cdc_rls",
  "jwt_secret" => "multigres-poller-smoke-secret",
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
        "publication" => publication,
        "slot_name" => slot_name,
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
Smoke.ok("tenant registered (slot_name=#{slot_name})")

# --- 2b. Run Realtime's tenant migrations through the gateway, creating the
#         realtime schema/functions (realtime.subscription, realtime.list_changes,
#         etc.) that the poller and Subscriptions.create/6 depend on. ----------
Smoke.step("Running Realtime tenant migrations through the gateway")

case Migrations.run_migrations(tenant) do
  res when res in [:ok, :noop] ->
    Smoke.ok("migrations applied (#{res})")

  {:error, reason} ->
    Smoke.die("tenant migrations failed through the gateway: #{inspect(reason)}")
end

# --- 3. Start the REAL supervision tree: WorkerSupervisor -> ReplicationPoller
#        + SubscriptionManager. This is exactly Extensions.PostgresCdcRls.start/1,
#        the function a channel join's handle_connect dispatches to. ----------
Smoke.step("Starting the real ReplicationPoller + SubscriptionManager (Extensions.PostgresCdcRls.start/1)")

case PostgresCdcRls.start(%{"id" => external_id, "region" => "us-east-1"}) do
  {:ok, _pid} -> Smoke.ok("supervision tree started")
  {:error, reason} -> Smoke.die("failed to start the CDC supervision tree: #{inspect(reason)}")
end

# handle_connect's real callers poll get_manager_conn in a retry loop (the
# manager registers itself in :syn once its own DB connection is up); mirror
# that here instead of a fixed sleep.
wait_for_manager = fn wait_for_manager, attempts ->
  case PostgresCdcRls.get_manager_conn(external_id) do
    {:ok, manager_pid, conn} ->
      {manager_pid, conn}

    _ when attempts > 0 ->
      Process.sleep(200)
      wait_for_manager.(wait_for_manager, attempts - 1)

    _ ->
      nil
  end
end

case wait_for_manager.(wait_for_manager, 50) do
  nil ->
    Smoke.die("""
    SubscriptionManager never registered a connection/manager through the gateway
    within 10s. Check the gateway logs (multigres-realtime.sh logs).
    """)

  {manager_pid, conn} ->
    Smoke.ok("SubscriptionManager connected through the gateway")

    # --- 4. Register a real subscription via the production entrypoint -------
    Smoke.step("Registering a subscription via PostgresCdcRls.create_subscription/7 (production path)")

    {:ok, subscription_params} =
      Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public", "table" => table})

    subscription_list = [%{id: UUID.uuid1(), claims: %{"role" => "anon"}, subscription_params: subscription_params}]

    case PostgresCdcRls.create_subscription(conn, tenant, publication, 4, subscription_list, manager_pid, self()) do
      {:ok, _} -> Smoke.ok("subscription registered")
      {:error, reason} -> Smoke.die("subscription registration failed: #{inspect(reason)}")
    end

    # --- 5. Wait for the poller to create the slot on its own ----------------
    Smoke.step("Waiting for the real ReplicationPoller to create the replication slot")

    wait_for_slot = fn wait_for_slot, attempts ->
      case Postgrex.query(mon_conn, "select confirmed_flush_lsn from pg_replication_slots where slot_name = $1", [
             slot_name
           ]) do
        {:ok, %Postgrex.Result{rows: [[lsn]]}} ->
          lsn

        _ when attempts > 0 ->
          Process.sleep(200)
          wait_for_slot.(wait_for_slot, attempts - 1)

        _ ->
          nil
      end
    end

    baseline_lsn = wait_for_slot.(wait_for_slot, 50)

    if is_nil(baseline_lsn) do
      Smoke.die("""
      ReplicationPoller never created slot '#{slot_name}' through the gateway within 10s.
      This means pg_create_logical_replication_slot (called from the poller's own
      poll loop, not a manual probe) failed or the poller never observed the
      publication's tables. Check the gateway logs.
      """)
    end

    Smoke.ok("slot created by the real poller (baseline confirmed_flush_lsn=#{inspect(baseline_lsn)})")

    # --- 6. Insert a row and wait for the poller's OWN poll loop to advance the
    #        slot past our insert — proof it decoded WAL through the tunnel on
    #        its own schedule, not because we drove it manually. ---------------
    Smoke.step("Inserting a row and watching the slot advance on the poller's own schedule")

    value = "hello-from-the-real-poller"
    %{rows: [[id]]} = Postgrex.query!(mon_conn, "insert into public.#{table} (details) values ($1) returning id", [value])
    Smoke.note("inserted id=#{id} details=#{value}; watching confirmed_flush_lsn for up to 10s…")

    wait_for_advance = fn wait_for_advance, attempts ->
      case Postgrex.query(mon_conn, "select confirmed_flush_lsn from pg_replication_slots where slot_name = $1", [
             slot_name
           ]) do
        {:ok, %Postgrex.Result{rows: [[lsn]]}} when lsn != baseline_lsn ->
          {:advanced, lsn}

        _ when attempts > 0 ->
          Process.sleep(200)
          wait_for_advance.(wait_for_advance, attempts - 1)

        _ ->
          :timeout
      end
    end

    case wait_for_advance.(wait_for_advance, 50) do
      {:advanced, new_lsn} ->
        Smoke.ok("slot advanced #{inspect(baseline_lsn)} -> #{inspect(new_lsn)} — the real poller drained our INSERT")

        IO.puts(
          IO.ANSI.green() <>
            "\nPASS: Realtime's real ReplicationPoller/SubscriptionManager GenServers work end-to-end through Multigres." <>
            IO.ANSI.reset()
        )

        System.halt(0)

      :timeout ->
        Smoke.partial("""
        the CDC supervision tree started and the slot was created through the
        gateway, but confirmed_flush_lsn never advanced within 10s after the
        insert — the poller may be idling/backed off longer than expected, or
        something downstream of decoding failed silently. This is weaker
        evidence than a FAIL: the slot creation + publication discovery (the
        core gateway-facing SQL) already succeeded above.
        """)
    end
end
