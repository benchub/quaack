# frozen_string_literal: true

require "json"
require "stringio"
require "pg_query"
require "quaack/enclave/supported_sql"

# The leak-test helper itself (spec/support/leak_check.rb). Every later
# enclave task leans on it, so it has to catch what it says it catches.
RSpec.describe LeakCheck do
  let(:sentinels) { LeakCheck::Sentinels.new }

  # An error whose message is clean, so only the channel under test holds
  # the sentinel.
  def clean_error(klass = RuntimeError) = klass.new("clean")

  def raised
    yield
  rescue StandardError => e
    e
  end

  describe LeakCheck::Sentinels do
    it "makes values that are valid in their positions in Postgres" do
      conn = test_database.connection
      row = conn.exec(<<~SQL).first
        SELECT '#{sentinels.text}'::text AS text, #{sentinels.number}::integer AS number,
               DATE '#{sentinels.date.iso8601}'::text AS date, ('#{sentinels.json}'::jsonb)::text AS json,
               '#{sentinels.like_prefix}-rest' LIKE '#{sentinels.like}' AS like_matches,
               '#{sentinels.text}' LIKE '#{sentinels.like}' AS like_matches_other
      SQL
      conn.exec("CREATE TEMP TABLE #{sentinels.word} (#{sentinels.word} integer)")

      expect(row).to eq("text" => sentinels.text, "number" => sentinels.number.to_s,
                        "date" => sentinels.date.iso8601, "json" => sentinels.json,
                        "like_matches" => "t", "like_matches_other" => "f")
      expect(conn.exec("SELECT relname FROM pg_class WHERE relname = '#{sentinels.word}'").column_values(0))
        .to eq([sentinels.word])
    end

    it "makes a distinctive nine-digit number that fits a Postgres integer" do
      expect(sentinels.number).to be_between(100_000_000, 999_999_999)
    end

    it "makes a date long before any date QUAACK writes itself" do
      expect(sentinels.date).to be_a(Date)
      expect(sentinels.date.year).to be < 1900
    end

    # Postgres counts days by the Gregorian calendar all the way back, so a
    # Julian-only leap day, such as 1100-02-29, is out of range for it.
    it "never draws a day Postgres refuses, and every day it draws is before 1900" do
      days = Array.new(LeakCheck::Sentinels::DAYS) { LeakCheck::Sentinels.day(it).iso8601 }

      expect(days & %w[1100-02-29 1300-02-29 1400-02-29 1500-02-29]).to eq([])
      expect(days.max).to start_with("189")
      expect(test_database.connection.exec("SELECT DATE '#{days.max}', DATE '#{days.min}'").ntuples).to eq(1)
    end

    it "names each needle it scans for, and each is distinct" do
      needles = sentinels.needles

      expect(needles.keys).to eq(%i[text word number date json like])
      expect(needles.values.uniq.size).to eq(6)
      expect(needles.values).to all(match(/\A[0-9a-z-]{9,}\z/))
    end

    it "scans for each value itself, or for the token in it" do
      needles = sentinels.needles

      expect(sentinels.text).to include(needles[:text])
      expect(needles[:word]).to eq(sentinels.word)
      expect(needles[:number]).to eq(sentinels.number.to_s)
      expect(needles[:date]).to eq(sentinels.date.iso8601)
      expect(sentinels.json).to include(needles[:json])
      expect(needles[:like]).to eq(sentinels.like_prefix)
      expect(sentinels.like).to eq("#{sentinels.like_prefix}%")
    end

    it "never makes the same needle twice, across many sets" do
      needles = Array.new(300) { LeakCheck::Sentinels.new.needles.values }.flatten

      expect(needles.uniq.size).to eq(needles.size)
      expect(needles.size).to eq(1800)
    end

    it "draws again when a draw repeats a needle an earlier set used" do
      draws = %w[sentinel-draw-one sentinel-draw-one sentinel-draw-two].each

      expect([LeakCheck::Sentinels.claim { draws.next }, LeakCheck::Sentinels.claim { draws.next }])
        .to eq(%w[sentinel-draw-one sentinel-draw-two])
    end

    it "adds fixed values, such as literals baked into a fixture file" do
      with_extra = LeakCheck::Sentinels.new(extra: { email: "quaack-sentinel-email" })

      expect(with_extra.needles).to include(email: "quaack-sentinel-email")
      expect(with_extra.needles.size).to eq(7)
    end

    it "refuses a fixed value short enough to show up by chance" do
      expect { LeakCheck::Sentinels.new(extra: { short: "abc" }) }.to raise_error(ArgumentError, /short/)
    end
  end

  describe ".findings" do
    def findings(**) = LeakCheck.findings(sentinels, **)
    def channels(**) = findings(**).map(&:channel)

    it "finds nothing in clean output" do
      _out, _err, status = run_ruby("-e", "exit 0")
      result = findings(stdout: %({"type":"done"}\n), stderr: "", status:,
                        objects: { error: RuntimeError.new("clean"), verdict: { rows: [1, 2], ok: true } })

      expect(result).to eq([])
    end

    it "finds each sentinel on stdout and on stderr" do
      sentinels.needles.each do |name, needle|
        expect(channels(stdout: "x #{needle} y")).to eq(["stdout"]), name.to_s
        expect(channels(stderr: "x #{needle} y")).to eq(["stderr"]), name.to_s
      end
    end

    it "finds a sentinel in the exit status's description" do
      status = Struct.new(:detail).new(sentinels.text)

      expect(channels(status:)).to include("status")
    end

    it "finds a sentinel whatever its case" do
      expect(channels(stdout: sentinels.text.upcase)).to eq(["stdout"])
    end

    it "finds a sentinel in bytes that aren't valid UTF-8, or in UTF-16" do
      expect(channels(stdout: "\xff#{sentinels.word}\xfe".b)).to eq(["stdout"])
      expect(channels(stdout: sentinels.word.encode("UTF-16LE"))).to eq(["stdout"])
    end

    it "finds a sentinel in a string, a number, or a date among the objects, however deep" do
      objects = { deep: [{ a: [1, { b: sentinels.text }] }], number: sentinels.number, date: sentinels.date,
                  key: { sentinels.word => 1 } }

      expect(channels(objects:)).to include("deep[0][:a][1][:b]", "number", "date", "key.keys")
    end

    it "finds a sentinel in an error's message, backtrace, and cause" do
      with_message = RuntimeError.new(sentinels.text)
      with_backtrace = clean_error.tap { it.set_backtrace(["#{sentinels.word}.rb:1"]) }
      with_cause = raised do
        raise sentinels.date.iso8601
      rescue StandardError
        raise "clean"
      end

      expect(channels(objects: { e: with_message })).to include("e.message")
      expect(channels(objects: { e: with_backtrace })).to include("e.backtrace", "e.full_message")
      expect(channels(objects: { e: with_cause })).to include("e.cause.message")
    end

    it "finds a sentinel only in an error's detailed_message or full_message" do
      needle = sentinels.number.to_s
      detailed = Class.new(RuntimeError)
      detailed.define_method(:detailed_message) { |**| "extra #{needle}" }
      full = Class.new(RuntimeError)
      full.define_method(:full_message) { |**| "extra #{needle}" }

      expect(channels(objects: { e: clean_error(detailed) })).to include("e.detailed_message")
      expect(channels(objects: { e: clean_error(full) })).to include("e.full_message")
    end

    it "finds a sentinel in an instance variable that inspect hides" do
      hidden = Class.new do
        def initialize(value) = @value = value
        def inspect = "#<hidden>"
        def to_s = "hidden"
      end
      error = clean_error.tap { it.instance_variable_set(:@detail, hidden.new(sentinels.json)) }

      expect(channels(objects: { e: error })).to include("e.@detail.@value")
    end

    it "finds a sentinel in what a describing method raises" do
      needle = sentinels.like_prefix
      loud = Class.new { define_method(:inspect) { raise needle } }

      expect(channels(objects: { loud: loud.new })).to include("loud.inspect (raised)")
    end

    # In-process specs capture into a StringIO, whose to_s is only
    # #<StringIO:...>, so passing it by mistake would scan nothing.
    it "refuses stdout or stderr that isn't a String, such as the StringIO it was captured in" do
      io = StringIO.new.tap { it.write("leak #{sentinels.text}") }

      expect { findings(stdout: io) }.to raise_error(ArgumentError, /stdout.*String/)
      expect { findings(stderr: io) }.to raise_error(ArgumentError, /stderr.*String/)
    end

    it "scans the text of a StringIO among the objects, and refuses any other IO" do
      io = StringIO.new.tap { it.write("leak #{sentinels.text}") }

      expect(channels(objects: { out: io })).to eq(["out.string"])
      expect { findings(objects: { out: $stdout }) }.to raise_error(ArgumentError, /out.*IO/)
    end

    it "finds a sentinel in a Struct's or a Data's members that inspect hides" do
      hiding = Module.new do
        def inspect = "#<hidden>"
        def to_s = "hidden"
      end
      hidden_struct = Struct.new(:value).include(hiding)
      hidden_data = Data.define(:value).include(hiding)

      expect(channels(objects: { s: hidden_struct.new(sentinels.text), d: hidden_data.new(value: sentinels.word) }))
        .to match_array(%w[s.value d.value])
    end

    it "ends on a cycle, and still finds what's in it" do
      cycle = []
      cycle << cycle << sentinels.text

      expect(channels(objects: { cycle: })).to include("cycle[1]")
    end
  end

  describe ".check_scanner!" do
    it "passes for the real scanner" do
      expect { LeakCheck.check_scanner!(sentinels) }.not_to raise_error
    end

    it "fails, naming the channel, for a scanner that misses a channel" do
      misses_stderr = ->(set, **channels) { LeakCheck.findings(set, **channels.except(:stderr)) }
      misses_causes = lambda do |set, objects: {}, **rest|
        without_causes = objects.transform_values { it.is_a?(Exception) && it.cause ? nil : it }
        LeakCheck.findings(set, objects: without_causes, **rest)
      end

      expect { LeakCheck.check_scanner!(sentinels, scanner: misses_stderr) }
        .to raise_error(LeakCheck::BrokenScanner, /stderr/)
      expect { LeakCheck.check_scanner!(sentinels, scanner: misses_causes) }
        .to raise_error(LeakCheck::BrokenScanner, /cause/)
    end

    it "fails, naming the kind, for a scanner that misses one kind of sentinel" do
      misses_numbers = ->(set, **channels) { LeakCheck.findings(set, **channels).reject { it.sentinel == :number } }

      expect { LeakCheck.check_scanner!(sentinels, scanner: misses_numbers) }
        .to raise_error(LeakCheck::BrokenScanner, /number in stdout/)
    end

    # The places overlap unless each plant keeps its needle out of every
    # other place. An error's full_message, for one, holds its message,
    # backtrace, and cause, so a scanner that missed causes would still
    # find a cause planted in an ordinary error.
    it "plants each place so the needle shows only there" do
      expected = {
        "stdout" => ["stdout"], "stdout, in capitals" => ["stdout"], "stdout, in UTF-16" => ["stdout"],
        "stderr" => ["stderr"], "status" => %w[status status.inspect status.detail],
        "a deep object" => ["result#{".@value" * LeakCheck::PositiveControl::DEPTH}"],
        "an object's to_s" => ["result"], "an object's inspect" => ["result.inspect"],
        "an object's instance variable" => ["result.@value"],
        "an error's message" => ["error.message"], "an error's backtrace" => ["error.backtrace"],
        "an error's detailed_message" => ["error.detailed_message"],
        "an error's full_message" => ["error.full_message"], "an error's cause" => ["error.cause"],
        "an error's instance variable" => ["error.@kept.@value"]
      }
      plants = LeakCheck::PositiveControl::PLANTS

      expect(plants.keys).to match_array(expected.keys)
      plants.each do |place, plant|
        found = LeakCheck.findings(sentinels, **plant.call(sentinels.word))
        channels = found.map(&:channel)
        channels = channels.map { it.sub(/\Aerror\.cause\..*/, "error.cause") }.uniq if place == "an error's cause"
        expect(channels).to match_array(expected.fetch(place)), place
      end
    end

    it "fails for a scanner that finds nothing" do
      expect { LeakCheck.check_scanner!(sentinels, scanner: ->(*, **) { [] }) }
        .to raise_error(LeakCheck::BrokenScanner)
    end
  end

  describe "#expect_no_leaks" do
    it "passes for clean output" do
      expect { expect_no_leaks(sentinels, stdout: "fine", stderr: "") }.not_to raise_error
    end

    it "fails, naming the sentinel and where it showed, for a leak" do
      expect { expect_no_leaks(sentinels, stdout: "fine", stderr: "oops #{sentinels.word}", why: "the probe") }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /the probe.*word.*stderr/m)
    end

    it "takes a subprocess outcome in place of stdout, stderr, and status" do
      outcome = LeakCheck::Quaacks::Outcome.new(stdout: sentinels.text, stderr: "", status: nil, loaded_features: [])

      expect { expect_no_leaks(sentinels, outcome) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /text.*stdout/m)
    end

    it "scans a subprocess outcome's stderr and status too" do
      on_stderr = LeakCheck::Quaacks::Outcome.new(stdout: "", stderr: "x #{sentinels.word}", status: nil,
                                                  loaded_features: [])
      in_status = LeakCheck::Quaacks::Outcome.new(stdout: "", stderr: "", loaded_features: [],
                                                  status: Struct.new(:detail).new(sentinels.number))

      expect { expect_no_leaks(sentinels, on_stderr) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /word in stderr/)
      expect { expect_no_leaks(sentinels, in_status) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /number in status/)
    end

    # The scanner is a parameter only for this: to show a broken one fails
    # the check before it can pass a leak.
    it "runs the positive control first, so a scanner that finds nothing fails instead of passing" do
      finds_nothing = ->(*, **) { [] }

      expect { expect_no_leaks(sentinels, stdout: sentinels.text, scanner: finds_nothing) }
        .to raise_error(LeakCheck::BrokenScanner)
    end
  end

  describe LeakCheck::Quaacks do
    let(:quaacks) { described_class.new }

    after { quaacks.remove }

    it "runs the installed exe/quaacks outside Bundler, the way the jump server does" do
      outcome = quaacks.run("--version")

      expect(outcome.stdout).to end_with(%({"type":"done"}\n))
      expect(outcome.status.exitstatus).to eq(0)
      enclave = outcome.loaded_features.grep(%r{/quaack/enclave\.rb\z})
      expect(enclave.size).to eq(1)
      expect(enclave.first).to include("/gem_home/gems/quaacks-")
      expect(outcome.loaded_features.grep(%r{\A#{Regexp.escape(File.join(REPO_ROOT, "enclave", "lib"))}/})).to eq([])
      expect(outcome.loaded_features.grep(%r{/bundler(/|\.rb\z)})).to eq([])
    end

    it "runs a script the same way, with no Bundler in its environment" do
      outcome = quaacks.run_ruby(<<~RUBY)
        print [ENV.keys.grep(/\\ABUNDLE/), $LOADED_FEATURES.grep(%r{/bundler/}), Gem.paths.home].inspect
      RUBY

      expect(outcome.stdout).to eq([[], [], File.realpath(quaacks.gem_home)].inspect)
    end

    it "captures stdout and stderr separately, and the exit status" do
      outcome = quaacks.run_ruby(<<~RUBY)
        STDOUT.syswrite("to stdout"); STDERR.syswrite("to stderr"); exit 5
      RUBY

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq(["to stdout", "to stderr", 5])
    end

    it "gives the child a temporary HOME, whose runs are its store base, and passes stdin" do
      outcome = quaacks.run_ruby(<<~RUBY, stdin: "from stdin")
        require "quaack/enclave/store"
        print [Dir.home, Quaack::Enclave::Store.default_base, $stdin.read].inspect
      RUBY

      expect(outcome.stdout).to eq([quaacks.home, quaacks.store_base, "from stdin"].inspect)
      expect(quaacks.home).not_to eq(Dir.home)
      expect(quaacks.store_base).to eq(File.join(quaacks.home, ".quaack", "runs"))
    end

    it "lists the runs a subcommand left under the store base" do
      query = File.join(quaacks.home, "q.sql").tap { File.write(it, "SELECT 1") }
      plan = File.join(quaacks.home, "p.json").tap do |path|
        File.write(path, File.read(File.join(__dir__, "fixtures", "plans", "sentinel_literals.json")))
      end

      outcome = quaacks.run("intake", "--query", query, "--plan", plan, "--server", "prod-db-3")

      expect(outcome.status.exitstatus).to eq(0), outcome.stdout
      expect(quaacks.runs.size).to eq(1)
      expect(outcome.stdout).to include(quaacks.runs.first)
    end

    it "removes its HOME" do
      quaacks.remove

      expect(File.exist?(quaacks.home)).to be(false)
    end

    it "writes the script it runs into the install's directory, and removes it after" do
      outcome = quaacks.run_ruby("print __FILE__")

      expect(File.dirname(outcome.stdout)).to eq(quaacks.install.dir)
      expect(File.exist?(outcome.stdout)).to be(false)
    end

    # No subcommand reads stdin yet, so a stand-in install shows what run
    # hands it. run_ruby's spec above shows the install passes stdin on.
    it "passes stdin, HOME, and argv on to the installed quaacks" do
      install = Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def run(*args, **kwargs)
          @calls << [args, kwargs]
          IsolatedInstall::Run.new("", "", nil, [])
        end
      end.new
      stand_in = described_class.new(install:)

      stand_in.run("probe", "--flag", stdin: "from stdin")

      expect(install.calls)
        .to eq([[%w[quaacks probe --flag], { env: { "HOME" => stand_in.home }, stdin: "from stdin" }]])
    ensure
      stand_in&.remove
    end
  end

  describe LeakCheck::Fixture do
    let(:conn) { test_database.connection }
    let!(:planted) { described_class.plant(conn, sentinels) }

    def stats(table, column, field)
      conn.exec_params("SELECT #{field}::text FROM pg_stats WHERE schemaname = 'public' AND tablename = $1 " \
                       "AND attname = $2", [table, column]).getvalue(0, 0).to_s
    end

    it "puts sentinels in the most common values of the columns it plants" do
      expect(stats("customers", "name", "most_common_vals")).to include(sentinels.text)
      expect(stats("orders", "status", "most_common_vals")).to include(sentinels.word)
      expect(stats("orders", "total_cents", "most_common_vals")).to include(sentinels.number.to_s)
      expect(stats("orders", "created_at", "most_common_vals")).to include(sentinels.date.iso8601)
    end

    it "puts the LIKE prefix in the email column's histogram bounds" do
      expect(stats("customers", "email", "histogram_bounds")).to include(sentinels.like_prefix)
    end

    it "gives a supported query whose literals are the sentinels, and that finds the planted rows" do
      query = planted.query

      [sentinels.text, sentinels.word, sentinels.number.to_s, sentinels.date.iso8601, sentinels.like].each do |value|
        expect(query).to include(value)
      end
      expect(Quaack::Enclave::SupportedSql.check!(PgQuery.parse(query))).to be_nil
      expect(conn.exec(query).ntuples).to eq(described_class::ROWS)
    end

    it "shows the sentinels in the query's EXPLAIN, so a plan read by a step holds them" do
      plan = conn.exec("EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) #{planted.query}").getvalue(0, 0)

      expect(LeakCheck.findings(sentinels, objects: { plan: }).map(&:sentinel)).to include(:text, :word, :number)
    end
  end
end
