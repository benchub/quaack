# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenario_tests"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# vacuity-guard's search for a distinguishing database (20261010-43), behind
# the rule-based scenarios.
RSpec.describe Quaack::Enclave::VacuityGuard::Search do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:guard) { Quaack::Enclave::VacuityGuard }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        score integer NOT NULL CHECK (score BETWEEN -5 AND 50), published boolean NOT NULL DEFAULT false);
      CREATE TABLE fx.comments (id bigint PRIMARY KEY, post_id bigint NOT NULL REFERENCES fx.posts,
        user_id bigint REFERENCES fx.users);
    SQL
  end

  # The rules build no comment whose author differs from its post's.
  let(:tie) do
    "SELECT fx.comments.id FROM fx.comments JOIN fx.posts ON fx.posts.id = fx.comments.post_id " \
      "WHERE fx.comments.user_id = fx.posts.user_id"
  end
  let(:tie_atoms) { ["fx.posts.id = fx.comments.post_id", "fx.comments.user_id = fx.posts.user_id"] }
  # score > 3 is redundant beside score > 5, so no database tells it apart.
  let(:redundant) { "SELECT fx.posts.id FROM fx.posts WHERE fx.posts.score > 5 AND fx.posts.score > 3" }

  def run(sql, search: true, **)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    [guard.run(runner, builder, sql, search:, **), builder]
  end

  it "closes atoms the rule-based scenarios leave untested" do
    expect(run(tie, search: false).first.untested.sort).to eq(tie_atoms.sort)
    expect(run(tie).first.untested).to eq([])
  end

  it "keeps the trials that told atoms apart as S1 fixtures, which rewrite-test replays" do
    _, off = run(tie, search: false)
    _, on = run(tie)
    added = on.spills.fetch(:s1, []) - off.spills.fetch(:s1, [])
    expect(added).not_to be_empty
    loosened, = guard.loosened_queries(on)
    exercised = added.flat_map { guard.exercised_atoms(runner, it, tie, loosened) }
    expect(exercised.map { on.atoms[it].shape }.sort).to eq(tie_atoms.sort)
  end

  it "says an atom it searched in full, with no difference found, was searched" do
    result, = run(redundant, search_options: { trials_per_atom: 5 })
    expect(result.untested).to eq(["fx.posts.score > $2"])
    expect(result.untested_states).to eq([:searched])
  end

  it "says an atom the clock stopped it before searching in full wasn't searched" do
    result, = run(redundant, search_options: { seconds: 0 })
    expect(result.untested_states).to eq([:not_searched])
  end

  it "never searches without the flag, and says so" do
    result, = run(redundant, search: false)
    expect(result.untested_states).to eq([:not_searched])
  end

  it "spends exactly its trial budget on an atom it can't close" do
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(redundant))
    outcome = search_for(builder, redundant, trials_per_atom: 7)
    expect(outcome.trials).to eq(7)
    expect(outcome.found).to eq([])
  end

  def search_for(builder, sql, **)
    rows = builder.build.values.flatten
    loosened, = guard.loosened_queries(builder)
    untested = guard.run(runner, builder, sql, search: false).untested_atoms
    searcher(builder, sql, rows, **).run(loosened.slice(*untested))
  end

  def searcher(builder, sql, rows, **)
    described_class.new(runner, builder.schema, builder.topology.order, sql, rows, builder.pools, **)
  end

  it "discards a trial that breaks a constraint, never counting it a difference" do
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(redundant))
    outcome = search_for(builder, redundant, trials_per_atom: 60)
    expect(outcome.discarded).to be_positive
    expect(outcome.found).to eq([])
  end

  it "leaves the arena empty after a search" do
    run(tie)
    run(redundant, search_options: { trials_per_atom: 20 })
    counts = %w[users posts comments].map { conn.exec("SELECT count(*) FROM fx.#{it}").getvalue(0, 0) }
    expect(counts).to eq(%w[0 0 0])
  end

  it "rolls each trial back, so rows don't carry from one trial to the next" do
    # Each trial holds at most MAX_ROWS rows a table. A trial that leaked
    # into the next would show more.
    seen = []
    spy = Class.new(Quaack::Enclave::ArenaRunner) do
      define_method(:with_fixture) do |rows = [], **kw, &blk|
        super(rows, **kw) do |tx|
          loaded = rows.count { |row| row.table.name == "posts" }
          seen << (tx.query("SELECT count(*) FROM fx.posts").rows.first.first.to_i - loaded)
          blk.call(tx)
        end
      end
    end
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(redundant))
    guard.run(spy.new(conn), builder, redundant, search_options: { trials_per_atom: 10 })
    expect(seen.uniq).to eq([0])
  end

  it "finds the same fixtures on every run, from its seed" do
    two = Array.new(2) do
      builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(tie))
      search_for(builder, tie).fixtures
    end
    expect(two.first).not_to be_empty
    expect(two.first).to eq(two.last)
  end

  it "doesn't count its trials as fixture loads" do
    off = Quaack::Enclave::ArenaRunner.new(conn)
    on = Quaack::Enclave::ArenaRunner.new(conn)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(redundant))
    guard.run(off, builder, redundant, search: false)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(redundant))
    guard.run(on, builder, redundant, search_options: { trials_per_atom: 20 })
    expect(on.loads).to eq(off.loads)
  end

  it "skips a query that calls a volatile function" do
    sql = "SELECT fx.posts.id FROM fx.posts WHERE fx.posts.score > 5 AND fx.posts.score > 3 AND random() < 2"
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    outcome = search_for(builder, sql, trials_per_atom: 5)
    expect(outcome.trials).to eq(0)
    expect(outcome.states.values.uniq).to eq([:not_searched])
  end

  # Trust boundary (20261010-47): whether a bounded search finds a
  # difference can follow a literal, such as a count threshold past the
  # rows a trial holds, or a LIMIT. Such queries aren't searched, so the
  # untested set and the loads don't step with the literal.
  [
    "SELECT fx.users.id FROM fx.users WHERE (SELECT count(*) FROM fx.posts WHERE fx.posts.user_id = fx.users.id) > 2",
    "SELECT fx.posts.user_id FROM fx.posts GROUP BY fx.posts.user_id HAVING count(*) > 2",
    "SELECT fx.posts.id FROM fx.posts WHERE fx.posts.score > 5 AND fx.posts.score > 3 LIMIT 2",
    "SELECT fx.posts.id FROM fx.posts WHERE fx.posts.score > 5 AND fx.posts.score > 3 OFFSET 1"
  ].each do |sql|
    it "doesn't search a query whose search could follow a literal: #{sql[/WHERE .*|GROUP BY .*/]}" do
      builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
      loosened, = guard.loosened_queries(builder)
      outcome = described_class.new(runner, builder.schema, builder.topology.order, sql, builder.build.values.flatten,
                                    builder.pools, trials_per_atom: 5).run(loosened)
      expect(outcome.trials).to eq(0)
      expect(outcome.states.values.uniq).to eq([:not_searched])
    end
  end

  it "searches a scalar subquery compared with a number when it isn't an aggregate" do
    sql = "SELECT fx.users.id FROM fx.users WHERE (SELECT p.score FROM fx.posts p WHERE p.user_id = fx.users.id) > 3"
    expect(described_class::Skips.literal_bound?(sql)).to be(false)
  end

  # Trust boundary: the trials' rows stay in the enclave. A sentinel
  # literal reaches the search's fixtures (so the check can see one), and
  # never the report rewrite-test sends.
  it "keeps the trial rows, and the query's literals, out of the report" do
    sentinel = "Sentinel-43-zq"
    sql = "#{tie} AND fx.posts.user_id IN (SELECT fx.users.id FROM fx.users WHERE fx.users.name = '#{sentinel}')"
    report = Quaack::Enclave::ScenarioTests.run(conn, sql, [sql])
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    fixtures = search_for(builder, sql).fixtures
    expect(JSON.generate(fixtures.flatten.map(&:values))).to include(sentinel)
    outgoing = report.to_h.except(:untested_paths)
    expect(outgoing.inspect).not_to include(sentinel)
  end
end
