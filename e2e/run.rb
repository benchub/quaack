# frozen_string_literal: true

# Runs the real QUAACK pipeline end to end over the e2e corpus (task
# 20260926-58) and judges each case's claim.
#
#   PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec ruby e2e/run.rb [prefix ...]
#
# Docker must be running. For each case in e2e/cases, or only those whose
# directory starts with a prefix given, it loads schema.sql into a stand-in
# production database on a throwaway harness Postgres
# (spec/support/test_postgres.rb), captures slow.sql's EXPLAIN ANALYZE, runs
# the enclave's intake through racetrack-setup over Transport::Local, then
# the driver's Pipeline, with a fake LLM (CaseLLM) behind the real client.
# Last it reads the run's report payload and judges the case:
#
# - refused: intake must refuse with the rule results.md names
# - index: the top-ranked fix must exist, and touch at most the case's bound
#   of total blocks on the slow literals. One whose own index comes from
#   the LLM (5a-5) and misses is LLM, not FAIL.
# - rewrite, both, trap, none: these need the LLM, so the outcome is only
#   recorded, but a crash or a stopped run still fails
#
# It prints a summary table and writes it to e2e/RUN.md (the table only,
# below RUN.md's hand-written notes marker, which it keeps). It's not part
# of `rake`: it runs the whole pipeline once per case.

require "bundler/setup"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/pipeline"
require "quaack/driver/transport/local"
require_relative "../spec/support/test_postgres"
require_relative "../spec/support/test_pg_dump"
require_relative "../driver/spec/support/fake_llm"

module E2ERun
  ROOT = File.expand_path("..", __dir__)
  CASES = File.join(__dir__, "cases")
  RUN_MD = File.join(__dir__, "RUN.md")
  NOTES = "<!-- notes: kept by run.rb -->"
  QUAACKS = [RbConfig.ruby, "-I", File.join(ROOT, "enclave", "lib"),
             File.join(ROOT, "enclave", "exe", "quaacks")].freeze
  # Lets quaacks run from this checkout, whose bundle holds the driver gem.
  ENV["QUAACKS_DEV_CHECKOUT"] = "1"
  SETUP = %w[inventory run-server qualify schema-dump statistics volatility classify redact literals anchor
             racetrack-setup].freeze

  Result = Data.define(:name, :category, :verdict, :detail, :seconds)

  # The fake LLM. Every ask gets a valid empty answer, unless replies has
  # one for the step. That's the seam for replaying spec/fixtures/llm_corpus
  # later: pass a replies object whose `for(step, body)` returns the
  # recorded answer (a Hash, or nil to fall back to the empty one).
  class CaseLLM < FakeLLM
    NO_REPLIES = Object.new.tap { |o| o.define_singleton_method(:for) { |*| nil } }

    def initialize(replies: NO_REPLIES)
      super()
      @replies = replies
    end

    def call(request, step:)
      reply(step, @replies.for(step, request.body) || empty(step, request.body)) if @scripts[step].empty?
      super
    end

    def empty(step, body)
      case step
      when "5a-5", "5a-6" then { "indexes" => [] }
      when "6a" then { "rewrites" => [] }
      when "step7"
        content = body[:messages].first[:content]
        n = JSON.parse(content[/```json\n(.*)\n```/m, 1])["rewrites"].size
        { "rewrites" => Array.new(n) { { "transformation" => "none", "assumptions" => [] } } }
      when "10a" then { "inserts" => [] }
      else raise "no empty answer for step #{step}"
      end
    end
  end

  # One case directory.
  class Case
    attr_reader :dir, :name

    def initialize(dir)
      @dir = dir
      @name = File.basename(dir)
    end

    def meta = @meta ||= JSON.parse(read("case.json"))
    def category = meta.fetch("category")
    def read(file) = File.read(File.join(dir, file))
    def settings = meta.fetch("settings", {}).map { |k, v| "SET #{k} = #{v};" }.join
    def results = read("results.md")
    def bound = results[/must touch at most (\d+) total blocks/, 1]&.to_i
    def refusal_rule = results[/must refuse the query with `([a-z_]+)`/, 1]
    def llm_index? = meta.fetch("features").any? { it.match?(/5a-[56]|set aside untested/) }
    def database = "e2e_#{name[0, 3]}"
  end

  module_function

  def main(prefixes)
    cases = Dir.children(CASES).sort.map { Case.new(File.join(CASES, it)) }
    cases = cases.select { |c| prefixes.any? { c.name.start_with?(it) } } unless prefixes.empty?
    abort "no such case: #{prefixes.join(", ")}" if cases.empty?
    server = TestPostgres.server
    results = cases.map do |kase|
      run_case(server, kase).tap { puts format_row(it) }
    end
    table = summary(results)
    puts table
    write_run_md(table) if prefixes.empty?
    exit 1 if results.any? { %w[CRASH FAIL].include?(it.verdict) }
  end

  def run_case(server, kase)
    started = now
    verdict, detail = in_home(kase) do |home|
      prod, racetrack = databases(server, kase)
      with_env(home, server, prod) { judge(kase, outcome(home, server, kase, prod, racetrack)) }
    ensure
      drop_all(server, kase)
    end
    Result.new(kase.name, kase.category, verdict, detail, (now - started).round)
  rescue StandardError => e
    Result.new(kase.name, kase.category, "CRASH", "#{e.class}: #{e.message.lines.first&.strip}", (now - started).round)
  end

  # QUAACK_E2E_KEEP=1 keeps each case's HOME, which holds the run's store,
  # for diagnosing a failure.
  def in_home(kase, &)
    return Dir.mktmpdir("quaack-e2e", &) unless ENV["QUAACK_E2E_KEEP"]

    home = Dir.mktmpdir("quaack-e2e-#{kase.name[0, 3]}-")
    warn "  keeping #{home}"
    yield home
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def drop_all(server, kase)
    server.admin.exec("SET client_min_messages = warning")
    %W[#{kase.database} #{kase.database}_racetrack #{kase.database}_racetrack_arena].each do |db|
      server.admin.exec(%(DROP DATABASE IF EXISTS "#{db}" WITH (FORCE)))
    end
  end

  # schema.sql runs VACUUM, so it goes through psql, not one exec.
  def databases(server, kase)
    drop_all(server, kase)
    prod = kase.database
    racetrack = "#{prod}_racetrack"
    server.admin.exec(%(CREATE DATABASE "#{prod}" TEMPLATE template0))
    psql(server, prod, "CREATE EXTENSION hypopg;\n#{kase.read("schema.sql")}")
    # The harness server runs with synchronous_commit off, so VACUUM can't
    # mark a page all-visible until the WAL writer has flushed the loading
    # transaction's commit. Whether it had was a race: relallvisible came out
    # 0 or full from one load to the next, the planner priced index-only
    # scans differently, and the top fix changed between runs (20260927-6).
    # CHECKPOINT flushes the WAL first, so the VACUUM after it always sets
    # the visibility map, as on production and verify.rb's server.
    psql(server, prod, "CHECKPOINT; VACUUM;")
    # A case's settings are production's own (DESIGN.md step 2 records the
    # server's value, not the plan session's), so they go on the databases,
    # and the racetrack gets them too, as a run server configured like
    # production would (step 4 checks it).
    server.admin.exec(%(CREATE DATABASE "#{racetrack}" TEMPLATE "#{prod}"))
    kase.meta.fetch("settings", {}).each do |k, v|
      [prod, racetrack].each { server.admin.exec(%(ALTER DATABASE "#{it}" SET #{k} = #{v})) }
    end
    server.close_admin
    [prod, racetrack]
  end

  def psql(server, db, sql)
    out, status = Open3.capture2e("docker", "exec", "-i", server.container_id, "psql", "-U", TestPostgres::USER,
                                  "-d", db, "-X", "-q", "-v", "ON_ERROR_STOP=1", stdin_data: sql)
    raise "psql failed on #{db}: #{out.lines.last(3).join}" unless status.success?
  end

  # The quaacks child's PATH starts with a pg_dump of the server's major
  # version, for schema-dump (TestPgDump).
  def with_env(home, server, prod)
    saved = ENV.to_h
    pg_bin = TestPgDump.bin
    ENV.update("HOME" => home, "PGHOST" => server.host, "PGPORT" => server.port.to_s, "PGDATABASE" => prod,
               "PGUSER" => TestPostgres::USER, "PGPASSWORD" => TestPostgres::PASSWORD,
               "PATH" => "#{pg_bin}:#{ENV.fetch("PATH")}")
    yield
  ensure
    ENV.replace(saved)
  end

  def explain(server, prod, kase)
    conn = PG.connect(host: server.host, port: server.port, dbname: prod, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec(kase.settings) unless kase.settings.empty?
    conn.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{kase.read("slow.sql")}").column_values(0).join
  ensure
    conn&.close
  end

  # What happened: { stage:, error:, report:, asks: }. stage is where it
  # stopped: :intake, :setup, :pipeline, or :done.
  def outcome(home, server, kase, prod, racetrack)
    transport = Quaack::Driver::Transport::Local.new(command: QUAACKS)
    stage = :intake
    run_id = intake(transport, home, server, kase, prod)
    stage = :setup
    setup(transport, run_id, server, racetrack)
    stage = :pipeline
    llm = CaseLLM.new
    Quaack::Driver::Pipeline.new(transport:, client: llm.client(burndown: Quaack::Driver::Burndown.new), run_id:,
                                 out: File.join(home, "report.html")).run
    report = transport.call("report-payload", args: { run: run_id }).messages.find { it["type"] == "report" }
    { stage: :done, report:, asks: llm.asks.map(&:step) }
  rescue Quaack::Driver::EnclaveError => e
    { stage:, error: e, asks: llm ? llm.asks.map(&:step) : [] }
  end

  def intake(transport, home, server, kase, prod)
    query_file = File.join(home, "query.sql").tap { File.write(it, kase.read("slow.sql")) }
    plan_file = File.join(home, "plan.json").tap { File.write(it, explain(server, prod, kase)) }
    transport.call("intake", args: { query: query_file, plan: plan_file, server: server.host })
             .messages.find { it["type"] == "run" }.fetch("run_id")
  end

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

  def describe_error(out)
    e = out[:error]
    parts = ["stopped at #{e.subcommand}", "rule #{e.rule}"]
    parts << "step #{e.step}" if e.step
    parts << "SQLSTATE #{e.sqlstate}" if e.sqlstate
    parts.join(", ")
  end

  def top_fix(report) = report&.fetch("top", [])&.first

  def judge(kase, out)
    return judge_refused(kase, out) if kase.category == "refused"
    return ["FAIL", describe_error(out)] if out[:error]

    top = top_fix(out[:report])
    return ["INFO", "#{shown(top, out[:report])}; needs the LLM"] unless kase.category == "index"

    judge_index(kase, top, shown(top, out[:report]))
  end

  def judge_index(kase, top, shown)
    return ["PASS", "#{shown} <= bound #{kase.bound}"] if top && top["slow_blocks"] <= kase.bound

    miss = top ? "#{shown} > bound #{kase.bound}" : "#{shown}, bound #{kase.bound}"
    kase.llm_index? ? ["LLM", "#{miss}; the case's index comes from the LLM (5a-5)"] : ["FAIL", miss]
  end

  def shown(top, report)
    top ? "top #{top["label"]} #{top["slow_blocks"]} blocks" : "no fix selected (#{why_none(report)})"
  end

  # Why the report has no fix, from its negative section (DESIGN.md 15a)
  # and each rewrite's fate.
  def why_none(report)
    negative = report["negative"] || {}
    parts = { "declined" => Array(negative["declined"]).map { it["reason"] },
              "existing" => Array(negative["existing"]).map { "covered" },
              "rewrites" => Array(report["rewrites"]).map { it["fate"] } }
    text = parts.reject { _2.empty? }.map { |k, v| "#{k}: #{v.tally.map { |r, n| "#{r} #{n}" }.join(" ")}" }
    text.empty? ? "no candidates" : text.join("; ")
  end

  def judge_refused(kase, out)
    want = kase.refusal_rule
    return ["FAIL", "intake accepted the query; wanted #{want}"] unless out[:error] && out[:stage] == :intake
    return ["PASS", "refused with #{want}"] if out[:error].rule == want

    ["FAIL", "#{describe_error(out)}; wanted #{want}"]
  end

  def format_row(res) = "| #{res.name} | #{res.category} | #{res.verdict} | #{res.detail} | #{res.seconds} |"

  def summary(results)
    counts = results.map(&:verdict).tally.sort.map { |v, n| "#{v} #{n}" }.join(", ")
    ["| Case | Category | Verdict | Detail | Seconds |", "| --- | --- | --- | --- | ---: |",
     *results.map { format_row(it) }, "", "#{results.size} cases: #{counts}."].join("\n")
  end

  def write_run_md(table)
    notes = File.exist?(RUN_MD) ? File.read(RUN_MD).split(NOTES, 2)[1] : nil
    File.write(RUN_MD, <<~MD + "\n#{NOTES}#{notes || "\n"}")
      # E2E run.

      Generated by `ruby e2e/run.rb` (a full run). The fake LLM gives every
      ask a valid empty answer, so only `refused` and `index` claims are
      judged. Other categories are recorded as INFO.

      #{table}
    MD
  end
end

E2ERun.main(ARGV) if $PROGRAM_NAME == __FILE__
