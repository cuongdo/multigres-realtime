# savepoint_latency_bench.exs
#
# Measures round-trip latency for the exact operation pattern used by
# Realtime's write-authorization probe (lib/realtime/tenants/authorization.ex:327,
# check_write_policies/4): a query run with `mode: :savepoint` inside an
# already-open transaction, which gets rejected by an RLS policy. This is the
# call site identified as the source of the `SAVEPOINT postgrex_query` wire
# artifact in the 2026-07-14 stall investigation. Also measures a plain
# baseline query for comparison. Run against both a plain Postgres target and
# a Multigres gateway target to quantify the latency difference the "added
# latency exposes a client-side race" theory depends on.
#
# Prerequisites: an RLS-denied table + a non-superuser/non-BYPASSRLS role
# granted INSERT on it (the `authenticated` role is BYPASSRLS-free on both
# the plain supabase/postgres image and Multigres's managed Postgres,
# confirmed in the 2026-07-14 investigation):
#
#   CREATE TABLE IF NOT EXISTS rls_bench (id serial primary key, val text);
#   ALTER TABLE rls_bench ENABLE ROW LEVEL SECURITY;
#   CREATE POLICY deny_all ON rls_bench FOR INSERT WITH CHECK (false);
#   GRANT INSERT ON rls_bench TO authenticated;
#   GRANT USAGE, SELECT ON SEQUENCE rls_bench_id_seq TO authenticated;
#   ALTER ROLE authenticated LOGIN PASSWORD 'postgres';  -- test-only
#
# Run from the realtime repo:
#   cd ~/dev/realtime && mix run ~/dev/integration-scripts/realtime/savepoint_latency_bench.exs
#
# Env vars: BENCH_HOST, BENCH_PORT, BENCH_USER (default authenticated),
# BENCH_PASSWORD, BENCH_DB, BENCH_N (iteration count, default 200),
# BENCH_LABEL (just a display label for the report).

host = System.get_env("BENCH_HOST", "127.0.0.1")
port = System.get_env("BENCH_PORT", "5433") |> String.to_integer()
user = System.get_env("BENCH_USER", "authenticated")
pass = System.get_env("BENCH_PASSWORD", "postgres")
db = System.get_env("BENCH_DB", "postgres")
n = System.get_env("BENCH_N", "200") |> String.to_integer()
label = System.get_env("BENCH_LABEL", "#{user}@#{host}:#{port}/#{db}")

IO.puts(IO.ANSI.cyan() <> "==> Benchmarking #{label} (n=#{n})" <> IO.ANSI.reset())

{:ok, conn} =
  Postgrex.start_link(
    hostname: host,
    port: port,
    username: user,
    password: pass,
    database: db,
    ssl: false
  )

defmodule Bench do
  def time_it(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    stop = System.monotonic_time(:microsecond)
    {stop - start, result}
  end

  def percentile(sorted, p) do
    idx = max(0, min(length(sorted) - 1, trunc(p / 100 * length(sorted))))
    Enum.at(sorted, idx)
  end

  def report(label, samples_us) do
    sorted = Enum.sort(samples_us)
    n = length(sorted)
    mean = Enum.sum(sorted) / n / 1000

    IO.puts("""
        #{label} (n=#{n}, ms):
          min=#{Enum.min(sorted) / 1000 |> Float.round(3)}
          p50=#{percentile(sorted, 50) / 1000 |> Float.round(3)}
          p95=#{percentile(sorted, 95) / 1000 |> Float.round(3)}
          p99=#{percentile(sorted, 99) / 1000 |> Float.round(3)}
          max=#{Enum.max(sorted) / 1000 |> Float.round(3)}
          mean=#{Float.round(mean, 3)}
    """)
  end
end

# --- Baseline: plain SELECT 1, N iterations -----------------------------------
baseline_samples =
  for _ <- 1..n do
    {us, _} = Bench.time_it(fn -> Postgrex.query!(conn, "SELECT 1", []) end)
    us
  end

Bench.report("baseline (SELECT 1)", baseline_samples)

# --- The check_write_policies pattern: savepoint-mode INSERT, RLS-rejected ---
# Mirrors lib/realtime/tenants/authorization.ex:327 exactly: an outer
# transaction, and inside it, a query run with mode: :savepoint that fails.
savepoint_samples =
  for i <- 1..n do
    {us, _result} =
      Bench.time_it(fn ->
        Postgrex.transaction(conn, fn tx_conn ->
          case Postgrex.query(tx_conn, "INSERT INTO rls_bench (val) VALUES ($1)", ["x#{i}"],
                 mode: :savepoint
               ) do
            {:ok, _} -> :ok
            {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} -> :expected_denial
            {:error, other} -> {:unexpected_error, other}
          end
        end)
      end)

    us
  end

Bench.report("savepoint-mode RLS-rejected INSERT (check_write_policies pattern)", savepoint_samples)

IO.puts(IO.ANSI.green() <> "==> Done: #{label}" <> IO.ANSI.reset())
