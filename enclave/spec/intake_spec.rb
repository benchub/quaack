# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "time"
require "tmpdir"
require "quaack/enclave/cli"
require "quaack/enclave/store"

# The production inputs of the fixture below hold these literals. They stand
# in for real values, which must never leave the enclave. They're baked
# into the plan fixture, so they're fixed rather than made by
# LeakCheck::Sentinels.
INTAKE_SENTINELS = %w[quaack-sentinel-email quaack-sentinel-name].freeze
# One more, planted in each bad input and each path.
INTAKE_SENTINEL = "sentinel-5b17c0-ssn"

# `quaacks intake` (DESIGN.md's input), run through the real CLI and its real
# steps table, with a temporary store base.
RSpec.describe "quaacks intake" do
  let(:dir) { Dir.mktmpdir("quaack-intake") }
  let(:base) { File.join(dir, "runs") }
  let(:out) { StringIO.new }
  let(:sentinels) do
    LeakCheck::Sentinels.new(extra: { email: INTAKE_SENTINELS[0], name: INTAKE_SENTINELS[1], planted: INTAKE_SENTINEL })
  end
  # A real EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON), captured from
  # the test harness by fixtures/plans/capture.rb, and its query.
  let(:plan_text) { File.read(File.join(__dir__, "fixtures", "plans", "sentinel_literals.json")) }
  let(:query_text) do
    "SELECT c.id FROM public.customers c WHERE c.email = 'quaack-sentinel-email' AND c.name = 'quaack-sentinel-name'"
  end
  let(:query_file) { file("q.sql", query_text) }
  let(:plan_file) { file("plan.json", plan_text) }

  after { FileUtils.rm_rf(dir) }

  def file(name, contents)
    path = File.join(dir, name)
    File.binwrite(path, contents)
    path
  end

  def intake(*args)
    Quaack::Enclave::CLI.new(stdin: StringIO.new, out:, store_base: base).run(["intake", *args])
  end

  def intake_with(query: query_file, plan: plan_file, server: "prod-db-3", extra: [])
    intake("--query", query, "--plan", plan, "--server", server, *extra)
  end

  def runs = File.directory?(base) ? Dir.children(base) : []

  def error_line(rule, reason: nil)
    fields = { "type" => "error", "step" => "intake", "rule" => rule }
    fields["reason"] = reason if reason
    "#{JSON.generate(fields)}\n"
  end

  def only_run = Quaack::Enclave::Store.open(runs.fetch(0), base:)

  # Every refusal: exit 70, only the rule, no sentinel or production
  # literal, and no run left behind.
  def expect_refused(rule, status, why = nil, reason: nil)
    expect(out.string).to eq(error_line(rule, reason:)), why
    expect(status).to eq(70), why
    expect_no_leaks(sentinels, stdout: out.string, why:)
    expect(runs).to eq([]), why
  end

  def refuses_query(text, rule)
    out.truncate(0) && out.rewind
    expect_refused(rule, intake_with(query: file("bad.sql", text)), "query #{text.inspect}")
  end

  def refuses_plan(text, rule)
    out.truncate(0) && out.rewind
    expect_refused(rule, intake_with(plan: file("bad.json", text)), "plan #{text[0, 200].inspect}")
  end

  describe "the store base" do
    # The link's target is named for a sentinel, so a line that named it
    # would show.
    it "fails as bad_store_base, starting no run, when the store base is a symlink or a file" do
      target = File.join(dir, INTAKE_SENTINEL).tap { Dir.mkdir(it, 0o700) }
      File.symlink(target, base)
      expect_refused("bad_store_base", intake_with, "linked")
      expect(Dir.children(target)).to eq([])

      File.unlink(base)
      File.write(base, INTAKE_SENTINEL)
      out.truncate(0) && out.rewind
      expect(intake_with).to eq(70)
      expect(out.string).to eq(error_line("bad_store_base"))
      expect(File.read(base)).to eq(INTAKE_SENTINEL)
    end
  end

  describe "good inputs" do
    it "creates a run holding the inputs and prints only its run ID and the done line" do
      expect(intake_with).to eq(0)

      expect(runs.size).to eq(1)
      expect(out.string).to eq(%({"type":"run","run_id":"#{runs[0]}"}\n{"type":"done"}\n))
      store = only_run
      expect(store.read("query")).to eq(query_text)
      expect(store.read("plan")).to eq(JSON.parse(plan_text))
      expect(store.read("server")).to eq("prod-db-3")
    end

    # The sentinel check itself: the literals are in what the run holds, so
    # a scan of the output for them would find them if they got out.
    it "keeps the production literals in the run and out of the output" do
      expect(intake_with).to eq(0)

      stored = Dir.children(only_run.path).map { File.read(File.join(only_run.path, it)) }.join
      INTAKE_SENTINELS.each { expect(stored).to include(it) }
      expect_no_leaks(sentinels, stdout: out.string)
    end

    it "anchors the clock at the time of intake, in UTC, without --captured-at" do
      before = Time.now
      expect(intake_with).to eq(0)
      after = Time.now

      anchor = only_run.read("clock_anchor")
      expect(anchor).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/)
      expect(Time.iso8601(anchor)).to be_between(before.floor(6), after)
    end

    it "anchors the clock at --captured-at, in UTC to the microsecond" do
      {
        "2026-09-23T22:15:00Z" => "2026-09-23T22:15:00.000000Z",
        "2026-09-23T15:15:00-07:00" => "2026-09-23T22:15:00.000000Z",
        "2026-09-24T00:15:00.5+02:00" => "2026-09-23T22:15:00.500000Z",
        "2026-09-23T22:15:00.123456789Z" => "2026-09-23T22:15:00.123456Z",
        "2024-02-29T23:59:59.999999+00:00" => "2024-02-29T23:59:59.999999Z"
      }.each do |given, stored|
        FileUtils.rm_rf(base)
        expect(intake_with(extra: ["--captured-at", given])).to eq(0), given
        expect(only_run.read("clock_anchor")).to eq(stored), given
      end
    end

    it "accepts server names made of letters, digits, dots, hyphens, and underscores" do
      ["prod-db-3", "db3.internal.example.com", "Prod_DB", "a", "a" * 253].each do |server|
        FileUtils.rm_rf(base)
        expect(intake_with(server:)).to eq(0), server
        expect(only_run.read("server")).to eq(server)
      end
    end

    it "accepts a plan with no Settings key" do
      plan = JSON.parse(plan_text)
      plan[0].delete("Settings")

      expect(intake_with(plan: file("plan.json", JSON.generate(plan)))).to eq(0)
      expect(only_run.read("plan")).to eq(plan)
    end

    it "accepts a plan from ANALYZE with TIMING OFF, which has Actual Rows but no Actual Total Time" do
      plan = JSON.parse(plan_text)
      plan[0]["Plan"].delete("Actual Total Time")
      plan[0]["Plan"].delete("Actual Startup Time")

      expect(intake_with(plan: file("plan.json", JSON.generate(plan)))).to eq(0)
    end

    it "keeps a query's comments and layout as given" do
      text = "-- slow report\nSELECT c.id\n  FROM public.customers c /* hint */\n WHERE c.id = 1;\n"

      expect(intake_with(query: file("q.sql", text))).to eq(0)
      expect(only_run.read("query")).to eq(text)
    end
  end

  describe "options" do
    it "refuses a missing --query, --plan, or --server as usage, and leaves no run" do
      [%w[--plan p --server s], %w[--query q --server s], %w[--query q --plan p], []].each do |args|
        out.truncate(0) && out.rewind
        args = args.map { |a| { "q" => query_file, "p" => plan_file }.fetch(a, a) }

        expect(intake(*args)).to eq(64), args.inspect
        expect(out.string).to eq(error_line("usage")), args.inspect
        expect(runs).to eq([])
      end
    end

    it "refuses an option it doesn't declare, such as --run, as usage" do
      expect(intake_with(extra: %w[--run 20260923T221500Z-0a1b2c3d])).to eq(64)
      expect(out.string).to eq(error_line("usage"))
      expect(runs).to eq([])
    end

    # A base under a regular file can't be made, so a run made before the
    # arguments were checked would fail as internal_error instead.
    it "checks its arguments before it makes a run" do
      blocked = File.join(file("not-a-directory", ""), "runs")
      [%w[--bogus], %w[--query q --plan p], %W[--query #{query_file} --plan #{plan_file} --server]].each do |args|
        out.truncate(0) && out.rewind
        cli = Quaack::Enclave::CLI.new(stdin: StringIO.new, out:, store_base: blocked)

        expect(cli.run(["intake", *args])).to eq(64), args.inspect
        expect(out.string).to eq(error_line("usage")), args.inspect
      end
    end
  end

  describe "the server name" do
    it "refuses anything but a hostname-like name of up to 253 characters as bad_server" do
      ["", "-prod", ".prod", "prod db", "prod;db", "prod/db", "prod\n", "prödb", "prod\xffdb", "a" * 254,
       "#{INTAKE_SENTINEL} x"].each do |server|
        out.truncate(0) && out.rewind
        expect_refused("bad_server", intake_with(server:), server.inspect)
      end
    end
  end

  describe "--port" do
    it "stores production's port as an Integer in production_port" do
      %w[1 6543 65535].each do |port|
        FileUtils.rm_rf(base)
        expect(intake_with(extra: ["--port", port])).to eq(0), port
        expect(out.string).to eq(%({"type":"run","run_id":"#{runs[0]}"}\n{"type":"done"}\n))
        expect(only_run.read("production_port")).to eq(Integer(port))
        out.truncate(0) && out.rewind
      end
    end

    it "stores no production_port without --port, so libpq's setup picks the port" do
      expect(intake_with).to eq(0)
      expect(only_run.entry?("production_port")).to be(false)
    end

    it "refuses anything but a whole number from 1 to 65535 as bad_port" do
      ["", "0", "65536", "-1", "+5432", " 5432", "5432\n", "54a", "05432", "５４３２", "\xff", "54\xff32",
       "5432".encode("UTF-16LE"), INTAKE_SENTINEL].each do |port|
        out.truncate(0) && out.rewind
        expect_refused("bad_port", intake_with(extra: ["--port", port]), port.inspect)
      end
    end

    it "refuses --port twice, or without a value, as usage" do
      [["--port", "5433", "--port", "5434"], ["--port"]].each do |extra|
        out.truncate(0) && out.rewind
        expect(intake_with(extra:)).to eq(64), extra.inspect
        expect(runs).to eq([])
      end
    end
  end

  describe "--captured-at" do
    it "refuses anything but an ISO-8601 time with a zone as bad_captured_at" do
      ["2026-09-23T22:15:00", "2026-09-23 22:15:00Z", "2026-09-23", "2026-09-23T22:15Z", "1790000000",
       "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-09-23T24:00:00Z", "2026-09-23T23:60:00Z",
       "2026-09-23T23:59:60Z", "2026-09-23T22:15:00+24:00", "2026-09-23T22:15:00+02:60",
       "2026-09-23T22:15:00+0200", "2026-09-23T22:15:00.Z", "now", "", " 2026-09-23T22:15:00Z",
       "2026-09-23T22:15:00Z\n", "2026-09-23T22:15:00\xffZ", "2026-09-23\xffT22:15:00Z",
       INTAKE_SENTINEL].each do |time|
        out.truncate(0) && out.rewind
        expect_refused("bad_captured_at", intake_with(extra: ["--captured-at", time]), time.inspect)
      end
    end

    # Postgres can't hold a year past 9999 or before 1 AD as written, and
    # a plan from before 1970 or from the future is a mistake.
    it "refuses a time before 1970, in UTC, as bad_captured_at" do
      ["1969-12-31T23:59:59.999999Z", "1970-01-01T00:30:00+01:00", "0000-01-01T00:00:00+01:00",
       "0001-01-01T00:00:00Z"].each do |time|
        out.truncate(0) && out.rewind
        expect_refused("bad_captured_at", intake_with(extra: ["--captured-at", time]), time)
      end

      ["1970-01-01T00:00:00Z", "1970-01-01T01:00:00+01:00"].each do |time|
        FileUtils.rm_rf(base)
        expect(intake_with(extra: ["--captured-at", time])).to eq(0), time
        expect(only_run.read("clock_anchor")).to eq("1970-01-01T00:00:00.000000Z")
      end
    end

    it "refuses a time more than one day after intake as bad_captured_at" do
      iso = ->(time) { time.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ") }
      [iso.call(Time.now + 86_400 + 60), "9999-12-31T23:00:00Z", "9999-12-31T23:00:00-05:00"].each do |time|
        out.truncate(0) && out.rewind
        expect_refused("bad_captured_at", intake_with(extra: ["--captured-at", time]), time)
      end

      near = iso.call(Time.now + 86_400 - 60)
      FileUtils.rm_rf(base)
      expect(intake_with(extra: ["--captured-at", near])).to eq(0)
      expect(only_run.read("clock_anchor")).to eq(near)
    end
  end

  describe "reading the files" do
    it "expands a leading ~/ on the jump server, but not ~otheruser/" do
      jump_home = File.join(dir, "jump-home").tap { Dir.mkdir(it) }
      nested = File.join(jump_home, "q").tap { Dir.mkdir(it) }
      File.binwrite(File.join(nested, "query.sql"), query_text)
      File.binwrite(File.join(nested, "plan.json"), plan_text)
      allow(Dir).to receive(:home).and_return(jump_home)

      expect(intake_with(query: "~/q/query.sql", plan: "~/q/plan.json")).to eq(0)
      expect(only_run.read("query")).to eq(query_text)

      FileUtils.rm_rf(base)
      out.truncate(0) && out.rewind
      expect_refused("query_unreadable", intake_with(query: "~otheruser/q/query.sql"), "~otheruser",
                     reason: "missing")
    end

    it "refuses a bare ~ as a directory, because it expands to the jump server user's home" do
      jump_home = File.join(dir, "jump-home").tap { Dir.mkdir(it) }
      allow(Dir).to receive(:home).and_return(jump_home)

      expect_refused("query_unreadable", intake_with(query: "~"), "bare ~", reason: "not_regular_file")
    end

    it "says why a missing path, directory, symlink, or FIFO is query_unreadable or plan_unreadable" do
      missing = File.join(dir, "#{INTAKE_SENTINEL}-missing")
      directory = File.join(dir, "#{INTAKE_SENTINEL}-dir").tap { Dir.mkdir(it) }
      fifo = File.join(dir, "#{INTAKE_SENTINEL}-fifo").tap { File.mkfifo(it) }
      query_link = File.join(dir, "#{INTAKE_SENTINEL}-q-link").tap { File.symlink(query_file, it) }
      plan_link = File.join(dir, "#{INTAKE_SENTINEL}-p-link").tap { File.symlink(plan_file, it) }

      [missing, directory, fifo, query_link].each do |path|
        out.truncate(0) && out.rewind
        reason = { missing => "missing", directory => "not_regular_file", fifo => "not_regular_file",
                   query_link => "symlink" }.fetch(path)
        expect_refused("query_unreadable", intake_with(query: path), path, reason:)
      end
      [missing, directory, fifo, plan_link].each do |path|
        out.truncate(0) && out.rewind
        reason = { missing => "missing", directory => "not_regular_file", fifo => "not_regular_file",
                   plan_link => "symlink" }.fetch(path)
        expect_refused("plan_unreadable", intake_with(plan: path), path, reason:)
      end
    end

    # Task 20261003-7: a path through a regular file (ENOTDIR) is missing,
    # since no such file can be there.
    it "says a path whose parent is a regular file is missing" do
      expect_refused("query_unreadable", intake_with(query: File.join(plan_file, "q.sql")), reason: "missing")
      out.truncate(0) && out.rewind
      expect_refused("plan_unreadable", intake_with(plan: File.join(query_file, "p.json")), reason: "missing")
    end

    it "refuses a file it can't read as unreadable" do
      File.chmod(0o000, query_file)
      File.chmod(0o000, plan_file)

      expect_refused("query_unreadable", intake_with(plan: file("p2.json", plan_text)), reason: "permission_denied")
      out.truncate(0) && out.rewind
      expect_refused("plan_unreadable", intake_with(query: file("q2.sql", query_text)), reason: "permission_denied")
    end

    it "reads a file of up to 16 MB and refuses a bigger one as query_too_large or plan_too_large" do
      max = 16 * 1024 * 1024
      padded_query = "#{query_text}\n--#{"x" * (max - query_text.bytesize - 3)}"
      expect(padded_query.bytesize).to eq(max)
      expect(intake_with(query: file("big.sql", padded_query))).to eq(0)
      FileUtils.rm_rf(base)

      refuses_query("#{padded_query}x", "query_too_large")
      refuses_plan("#{plan_text}#{" " * (max + 1 - plan_text.bytesize)}", "plan_too_large")
      expect(intake_with(plan: file("big.json", plan_text + (" " * (max - plan_text.bytesize))))).to eq(0)
    end

    it "refuses a plan of more than CLI::Input::MAX_ELEMENTS elements as plan_too_large" do
      elements = Quaack::Enclave::CLI::Input::MAX_ELEMENTS
      plan = JSON.parse(plan_text)
      plan[0]["Sentinel"] = [INTAKE_SENTINEL, *Array.new(elements, 0)]

      refuses_plan(JSON.generate(plan), "plan_too_large")
    end
  end

  describe "the query" do
    it "refuses text that isn't UTF-8, or that holds a NUL, as query_not_text" do
      refuses_query("SELECT '#{INTAKE_SENTINEL}\xff'".b, "query_not_text")
      refuses_query("SELECT 1\0; SELECT '#{INTAKE_SENTINEL}'", "query_not_text")
    end

    it "strips one leading byte order mark, and keeps the rest as given" do
      expect(intake_with(query: file("q.sql", "﻿#{query_text}"))).to eq(0)
      expect(only_run.read("query")).to eq(query_text)

      FileUtils.rm_rf(base)
      refuses_query("﻿﻿#{query_text}", "query_unparsable")
    end

    it "refuses a query with $n parameters as query_has_parameters" do
      ["SELECT c.id FROM public.customers c WHERE c.email = $1 AND c.name = '#{INTAKE_SENTINEL}'",
       "SELECT '#{INTAKE_SENTINEL}' FROM t WHERE a IN (SELECT b FROM u WHERE c = $2)"].each do |sql|
        refuses_query(sql, "query_has_parameters")
      end
    end

    it "refuses text pg_query can't parse as query_unparsable" do
      refuses_query("SELECT '#{INTAKE_SENTINEL}' FROM WHERE", "query_unparsable")
      refuses_query("SELECT '#{INTAKE_SENTINEL}", "query_unparsable")
    end

    it "refuses anything but exactly one statement as query_not_one_statement" do
      refuses_query("", "query_not_one_statement")
      refuses_query("-- #{INTAKE_SENTINEL}\n;", "query_not_one_statement")
      refuses_query("SELECT '#{INTAKE_SENTINEL}'; SELECT 2", "query_not_one_statement")
    end

    it "refuses what SupportedSql refuses, such as SELECT INTO, DML, and locking, as unsupported_construct" do
      ["SELECT '#{INTAKE_SENTINEL}' INTO t", "UPDATE t SET a = '#{INTAKE_SENTINEL}'",
       "SELECT '#{INTAKE_SENTINEL}' FROM t FOR UPDATE",
       "WITH d AS (DELETE FROM t WHERE a = '#{INTAKE_SENTINEL}' RETURNING *) SELECT * FROM d",
       "SELECT * FROM t TABLESAMPLE SYSTEM (1) WHERE a = '#{INTAKE_SENTINEL}'"].each do |sql|
        refuses_query(sql, "unsupported_construct")
      end
    end
  end

  describe "the plan" do
    let(:plan) { JSON.parse(plan_text) }

    it "refuses text that isn't one strict JSON document as plan_not_json" do
      [%([{"Plan": {"Node Type": "#{INTAKE_SENTINEL}"}}), "#{plan_text}\n{}", "",
       %([{"Plan": {"Actual Rows": 1, "Actual Rows": "#{INTAKE_SENTINEL}"}}]),
       %([{"Plan": {"Actual Rows": 1e400, "Node Type": "#{INTAKE_SENTINEL}"}}]),
       %([{"Plan": {"Node Type": "#{INTAKE_SENTINEL}" /* x */}}]),
       %([{"Plan": {"Node Type": "#{INTAKE_SENTINEL}\\q"}}]),
       %([{"Plan": {"Node Type": "#{INTAKE_SENTINEL}\xff"}}]).b].each do |text|
        refuses_plan(text, "plan_not_json")
      end
    end

    it "refuses JSON that isn't one EXPLAIN result, [{\"Plan\": {...}}], as plan_bad_shape" do
      entry = plan[0]
      [plan[0], [], [entry, entry], [[entry]], [INTAKE_SENTINEL], [{ "Plan" => [entry["Plan"]] }],
       [{ "Query" => entry["Plan"] }], [entry.merge("Settings" => [INTAKE_SENTINEL])],
       [entry.merge("Settings" => { "search_path" => [INTAKE_SENTINEL] })], INTAKE_SENTINEL, 1, nil].each do |bad|
        refuses_plan(JSON.generate(bad), "plan_bad_shape")
      end
    end

    it "strips one leading byte order mark from the plan" do
      expect(intake_with(plan: file("plan.json", "﻿#{plan_text}"))).to eq(0)
      expect(only_run.read("plan")).to eq(plan)

      FileUtils.rm_rf(base)
      refuses_plan("﻿﻿#{plan_text}", "plan_not_json")
    end

    it "refuses a plan without ANALYZE as plan_not_analyzed" do
      plan[0]["Plan"].delete_if { |key, _| key.start_with?("Actual") }

      refuses_plan(JSON.generate(plan), "plan_not_analyzed")
    end

    it "refuses a plan without BUFFERS as plan_no_buffers" do
      plan[0]["Plan"].delete_if { |key, _| key.end_with?("Blocks") }

      refuses_plan(JSON.generate(plan), "plan_no_buffers")
    end

    it "accepts a plan with only one buffer counter" do
      plan[0]["Plan"].delete_if { |key, _| key.end_with?("Blocks") && key != "Temp Written Blocks" }

      expect(intake_with(plan: file("plan.json", JSON.generate(plan)))).to eq(0)
    end
  end
end
