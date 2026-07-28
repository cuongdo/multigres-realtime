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
# Prints two labeled lines on the last two lines of stdout — ANON_JWT=... and
# SERVICE_JWT=.... Callers should capture with `| tail -2` and parse by prefix.
# All other output goes to stderr.
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
