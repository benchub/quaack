# frozen_string_literal: true

# Generates the LLM prompt pack in spec/fixtures/llm_corpus (task 20260922-65).
#
#   PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec ruby script/prompt_pack/run.rb [query ...]
#
# Docker must be running. For each query in QUERIES, or only those named, it
# starts from a throwaway harness Postgres (spec/support/test_postgres.rb),
# loads schema.sql and data.sql into a stand-in production
# database, captures the query's EXPLAIN ANALYZE, and runs the real enclave
# steps 1 to 4a, then the driver's Pipeline, over Transport::Local. The LLM
# client's transport is CapturingLLM: it writes down every prompt the driver
# sends, and answers with a small placeholder so the pipeline reaches its
# later LLM steps.
#
# Each prompt goes to <query>/<step>-<n>/prompt.md. If the enclave stops the
# run, stopped.md says where and why. Reply files in the pack are never
# touched. Last, every prompt file is scanned for the sentinels, the
# queries' literals, and the run fails if one shows up.
#
# It's not part of `rake`: it runs the whole pipeline four times.

require "bundler/setup"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/pipeline"
require "quaack/driver/transport/local"
require_relative "../../spec/support/test_postgres"
require_relative "../../enclave/spec/support/leak_check/sentinels"
require_relative "../../enclave/spec/support/leak_check/scanner"
require_relative "../../driver/spec/support/fake_llm"

module PromptPack
  ROOT = File.expand_path("../..", __dir__)
  HERE = __dir__
  CORPUS = File.join(ROOT, "spec", "fixtures", "llm_corpus")
  QUAACKS = [RbConfig.ruby, "-I", File.join(ROOT, "enclave", "lib"),
             File.join(ROOT, "enclave", "exe", "quaacks")].freeze
  # Lets quaacks run from this checkout, whose bundle holds the driver gem.
  ENV["QUAACKS_DEV_CHECKOUT"] = "1"

  # The queries' literals that must never reach a prompt, fixed so the pack
  # comes out the same on every run. Each is long enough for LeakCheck
  # (Sentinels::MIN_EXTRA). The date alone is checked too. The queries'
  # other literals, such as 'US' and 'shipped', are values of low-cardinality
  # columns that aren't on the PII list, which README 3f sends to the LLM
  # as most_common_vals by design, so they aren't sentinels.
  SINCE = "2024-03-17 08:00:00+00"
  UNTIL = "2024-05-29 20:00:00+00"
  BEFORE = "2024-06-11 13:45:00+00"
  BEFORE_ID = 777_777_777
  MIN_QUANTITY_SINCE = "2024-02-08 00:00:00+00"

  STAMPS = { since: SINCE, until: UNTIL, before: BEFORE, min_quantity_since: MIN_QUANTITY_SINCE }.freeze
  SENTINELS = STAMPS.merge(STAMPS.to_h { |k, v| [:"#{k}_date", v[0, 10]] }, before_id: BEFORE_ID).freeze

  # order is the query's ORDER BY over its output columns, for the 6a
  # placeholder rewrite (Placeholder.wrapped). bug is a [from, to] edit to
  # the 6a prompt's query text that makes the second, subtly wrong 6a
  # placeholder rewrite (Placeholder.buggy), so 10a has a real
  # counterexample to find.
  Query = Data.define(:name, :sql, :rewrites, :indexes, :order, :bug)

  QUERIES = [
    Query.new(
      name: "orm_join",
      sql: "SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o " \
           "JOIN public.users u ON u.id = o.user_id WHERE u.country = 'US' " \
           "AND o.created_at >= '#{SINCE}' AND o.created_at < '#{UNTIL}' ORDER BY o.created_at DESC LIMIT 50",
      rewrites: ["SELECT o.id, o.total_cents, o.created_at, u.email FROM public.orders o " \
                 "JOIN public.users u ON u.id = o.user_id AND u.country = $1 " \
                 "WHERE o.created_at >= $2 AND o.created_at < $3 ORDER BY o.created_at DESC LIMIT $4;"],
      indexes: ["CREATE INDEX ON public.users (name, id)", "CREATE INDEX ON orders (status)"],
      order: "created_at DESC",
      bug: ["WHERE u.country = $1", "WHERE u.country = $1 AND u.name IS NOT NULL"]
    ),
    Query.new(
      name: "group_having",
      sql: "SELECT o.user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o " \
           "WHERE o.status = 'shipped' GROUP BY o.user_id HAVING count(*) > 1 ORDER BY spent DESC",
      rewrites: ["SELECT o.user_id, count(*) AS order_count, sum(o.total_cents) AS spent FROM public.orders o " \
                 "WHERE o.status = $1 GROUP BY o.user_id HAVING count(o.id) > $2 ORDER BY spent DESC;"],
      indexes: ["CREATE INDEX ON public.orders (updated_at)", "CREATE INDEX ON orders (status)"],
      order: "spent DESC",
      bug: ["WHERE o.status = $1", "WHERE o.status = $1 AND o.total_cents >= 0"]
    ),
    Query.new(
      name: "correlated_exists",
      sql: "SELECT p.id, p.sku, p.name FROM public.products p WHERE p.category = 'kitchen' AND EXISTS " \
           "(SELECT 1 FROM public.line_items li JOIN public.orders o ON o.id = li.order_id " \
           "WHERE li.product_id = p.id AND o.created_at >= '#{MIN_QUANTITY_SINCE}' AND li.quantity >= 3) " \
           "ORDER BY p.id",
      rewrites: ["SELECT p.id, p.sku, p.name FROM public.products p WHERE p.category = $1 AND p.id IN " \
                 "(SELECT li.product_id FROM public.line_items li JOIN public.orders o ON o.id = li.order_id " \
                 "WHERE o.created_at >= $2 AND li.quantity >= $3) ORDER BY p.id;"],
      indexes: ["CREATE INDEX ON public.products (name)", "CREATE INDEX ON line_items (quantity)"],
      order: "id",
      bug: ["WHERE p.category = $1", "WHERE p.category = $1 AND p.sku <> p.name"]
    ),
    Query.new(
      name: "keyset_pagination",
      sql: "SELECT o.id, o.created_at, o.total_cents FROM public.orders o " \
           "WHERE (o.created_at, o.id) < ('#{BEFORE}', #{BEFORE_ID}) ORDER BY o.created_at DESC, o.id DESC LIMIT 25",
      rewrites: ["SELECT o.id, o.created_at, o.total_cents FROM public.orders o WHERE o.created_at <= $1 " \
                 "AND (o.created_at < $1 OR o.id < $2) ORDER BY o.created_at DESC, o.id DESC LIMIT $3;"],
      indexes: ["CREATE INDEX ON public.orders (updated_at)", "CREATE INDEX ON orders (created_at)"],
      order: "created_at DESC, id DESC",
      bug: ["o.id) < ($1, $2)", "o.id) < ($1, $2) AND o.updated_at <= o.created_at"]
    )
  ].freeze

  # FakeLLM, but it answers every ask with a placeholder made from the ask
  # itself, and keeps every ask for the pack.
  class CapturingLLM < FakeLLM
    def initialize(query)
      super()
      @query = query
    end

    def call(request, step:)
      reply(step, Placeholder.for(step, request.body, @query)) if @scripts[step].empty?
      super
    end
  end

  # The smallest valid answer to each step's ask that still lets the
  # pipeline go on to its later LLM steps.
  module Placeholder
    module_function

    # A first 5a-5 ask gets the query's indexes: one the planner won't use,
    # so 5a-6 gets asked, and one with an unqualified table, which is
    # dropped, so the replacement ask happens.
    def for(step, body, query)
      messages = body[:messages]
      first = messages.first[:content]
      case step
      when "5a-5" then { "indexes" => messages.size == 1 ? query.indexes : [] }
      when "5a-6" then { "indexes" => [] }
      when "6a" then { "rewrites" => [wrapped(first, query), buggy(first, query)] }
      when "step7" then { "rewrites" => Array.new(json_in(first)["rewrites"].size) { inferred } }
      when "10a" then { "inserts" => [] }
      else raise "no placeholder for step #{step}"
      end
    end

    # The query itself in a materialized CTE, so its plan differs from the
    # original's, and step 8 doesn't prune it. The outer query keeps the
    # order, so step 9 passes it, and 10a and step 11 get asked.
    def wrapped(content, query) = in_cte(json_in(content).fetch("query"), query)

    # The same wrapper around the query with query.bug applied: an extra
    # condition that looks harmless but drops rows real data can hold, the
    # kind of slip an LLM makes. It tests a column the original never
    # mentions, so step 9's fixtures, which give such columns a typical
    # value that passes it, don't catch it, and 10a gets asked to disprove
    # it. (A changed bound or a dropped condition on the original's own
    # atoms is caught at step 9.) The wrapper keeps step 8 from pruning it.
    def buggy(content, query)
      sql = json_in(content).fetch("query")
      from, to = query.bug
      raise "#{query.name}: #{from} isn't in the 6a query" unless sql.include?(from)

      in_cte(sql.sub(from, to), query)
    end

    def in_cte(sql, query)
      { "sql" => "WITH r AS MATERIALIZED (#{sql}) SELECT * FROM r ORDER BY #{query.order}",
        "transformation" => "placeholder", "assumptions" => [] }
    end

    def inferred = { "transformation" => "placeholder", "assumptions" => [] }

    def json_in(content) = JSON.parse(content[/```json\n(.*)\n```/m, 1])
  end

  module_function

  def main(names)
    queries = names.empty? ? QUERIES : QUERIES.select { names.include?(it.name) }
    abort "no such query: #{names.join(", ")}" if queries.empty?
    server = TestPostgres.server
    queries.each { run_query(server, it) }
    check_leaks
  end

  def run_query(server, query)
    puts "#{query.name}:"
    Dir.mktmpdir("quaack-prompt-pack") do |home|
      prod, racetrack = databases(server, query)
      with_env(home, server, prod) do
        write_pack(query, *pipeline(home, server, query, prod, racetrack))
      end
    ensure
      [prod, racetrack, "#{racetrack}_arena"].compact.each do |db|
        server.admin.exec(%(DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)))
      end
    end
  end

  def databases(server, query)
    prod = "pack_#{query.name}"
    racetrack = "#{prod}_racetrack"
    [prod, racetrack, "#{racetrack}_arena"].each { server.admin.exec(%(DROP DATABASE IF EXISTS "#{it}" WITH (FORCE))) }
    server.admin.exec(%(CREATE DATABASE "#{prod}" TEMPLATE template0))
    conn = PG.connect(host: server.host, port: server.port, dbname: prod, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec("CREATE EXTENSION hypopg")
    [File.read(File.join(HERE, "schema.sql")), File.read(File.join(HERE, "data.sql"))].each { conn.exec(it) }
    conn.exec("ANALYZE")
    conn.close
    server.admin.exec(%(CREATE DATABASE "#{racetrack}" TEMPLATE "#{prod}"))
    # The run server check refuses a server with other clients on it.
    server.close_admin
    [prod, racetrack]
  end

  # The enclave child reads libpq's variables for production and the run
  # server, and its HOME for the store and config.
  def with_env(home, server, prod)
    saved = ENV.to_h
    ENV.update("HOME" => home, "PGHOST" => server.host, "PGPORT" => server.port.to_s, "PGDATABASE" => prod,
               "PGUSER" => TestPostgres::USER, "PGPASSWORD" => TestPostgres::PASSWORD)
    yield
  ensure
    ENV.replace(saved)
  end

  def explain(server, prod, sql)
    conn = PG.connect(host: server.host, port: server.port, dbname: prod, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{sql}").column_values(0).join("\n")
  ensure
    conn&.close
  end

  # Runs the query through the enclave's steps 1 to 4a and the driver's
  # Pipeline. Returns the LLM asks, and nil or the EnclaveError that
  # stopped the run.
  def pipeline(home, server, query, prod, racetrack)
    transport = Quaack::Driver::Transport::Local.new(command: QUAACKS)
    run_id = intake(transport, home, server, query, prod)
    setup(transport, run_id, server, racetrack)
    llm = CapturingLLM.new(query)
    [llm.asks, run_pipeline(transport, llm, run_id, query, home)]
  rescue Quaack::Driver::EnclaveError => e
    puts "  stopped before any LLM step: #{e.message}"
    [[], e]
  end

  def run_pipeline(transport, llm, run_id, query, home)
    client = llm.client(burndown: Quaack::Driver::Burndown.new)
    Quaack::Driver::Pipeline.new(transport:, client:, run_id:, rewrites: query.rewrites,
                                 out: File.join(home, "report.html")).run
    puts "  ran to the report, #{llm.asks.size} LLM asks"
    nil
  rescue Quaack::Driver::EnclaveError => e
    puts "  stopped after #{llm.asks.size} LLM asks: #{e.message}"
    e
  end

  def intake(transport, home, server, query, prod)
    query_file = File.join(home, "query.sql").tap { File.write(it, query.sql) }
    plan_file = File.join(home, "plan.json").tap { File.write(it, explain(server, prod, query.sql)) }
    transport.call("intake", args: { query: query_file, plan: plan_file, server: server.host })
             .messages.find { it["type"] == "run" }.fetch("run_id")
  end

  SETUP = %w[inventory run-server qualify schema-dump statistics volatility classify redact literals anchor
             racetrack-setup].freeze

  def setup(transport, run_id, server, racetrack)
    SETUP.each do |step|
      args = { run: run_id }
      if step == "run-server"
        args.merge!("host" => server.host, "port" => server.port.to_s, "racetrack-db" => racetrack,
                    "arena-db" => "#{racetrack}_arena")
      end
      transport.call(step, args:)
    end
  end

  def write_pack(query, asks, error)
    dir = File.join(CORPUS, query.name)
    FileUtils.mkdir_p(dir)
    stopped = File.join(dir, "stopped.md")
    error ? File.write(stopped, stopped(error, asks.size)) : FileUtils.rm_f(stopped)
    counts = Hash.new(0)
    rewrites = false
    kept = asks.map do |ask|
      # 5a asks after 6a are step 11's, for the surviving rewrites.
      rewrites ||= ask.step == "6a"
      step = rewrites && ask.step.start_with?("5a-") ? "step11-#{ask.step}" : ask.step
      name = "#{step}-#{counts[step] += 1}"
      FileUtils.mkdir_p(File.join(dir, name))
      File.write(File.join(dir, name, "prompt.md"), prompt(ask))
      chat_file = File.join(dir, name, "chat.md")
      (chat = chat(ask)) ? File.write(chat_file, chat) : FileUtils.rm_f(chat_file)
      name
    end
    prune(dir, kept)
  end

  # Removes step directories this run didn't ask for, unless they hold
  # replies, which it only warns about.
  def prune(dir, kept)
    (Dir.children(dir).select { File.directory?(File.join(dir, it)) } - kept).each do |name|
      path = File.join(dir, name)
      if (Dir.children(path) - ["chat.md"]) == ["prompt.md"]
        FileUtils.rm_rf(path)
      else
        warn "  #{path} holds replies but wasn't asked this time; left alone"
      end
    end
  end

  def stopped(error, asks)
    where = if asks.zero?
              "before any LLM step, so this query has no prompts"
            else
              "after #{asks} LLM asks. Their prompts are here, and any later steps' are missing"
            end
    <<~MD
      # Stopped

      The pipeline stopped #{where}.

      - Step: `#{error.subcommand}`
      - Rule: `#{error.rule}`

      Regenerate the pack once the enclave gets past it.
    MD
  end

  def prompt(ask)
    body = ask.body
    parts = ["# System\n\n#{text(body[:system]).strip}\n"]
    body[:messages].each do |message|
      parts << "# #{message[:role].to_s.capitalize}\n\n#{text(message[:content]).strip}\n"
    end
    parts << reply_format(body)
    parts.join("\n")
  end

  # A chat window can't take an assistant turn, so for a prompt with more
  # than one user turn this folds the earlier exchange into one message
  # that quotes it plainly. It's nil for a single-turn prompt.
  def chat(ask)
    body = ask.body
    *earlier, last = body[:messages]
    return nil if earlier.empty?

    quoted = earlier.map do |message|
      label = message[:role].to_s == "assistant" ? "Your reply:" : "You were asked:"
      "#{label}\n\n#{text(message[:content]).strip}\n"
    end
    ["# System\n\n#{text(body[:system]).strip}\n",
     "# Message\n\nEarlier in this conversation you were asked the following, and you replied as shown. " \
     "Treat that reply as your own.\n",
     *quoted, "Now:\n\n#{text(last[:content]).strip}\n", reply_format(body)].join("\n")
  end

  def reply_format(body)
    "# Reply format\n\nReply with only JSON matching this schema:\n\n```json\n" \
      "#{JSON.pretty_generate(body.dig(:output_config, :format, :schema))}\n```\n"
  end

  def text(value)
    return value if value.is_a?(String)

    Array(value).map { it.is_a?(Hash) ? it[:text] : it.to_s }.join
  end

  def check_leaks
    sentinels = LeakCheck::Sentinels.new(extra: SENTINELS)
    files = Dir.glob(File.join(CORPUS, "*", "**", "*.md"))
    found = files.flat_map { |f| LeakCheck.findings(sentinels, objects: { f => File.read(f) }) }
    abort "sentinels leaked into the pack:\n#{found.map { "  #{it}" }.join("\n")}" unless found.empty?
    puts "#{files.size} files, no sentinel in any"
  end
end

PromptPack.main(ARGV) if $PROGRAM_NAME == __FILE__
