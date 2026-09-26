# frozen_string_literal: true

# Proves each end-to-end case's claims against real Postgres.
#
#   ruby e2e/verify.rb                 # every case
#   ruby e2e/verify.rb 001 017         # cases whose directory starts with these
#   ruby e2e/verify.rb --write         # also rewrite each results.md and CASES.md
#
# It starts its own throwaway Postgres container, labeled quaack.e2e, and
# removes it at exit. It needs only Docker and the standard library. Each
# case loads into a fresh database. See e2e/README.md for what's checked.

require "json"
require "open3"

module E2E
  ROOT = File.expand_path(__dir__)
  IMAGE = ENV.fetch("QUAACK_E2E_IMAGE", "postgres:18")
  LABEL = "quaack.e2e"
  # README step 14a: better means more than 5% fewer total blocks.
  WIN = 0.95
  BLOCK_KEYS = ["Shared Hit Blocks", "Shared Read Blocks", "Local Hit Blocks",
                "Local Read Blocks", "Temp Read Blocks", "Temp Written Blocks"].freeze

  # One throwaway Postgres container, reached with docker exec and psql.
  class Postgres
    def initialize
      system("docker", "rm", "-f", *leftovers, out: File::NULL, err: File::NULL) unless leftovers.empty?
      @id = capture("docker", "run", "-d", "--label", LABEL, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", IMAGE).strip
      at_exit { system("docker", "rm", "-f", @id, out: File::NULL, err: File::NULL) }
      wait_until_ready
    end

    def psql(sql, database)
      capture("docker", "exec", "-i", @id, "psql", "-U", "postgres", "-d", database, "-X", "-q",
              "-v", "ON_ERROR_STOP=1", "-At", "-P", "null=<NULL>", stdin: sql)
    end

    private

    def leftovers
      @leftovers ||= capture("docker", "ps", "-aq", "--filter", "label=#{LABEL}").split
    end

    def wait_until_ready
      60.times do
        return if system("docker", "exec", @id, "psql", "-U", "postgres", "-Atc", "SELECT 1",
                         out: File::NULL, err: File::NULL)

        sleep 1
      end
      abort "Postgres didn't start."
    end

    def capture(*cmd, stdin: nil)
      out, err, status = Open3.capture3(*cmd, stdin_data: stdin)
      raise "#{cmd.first(3).join(" ")} failed:\n#{err}" unless status.success?

      out
    end
  end

  # One case directory: case.json, schema.sql, slow.sql, and optionally
  # fast.sql, indexes.sql, and slow_unlimited.sql.
  class Case
    attr_reader :dir, :meta

    def initialize(dir)
      @dir = dir
      @meta = JSON.parse(read("case.json"))
    end

    def name = File.basename(dir)
    def database = "case_#{name[/\A\d+/]}"
    def category = meta.fetch("category")
    def literal_sets = meta.fetch("literal_sets")
    def compare_mode = meta.fetch("compare", "multiset")
    def schema = read("schema.sql")
    def slow = read("slow.sql")
    def fast = optional("fast.sql")
    def indexes = optional("indexes.sql")
    def unlimited = optional("slow_unlimited.sql")

    def bind(sql, set)
      set.fetch("replace").reduce(sql) { |text, (from, to)| text.gsub(from, to) }
    end

    # A replacement that matches none of the case's queries is a typo.
    def check_literals!
      queries = [slow, fast, unlimited].compact
      literal_sets.flat_map { |set| set.fetch("replace").keys }.each do |from|
        raise "#{name}: literal #{from.inspect} isn't in any query" unless queries.any? { |q| q.include?(from) }
      end
    end

    private

    def read(file) = File.read(File.join(dir, file))
    def optional(file) = File.exist?(File.join(dir, file)) ? read(file) : nil
  end

  # Runs one case: equivalence on every literal set, then total blocks.
  class Runner
    Row = Struct.new(:set, :rows, :orig, :rewrite, :orig_idx, :rewrite_idx, :minimax)

    def initialize(postgres, kase)
      @pg = postgres
      @case = kase
      @failures = []
    end

    attr_reader :failures

    def run
      @case.check_literals!
      load_schema
      equivalence = compare_everywhere
      @rows = measure
      Verdict.new(@case, @rows, equivalence).check(@failures)
      self
    end

    def table
      @rows
    end

    private

    def sql(text) = @pg.psql(text, @case.database)

    def load_schema
      @pg.psql("DROP DATABASE IF EXISTS #{@case.database}; CREATE DATABASE #{@case.database};", "postgres")
      sql(@case.schema)
    end

    # Each literal set's verdict: true when the candidate returned the same
    # results as the original, with and without the new indexes.
    def compare_everywhere
      return {} unless @case.fast || @case.indexes

      without = @case.literal_sets.to_h { |set| [set["name"], same?(set)] }
      with = with_indexes { @case.literal_sets.to_h { |set| [set["name"], same?(set)] } }
      without.to_h { |name, ok| [name, ok && with.fetch(name, true)] }
    end

    def same?(set)
      candidate = @case.fast || @case.slow
      Compare.new(@case.compare_mode).same?(
        sql(@case.bind(@case.slow, set)), sql(@case.bind(candidate, set)),
        @case.unlimited && sql(@case.bind(@case.unlimited, set))
      )
    end

    def with_indexes
      return {} unless @case.indexes

      before = index_names
      sql("#{@case.indexes}\nANALYZE;")
      yield
    ensure
      if @case.indexes
        added = index_names - before
        sql("#{added.map { |n| "DROP INDEX #{n};" }.join}ANALYZE;") unless added.empty?
      end
    end

    def index_names = sql("SELECT indexrelid::regclass FROM pg_index;").split

    def measure
      sets = @case.literal_sets
      plain = sets.map { |set| blocks_for(set) }
      sets.zip(plain, indexed_blocks).map do |set, (orig, rewrite), (orig_idx, rewrite_idx)|
        Row.new(set["name"], row_count(set), orig, rewrite, orig_idx, rewrite_idx, set.fetch("minimax", true))
      end
    end

    def indexed_blocks
      sets = @case.literal_sets
      return Array.new(sets.size, []) unless @case.indexes

      with_indexes { sets.map { |set| blocks_for(set) } }
    end

    def blocks_for(set)
      [blocks(@case.bind(@case.slow, set)), @case.fast && blocks(@case.bind(@case.fast, set))]
    end

    def row_count(set) = sql(@case.bind(@case.slow, set)).lines.count

    # README step 13: shared, local, and temp blocks. The first run warms up.
    def blocks(query)
      explain = "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) #{query.strip.chomp(";")};"
      sql(explain)
      plan = JSON.parse(sql(explain)).first.fetch("Plan")
      BLOCK_KEYS.sum { |key| plan.fetch(key, 0) }
    end
  end

  # The result comparisons from README 9d, for the cases' own data.
  class Compare
    def initialize(mode)
      @mode = mode
    end

    def same?(original, candidate, unlimited)
      case @mode
      when "ordered" then original == candidate
      when "multiset" then original.lines.sort == candidate.lines.sort
      when "tolerance" then close?(original.lines.sort, candidate.lines.sort)
      when "limit_subset" then subset?(original, candidate, unlimited)
      else raise "unknown compare mode #{@mode}"
      end
    end

    private

    # Float aggregates: each numeric field within a relative 1e-9.
    def close?(original, candidate)
      original.size == candidate.size && original.zip(candidate).all? do |a, b|
        a.split("|").zip(b.split("|")).all? { |x, y| x == y || near?(x, y) }
      end
    end

    def near?(one, other)
      a = Float(one, exception: false)
      b = Float(other, exception: false)
      a && b && (a - b).abs <= 1e-9 * [a.abs, b.abs, 1].max
    end

    # LIMIT with no ORDER BY: same row count, and every row is one the
    # unlimited original returns, counted with multiplicity.
    def subset?(original, candidate, unlimited)
      return false unless original.lines.size == candidate.lines.size

      pool = unlimited.lines.tally
      candidate.lines.tally.all? { |line, n| pool.fetch(line, 0) >= n }
    end
  end

  # Checks a case's measurements against what its category claims.
  class Verdict
    FIXES = { rewrite: "the rewrite", orig_idx: "the index", rewrite_idx: "the rewrite plus the index" }.freeze

    def initialize(kase, rows, equivalence)
      @case = kase
      @rows = rows
      @equivalence = equivalence
    end

    def check(failures)
      checker = "check_#{@case.category}"
      raise "#{@case.name}: unknown category #{@case.category}" unless respond_to?(checker, true)

      send(checker, failures)
    end

    private

    def slow_row = @rows.first
    def all_equivalent? = @equivalence.values.all?

    def check_index(failures)
      equivalent(failures)
      wins(failures, :orig_idx, "the new index")
    end

    def check_rewrite(failures)
      equivalent(failures)
      wins(failures, :rewrite, "the rewrite")
    end

    def check_both(failures)
      equivalent(failures)
      wins(failures, :rewrite_idx, "the rewrite plus the new index")
      beats(failures, :rewrite_idx, :rewrite, "the rewrite alone")
      beats(failures, :rewrite_idx, :orig_idx, "the new index alone")
    end

    # Nothing may pass 14a and 14b: the tempting rewrite, the tempting
    # index, or both together.
    def check_none(failures)
      equivalent(failures)
      FIXES.each do |column, what|
        failures << "#{what} would be accepted" if slow_row[column] && accepted?(column)
      end
    end

    # QUAACK v1 refuses the query. The proof only shows it runs on Postgres.
    def check_refused(failures)
      failures << "a refused case has nothing to compare" if @case.fast || @case.indexes
    end

    def check_trap(failures)
      failures << "the tempting rewrite matched the original on every literal set" if all_equivalent?
    end

    def equivalent(failures)
      @equivalence.each { |set, ok| failures << "results differ: #{set}" unless ok }
    end

    def wins(failures, column, what)
      failures << "#{what} isn't >5% better on the slow literals" unless slow_row[column] < slow_row.orig * WIN
      minimax_rows.each do |r|
        failures << "#{what} is worse than the original: #{r.set}" if r[column] > r.orig
      end
    end

    # README 14a and 14b: more than 5% better on the slow literals, and no
    # worse on any other literal set.
    def accepted?(column)
      slow_row[column] < slow_row.orig * WIN && minimax_rows.all? { |r| r[column] <= r.orig }
    end

    # Literal sets marked "minimax": false only prove equivalence. They
    # aren't sets 3e would pick, so 14b doesn't judge them.
    def minimax_rows = @rows.select(&:minimax)

    def beats(failures, column, other, what)
      return if slow_row[column] < slow_row[other] * WIN

      failures << "the best fix isn't >5% better than #{what} on the slow literals"
    end
  end

  # Prints a case's table, and writes it to results.md with --write.
  module Report
    HEADER = "| Literal set | Rows | Orig | Rewrite | Orig + idx | Rewrite + idx |\n" \
             "| --- | ---: | ---: | ---: | ---: | ---: |\n"

    module_function

    def markdown(kase, rows, failures)
      body = rows.map do |r|
        "| #{r.set} | #{r.rows} | #{r.orig} | #{r.rewrite || "-"} | #{r.orig_idx || "-"} | #{r.rewrite_idx || "-"} |"
      end
      verdict = failures.empty? ? "Every claim holds." : failures.map { |f| "- FAILED: #{f}" }.join("\n")
      "# #{kase.name} results.\n\nTotal blocks (README step 13), from `ruby e2e/verify.rb`.\n" \
        "Category: `#{kase.category}`.\n\n#{HEADER}#{body.join("\n")}\n\n#{verdict}\n"
    end

    def index(cases)
      lines = cases.map do |c|
        "| [#{c.name}](cases/#{c.name}/README.md) | #{c.category} | #{c.meta.fetch("features").join(", ")} |"
      end
      "# Case index.\n\nGenerated by `ruby e2e/verify.rb --write`.\n\n" \
        "| Case | Category | Exercises |\n| --- | --- | --- |\n#{lines.join("\n")}\n"
    end
  end

  def self.main(args)
    write = args.delete("--write")
    cases = select(Dir.glob(File.join(ROOT, "cases", "*")).map { |d| Case.new(d) }, args)
    File.write(File.join(ROOT, "CASES.md"), Report.index(cases)) if write && args.empty?
    finish(cases, run_all(Postgres.new, cases, write))
  end

  def self.finish(cases, failed)
    puts failed.empty? ? "All #{cases.size} cases hold." : "Failed: #{failed.join(", ")}"
    exit(failed.empty? ? 0 : 1)
  end

  def self.select(cases, prefixes)
    return cases if prefixes.empty?

    cases.select { |c| prefixes.any? { |a| c.name.start_with?(a) } }
  end

  def self.run_all(postgres, cases, write)
    cases.reject do |kase|
      runner = Runner.new(postgres, kase).run
      text = Report.markdown(kase, runner.table, runner.failures)
      File.write(File.join(kase.dir, "results.md"), text) if write
      puts text
      runner.failures.empty?
    end.map(&:name)
  end
end

E2E.main(ARGV.dup) if $PROGRAM_NAME == __FILE__
