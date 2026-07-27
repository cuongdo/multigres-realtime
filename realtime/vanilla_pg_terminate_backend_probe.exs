# vanilla_pg_terminate_backend_probe.exs
#
# Reproduces Realtime's `Database.transaction/1 handles transaction errors` test
# EXACTLY (Postgrex.transaction wrapping a self pg_terminate_backend), but against
# a directly-attached vanilla-ish Postgres (realtime-db-1, supabase/postgres:17.6.1.127,
# no Multigres in the loop at all) to check whether the SQLSTATE Realtime's test
# hardcodes (admin_shutdown/57P01) is actually reliable outside of Multigres, or
# whether the self-terminate-then-COMMIT timing issue is a general Postgres/Postgrex
# phenomenon.
#
# Run: cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/vanilla_pg_terminate_backend_probe.exs

{:ok, db_conn} =
  Postgrex.start_link(
    hostname: "127.0.0.1",
    port: 5432,
    username: "supabase_admin",
    password: "postgres",
    database: "postgres"
  )

result =
  Postgrex.transaction(db_conn, fn conn ->
    Postgrex.query!(conn, "select pg_terminate_backend(pg_backend_pid())", [])
  end)

IO.inspect(result, label: "RESULT")

case result do
  {:error, %Postgrex.Error{postgres: %{code: code}}} ->
    IO.puts("SQLSTATE: #{code}")

  {:error, %DBConnection.ConnectionError{} = e} ->
    IO.puts("DBConnection.ConnectionError (no SQLSTATE at all): #{Exception.message(e)}")

  other ->
    IO.puts("UNEXPECTED: #{inspect(other)}")
end

System.halt(0)
