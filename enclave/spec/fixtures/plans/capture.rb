# frozen_string_literal: true

# Regenerates the plan fixtures in this directory. It isn't part of the test
# suite. Run it by hand, with Docker running:
#
#   ruby enclave/spec/fixtures/plans/capture.rb
#
# It starts a throwaway postgres:18 container with its own name, loads
# sample.sql, runs ANALYZE, and writes one <name>.json per plan below: the
# exact output of EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON), or with
# VERBOSE too for a name that ends in _verbose. It also
# writes statistics.txt, the pg_class, pg_stats, and pg_get_indexdef values
# that generator_two_spec.rb builds its Statistics input from. Autovacuum is
# off, so no index's visibility map gets set and the Index Only Scan fixture
# shows heap fetches. The container is removed at the end, even on failure.
#
# Timings and buffer counts change from run to run. Row counts, plan shapes,
# and the statistics don't, because the sample rows are computed, not random.

require "json"
require "open3"
require "securerandom"

DIR = __dir__
CONTAINER = "quaack-plan-capture-#{SecureRandom.hex(4)}".freeze
EXPLAIN = "EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)"
# The one fixture that shows what VERBOSE adds: a "Schema" on each scan, and
# columns qualified by their alias even in scan filters.
VERBOSE_EXPLAIN = "EXPLAIN (ANALYZE, VERBOSE, BUFFERS, SETTINGS, FORMAT JSON)"

# name => [SET LOCAL lines, query, optional setup SQL]. The SET lines push the
# planner into the pattern each fixture is for. The setup runs in the same
# transaction, just before the EXPLAIN.
PLANS = {
  "seq_scan_most_rows" => [
    ["enable_indexscan = off", "enable_bitmapscan = off"],
    "SELECT c.name FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
    "WHERE o.status = 'shipped' AND o.created_at > '2026-01-01' AND o.total_cents = 5100"
  ],
  "seq_scan_most_rows_verbose" => [
    ["enable_indexscan = off", "enable_bitmapscan = off"],
    "SELECT c.name FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
    "WHERE o.status = 'shipped' AND o.created_at > '2026-01-01' AND o.total_cents = 5100"
  ],
  "index_scan_filter" => [
    ["enable_seqscan = off", "enable_bitmapscan = off"],
    "SELECT o.id FROM public.orders o WHERE o.status = 'shipped' AND o.total_cents < 5000"
  ],
  "bitmap_heap_scan_filter" => [
    [], "SELECT o.id FROM public.orders o WHERE o.status = 'shipped' AND o.total_cents < 5000"
  ],
  # The InitPlan comes before the Bitmap Index Scan in the heap scan's Plans.
  "bitmap_heap_scan_init_plan" => [
    [], "SELECT o.id FROM public.orders o " \
        "WHERE o.status = (SELECT 'shipped'::text FROM public.customers c WHERE c.id = 1) AND o.total_cents < 5000"
  ],
  "sort_under_limit" => [
    [], "SELECT o.id FROM public.orders o WHERE o.customer_id = 5 ORDER BY o.created_at DESC LIMIT 3"
  ],
  "sort_external_merge" => [
    ["work_mem = '64kB'"],
    "SELECT * FROM public.orders o WHERE o.status = 'delivered' ORDER BY o.total_cents DESC NULLS LAST, o.id"
  ],
  "nested_loop_inner" => [
    ["enable_hashjoin = off", "enable_mergejoin = off", "enable_indexscan = off", "enable_bitmapscan = off"],
    "SELECT c.name, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
    "WHERE c.created_at < '2025-01-10' AND o.status = 'failed'"
  ],
  "hash_join_batches" => [
    ["work_mem = '64kB'"],
    "SELECT c.name, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id"
  ],
  "bitmap_or" => [
    # Two of the three arms use the same index.
    [], "SELECT c.id FROM public.customers c WHERE c.id < 5 OR c.email = 'ada.smith.8@example.com' OR c.id > 1995"
  ],
  "hash_aggregate" => [
    [], "SELECT o.status, o.total_cents, count(*) FROM public.orders o GROUP BY o.status, o.total_cents"
  ],
  "group_aggregate_sort" => [
    ["enable_hashagg = off"],
    "SELECT c.name, count(*) FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
    "GROUP BY c.name, c.created_at"
  ],
  "index_only_scan_heap_fetches" => [
    ["enable_seqscan = off", "enable_bitmapscan = off"],
    "SELECT o.customer_id FROM public.orders o WHERE o.customer_id < 100"
  ],
  "primary_key_lookup" => [[], "SELECT * FROM public.orders o WHERE o.id = 5"],
  # The literals are sentinels: the trust-boundary spec checks they never show
  # up in anything but a candidate's to_ddl and predicate.
  "sentinel_literals" => [
    ["enable_indexscan = off", "enable_bitmapscan = off"],
    "SELECT c.id FROM public.customers c WHERE c.email = 'quaack-sentinel-email' AND c.name = 'quaack-sentinel-name'"
  ],
  # A generic plan prints the parameter as $1: a constant, but not a literal.
  "seq_scan_parameter" => [
    ["enable_indexscan = off", "enable_bitmapscan = off", "plan_cache_mode = force_generic_plan"],
    "EXECUTE p(5100)",
    "PREPARE p(integer) AS SELECT o.id FROM public.orders o WHERE o.status = 'shipped' AND o.total_cents = $1"
  ],
  # Zero index-tuple and operator costs, and a high heap-tuple cost, make
  # the planner AND two bitmaps instead of rechecking one.
  "bitmap_and" => [
    ["enable_indexscan = off", "enable_seqscan = off", "cpu_tuple_cost = 10", "cpu_index_tuple_cost = 0",
     "cpu_operator_cost = 0"],
    "SELECT o.id FROM public.orders o WHERE o.customer_id < 200 AND o.id < 2000"
  ],
  "incremental_sort" => [
    [], "SELECT * FROM public.orders o ORDER BY o.status, o.total_cents LIMIT 10"
  ],
  # Sorted by the index it reads, so no Sort feeds the aggregate.
  "group_aggregate_presorted" => [
    ["enable_hashagg = off", "enable_sort = off"],
    "SELECT o.customer_id, count(*) FROM public.orders o GROUP BY o.customer_id"
  ],
  # The index in use is the primary key, and the Filter has a range before a
  # constant equality.
  "index_scan_unique_filter" => [
    ["enable_seqscan = off", "enable_bitmapscan = off"],
    "SELECT c.id FROM public.customers c WHERE c.id < 1800 AND c.created_at > '2025-01-05' " \
    "AND c.name = 'Ada Smith 8' AND c.id % 2 = 0"
  ],
  # The inner side is an Index Scan with the join in its Index Cond, and a
  # Filter with a range before a constant equality.
  "nested_loop_parameterized" => [
    ["enable_hashjoin = off", "enable_mergejoin = off", "enable_memoize = off", "enable_bitmapscan = off"],
    "SELECT c.name, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
    "WHERE c.name = 'Ada Jones 8' AND o.total_cents > 1000 AND o.status = 'shipped'"
  ],
  "hash_aggregate_two_tables" => [
    [], "SELECT c.name, o.status, count(*) FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
        "GROUP BY c.name, o.status"
  ],
  "sort_two_tables" => [
    [], "SELECT c.name, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
        "ORDER BY c.name, o.total_cents, c.created_at"
  ],
  # A lossy bitmap needs more heap pages than the sample tables have, so this
  # one makes its own table inside the transaction. The spec builds its
  # statistics by hand: a million rows, and the one index.
  "bitmap_heap_scan_lossy" => [
    ["enable_seqscan = off", "enable_indexscan = off", "work_mem = '64kB'"],
    "SELECT e.id FROM public.events e WHERE e.kind < 300 AND e.id < 100000",
    "CREATE TABLE public.events AS SELECT i AS id, i % 1000 AS kind FROM generate_series(1, 1000000) AS i; " \
    "CREATE INDEX events_kind_idx ON public.events (kind); ANALYZE public.events"
  ],
  "init_plan" => [
    [], "SELECT c.name FROM public.customers c " \
        "WHERE c.id = (SELECT o.customer_id FROM public.orders o WHERE o.total_cents = 5100 LIMIT 1)"
  ],
  "sub_plan" => [
    [], "SELECT c.name, (SELECT count(*) FROM public.orders o WHERE o.customer_id = c.id AND o.total_cents > 40000) " \
        "FROM public.customers c WHERE c.id < 200"
  ]
}.freeze

STATISTICS = <<~SQL
  SELECT 'reltuples', relname, reltuples::text FROM pg_class
   WHERE relname IN ('orders', 'customers') ORDER BY relname;
  SELECT 'pg_stats', tablename, attname, n_distinct, null_frac, correlation FROM pg_stats
   WHERE schemaname = 'public' AND tablename IN ('orders', 'customers') ORDER BY tablename, attname;
  SELECT 'indexdef', indexrelid::regclass, pg_get_indexdef(indexrelid) FROM pg_index
   WHERE indrelid IN ('public.orders'::regclass, 'public.customers'::regclass) ORDER BY 2::text;
SQL

def run(*command, stdin: nil)
  out, err, status = Open3.capture3(*command, stdin_data: stdin)
  raise "#{command.first(3).join(" ")} failed: #{err}" unless status.success?

  out
end

def psql(sql)
  run("docker", "exec", "-i", CONTAINER, "psql", "-U", "postgres", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
      stdin: sql)
end

def wait_for_postgres
  60.times do
    _, _, status = Open3.capture3("docker", "exec", CONTAINER, "pg_isready", "-U", "postgres")
    # pg_isready can pass during initdb's temporary server, so also run a query.
    return if status.success? && Open3.capture3("docker", "exec", CONTAINER, "psql", "-U", "postgres",
                                                "-c", "SELECT 1").last.success?

    sleep 1
  end
  raise "postgres didn't start"
end

begin
  run("docker", "run", "-d", "--rm", "--name", CONTAINER, "-e", "POSTGRES_HOST_AUTH_METHOD=trust",
      "postgres:18", "-c", "autovacuum=off")
  wait_for_postgres
  sleep 2
  psql(File.read(File.join(DIR, "sample.sql")))
  psql("ANALYZE;")

  PLANS.each do |name, (settings, query, setup)|
    sets = settings.map { |s| "SET LOCAL #{s};\n" }.join
    explain = name.end_with?("_verbose") ? VERBOSE_EXPLAIN : EXPLAIN
    json = psql("BEGIN;\n#{sets}#{setup && "#{setup};\n"}#{explain} #{query};\nROLLBACK;\n")
    File.write(File.join(DIR, "#{name}.json"), "#{JSON.pretty_generate(JSON.parse(json))}\n")
  end
  File.write(File.join(DIR, "statistics.txt"), psql(STATISTICS))
ensure
  Open3.capture3("docker", "rm", "-f", CONTAINER)
end
