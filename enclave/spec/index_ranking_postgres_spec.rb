# frozen_string_literal: true

require "delegate"
require "pp"
require "quaack/enclave/index_ranking"

# 5a-7 against real HypoPG on the test harness. Each table is analyzed with
# a statistics target big enough to read every row, so the statistics, and
# with them every cost, come out the same on every run.
#
# t's s column is skewed as in 5a-4's spec: 90% of rows hold 0, and the
# rest each hold a value of their own. o and cu join on o.cid = cu.id. w is
# one more table, of a size between o's and cu's.
RSpec.describe Quaack::Enclave::IndexRanking do
  let(:conn) { test_database.connection }
  let(:sentinel) { "SENTINEL-5a7-91d2" }

  before do
    conn.exec(<<~SQL)
      CREATE EXTENSION IF NOT EXISTS hypopg;
      CREATE TABLE t (a int, b int, c int, s int, flag text);
      INSERT INTO t SELECT i, i % 1000, i, CASE WHEN i % 10 = 0 THEN i ELSE 0 END,
                           CASE WHEN i % 100 = 0 THEN '#{sentinel}' ELSE 'closed' END
      FROM generate_series(1, 100000) AS i;
      CREATE TABLE o (id int, cid int, x int);
      INSERT INTO o SELECT i, i % 10000, i FROM generate_series(1, 100000) AS i;
      CREATE TABLE cu (id int, y int);
      INSERT INTO cu SELECT i, i FROM generate_series(1, 10000) AS i;
      CREATE TABLE w (z int);
      INSERT INTO w SELECT i FROM generate_series(1, 50000) AS i;
    SQL
    conn.exec("SET default_statistics_target = 1000")
    conn.exec("VACUUM ANALYZE t, o, cu, w")
    conn.exec("RESET default_statistics_target")
  end

  def table(name) = Quaack::Enclave::TableName.new(schema: "public", name:)

  def candidate(on = "t", **)
    Quaack::Enclave::IndexCandidate.new(table: table(on), sources: [:parse], **)
  end

  def key(name, direction) = Quaack::Enclave::IndexCandidate::KeyColumn.new(name:, direction:)

  def single_test(query, literal_sets, candidates)
    Quaack::Enclave::SingleCandidateTest.run(conn, query:, literal_sets:, candidates:)
  end

  def rank(query, literal_sets, report, connection: conn, results: report.results)
    described_class.rank(connection, query:, literal_sets:, baseline: report.baseline, results:)
  end

  # 5a-4, then 5a-7 on its results.
  def ranked(query, literal_sets, candidates)
    rank(query, literal_sets, single_test(query, literal_sets, candidates))
  end

  def ddl(entry) = entry&.ddl

  def leftovers
    {
      hypothetical: conn.exec("SELECT count(*) FROM hypopg_list_indexes").getvalue(0, 0).to_i,
      prepared: conn.exec("SELECT count(*) FROM pg_prepared_statements").getvalue(0, 0).to_i,
      transaction: conn.transaction_status
    }
  end

  let(:clean) { { hypothetical: 0, prepared: 0, transaction: 0 } }

  # s = 10 finds one row, and s = 0 finds 90,000. b = 7 finds 100 either
  # way. So the index on s helps only the slow literal, but helps it most,
  # and the index on b helps both.
  let(:skewed) { "SELECT * FROM t WHERE s = $1 AND b = $2" }
  let(:skewed_sets) { { slow: %w[10 7], worst: %w[0 7] } }
  let(:on_s) { candidate(key: ["s"]) }
  let(:on_b) { candidate(key: ["b"]) }

  it "ranks by the worst case across literal sets, above one that helps only the slow literal more" do
    ranking = ranked(skewed, skewed_sets, [on_s, on_b])
    by_candidate = ranking.top.to_h { |e| [e.candidates, e] }

    expect(ranking.top.map(&:candidates)).to eq([[on_b], [on_s]])
    expect(by_candidate[[on_s]].reductions[:slow]).to be > by_candidate[[on_b]].reductions[:slow]
    expect(by_candidate[[on_s]].reductions[:worst]).to be_within(1e-9).of(0.0)
    expect(by_candidate[[on_b]].worst_reduction).to be > 0.5
  end

  it "leaves out a candidate the planner never used and one HypoPG refused" do
    ignored = candidate(key: ["c"])
    refused = candidate(key: ["nope"])
    ranking = ranked(skewed, skewed_sets, [ignored, on_b, refused])

    expect(ranking.top.map(&:candidates)).to eq([[on_b]])
    expect(ranking.combination).to be_nil
  end

  let(:join) { "SELECT * FROM o JOIN cu ON cu.id = o.cid WHERE o.x = $1 AND cu.y = $2" }
  let(:join_sets) { { slow: %w[5 5], typical: %w[70000 70000] } }
  let(:on_x) { candidate("o", key: ["x"]) }
  let(:on_y) { candidate("cu", key: ["y"]) }

  it "keeps a pair of indexes, on two joined tables, that beats either one alone" do
    report = single_test(join, join_sets, [on_y, on_x])
    ranking = rank(join, join_sets, report)
    best = ranking.top.first
    pair = ranking.combination

    expect(ranking.top.map(&:candidates)).to eq([[on_x], [on_y]])
    expect(pair).to be_a(described_class::Entry)
    expect(pair.candidates).to eq([on_x, on_y])
    expect(pair.ddl).to eq([on_x.to_ddl, on_y.to_ddl])
    expect(pair.used).to eq(slow: [true, true], typical: [true, true])
    expect(pair.worst_reduction).to be > best.worst_reduction
    expect(pair.costs.transform_values(&:after)).to all(satisfy { |set, after| after < best.costs[set].after })
    expect(pair.costs.transform_values(&:before)).to eq(report.baseline.plans.transform_values(&:total_cost))
    expect(pair.size).to eq(report.results.sum(&:size))
    expect(pair.canonical_plans.values).to all(be_comparable)
    expect(pair.canonical_plans[:slow]).not_to be_matches(best.canonical_plans[:slow])
  end

  # What the plans use with these candidates' indexes all present, from
  # 5a-4's shared core.
  def used_together(query, literal_sets, candidates)
    Quaack::Enclave::SingleCandidateTest.session(conn, query:, literal_sets:) do |session|
      session.measure(candidates).plans.transform_values(&:used)
    end
  end

  # With both indexes, s = 10 uses the one on s and s = 0 uses the one on
  # b, whose cost doesn't depend on s. So the worst case is no better, but
  # the slow set is, and no set is worse (DESIGN.md 5a-7, 20260927-9).
  it "combines an index that lowers one set's cost without making any set worse" do
    ranking = ranked(skewed, skewed_sets, [on_s, on_b])
    pair = ranking.combination

    expect(used_together(skewed, skewed_sets, [on_b, on_s])).to eq(slow: [false, true], worst: [true, false])
    expect(pair.candidates).to eq([on_b, on_s])
    expect(pair.costs[:slow].after).to be < ranking.top.first.costs[:slow].after
    expect(pair.costs[:worst].after).to be <= ranking.top.first.costs[:worst].after
  end

  # u's g holds 0 for 90% of rows, and each other value for 100 rows.
  # Neither index is used for g = 0, so both tie on the worst case at 0.
  # The one on (g, h) is bigger but cuts g = 7 more, so the next-worst set
  # puts it first, ahead of size (20260927-9, e2e 025).
  it "breaks a tie in the worst case on the next-worst set before size" do
    conn.exec(<<~SQL)
      CREATE TABLE u (g int, h int);
      INSERT INTO u SELECT CASE WHEN i % 10 = 0 THEN (i / 10) % 100 + 1 ELSE 0 END, i
      FROM generate_series(1, 100000) AS i;
      SET default_statistics_target = 1000;
      ANALYZE u;
      RESET default_statistics_target;
    SQL
    on_g = candidate("u", key: ["g"])
    on_gh = candidate("u", key: %w[g h])
    ranking = ranked("SELECT * FROM u WHERE g = $1 AND h < $2",
                     { slow: %w[7 1000], worst: %w[0 100001] }, [on_g, on_gh])

    expect(ranking.top.map(&:worst_reduction)).to all(be_within(1e-9).of(0.0))
    expect(ranking.top.map(&:candidates)).to eq([[on_gh], [on_g]])
    expect(ranking.top.first.size).to be > ranking.top.last.size
  end

  # With both indexes, the planner uses only one of them.
  it "keeps no combination whose second index the plan never uses" do
    query = "SELECT * FROM t WHERE a = $1"
    sets = { slow: ["5"], typical: ["70000"] }
    ranking = ranked(query, sets, [candidate(key: ["a"]), candidate(key: %w[a c])])
    together = used_together(query, sets, ranking.top.flat_map(&:candidates))

    expect(ranking.top.size).to eq(2)
    expect(together.values.uniq.size).to eq(1)
    expect(together.values.first).to contain_exactly(true, false)
    expect(ranking.combination).to be_nil
  end

  # The index on b helps both branches some, so it ranks first. The ones on
  # a and c each help one branch more. With all three, neither branch uses
  # the one on b, so the third addition, though cheaper, isn't kept.
  it "keeps no combination in which an index it already had goes unused" do
    query = "SELECT a FROM t WHERE b = $1 AND a = $2 UNION ALL SELECT a FROM t WHERE b = $3 AND c = $4"
    sets = { slow: %w[7 7 7 9] }
    on_a = candidate(key: ["a"])
    on_c = candidate(key: ["c"])
    ranking = ranked(query, sets, [on_c, on_a, on_b])

    expect(used_together(query, sets, [on_b, on_a, on_c])).to eq(slow: [false, true, true])
    expect(ranking.combination.candidates).to eq([on_b, on_a])
    expect(ranking.combination.used).to eq(slow: [true, true])
  end

  # Each index helps one branch, and they help in the order of their
  # tables' sizes. The input lists them smallest first.
  let(:branches) do
    "SELECT 1 FROM t WHERE a = $1 UNION ALL SELECT 1 FROM o WHERE x = $2 " \
      "UNION ALL SELECT 1 FROM w WHERE z = $3 UNION ALL SELECT 1 FROM cu WHERE y = $4"
  end
  let(:branch_sets) { { slow: %w[5 5 5 5] } }
  let(:on_a) { candidate(key: ["a"]) }
  let(:on_z) { candidate("w", key: ["z"]) }

  it "keeps the top three and combines at most three indexes, picking the best addition each time" do
    ranking = ranked(branches, branch_sets, [on_y, on_z, on_x, on_a])

    expect(ranking.top.map(&:candidates)).to eq([[on_a], [on_x], [on_z]])
    expect(ranking.combination.candidates).to eq([on_a, on_x, on_z])
    expect(ranking.combination.used).to eq(slow: [true, true, true])
  end

  let(:point) { "SELECT * FROM t WHERE a = $1" }
  let(:point_sets) { { slow: ["5"], typical: ["70000"] } }

  # The wider index's DDL sorts first, so only size puts it second.
  it "breaks a tie in the worst case by size, smallest first" do
    wider = candidate(key: [key("a", :desc), "c"])
    ranking = ranked(point, point_sets, [wider, on_a])

    expect(ranking.top.map(&:worst_reduction).uniq.size).to eq(1)
    expect(wider.to_ddl).to be < on_a.to_ddl
    expect(ranking.top.map(&:candidates)).to eq([[on_a], [wider]])
    expect(ranking.top.map(&:size)).to eq(ranking.top.map(&:size).sort.uniq)
  end

  it "breaks a tie in both the worst case and size by DDL, whatever the order given" do
    descending = candidate(key: [key("a", :desc)])
    rankings = [[descending, on_a], [on_a, descending]].map { |given| ranked(point, point_sets, given) }

    expect(rankings.map { |r| r.top.map(&:worst_reduction).uniq.size }).to eq([1, 1])
    expect(rankings.map { |r| r.top.map(&:size).uniq.size }).to eq([1, 1])
    expect(descending.to_ddl).to be < on_a.to_ddl
    expect(rankings.map { |r| r.top.map(&:ddl) }).to all(eq([[descending.to_ddl], [on_a.to_ddl]]))
  end

  # Adding the index on a or the one on c to the one on b lowers the worst
  # case by the same amount, so DDL decides which pair the greedy step
  # keeps.
  it "combines the same way, whatever the order given" do
    query = "SELECT a FROM t WHERE b = $1 AND a = $2 UNION ALL SELECT a FROM t WHERE b = $3 AND c = $4"
    sets = { slow: %w[7 7 7 9] }
    report = single_test(query, sets, [on_b, on_a, candidate(key: ["c"])])
    rankings = report.results.permutation.map { |results| rank(query, sets, report, results:) }

    expect(rankings.map { |r| r.combination.ddl }).to all(eq([on_b.to_ddl, on_a.to_ddl]))
    expect(rankings.map { |r| r.top.map(&:ddl) }.uniq.size).to eq(1)
    expect(rankings.map { |r| r.combination.costs }.uniq.size).to eq(1)
  end

  # The partial index's predicate holds the sentinel, which t's flag holds
  # for 1% of rows.
  let(:partial_query) do
    "SELECT a FROM t WHERE b = $1 AND flag = '#{sentinel}' UNION ALL SELECT x FROM o WHERE x = $2"
  end
  let(:partial_sets) { { slow: %w[7 5] } }
  let(:partial) { candidate(key: ["b"], predicate: "flag = '#{sentinel}'") }

  it "tags an entry partial when any of its indexes has a predicate" do
    ranking = ranked(partial_query, partial_sets, [partial, on_x])

    expect(ranking.top.to_h { |e| [e.candidates, e.partial] }).to eq([partial] => true, [on_x] => false)
    expect(ranking.combination.candidates).to contain_exactly(partial, on_x)
    expect(ranking.combination.partial).to be(true)
  end

  it "keeps a partial index's predicate out of inspect, though its DDL holds it" do
    ranking = ranked(partial_query, partial_sets, [partial, on_x])

    expect(ranking.combination.ddl.join).to include(sentinel)
    expect(ranking.top.flat_map(&:ddl).join).to include(sentinel)
    expect(ranking.inspect).not_to include(sentinel)
    expect(ranking.to_s).not_to include(sentinel)
    expect(ranking.combination.to_s).not_to include(sentinel)
    expect(ranking.top.first.pretty_inspect).not_to include(sentinel)
  end

  # With $2 false, the plan is a Result that costs nothing, with or without
  # the index.
  it "counts a literal set that costs nothing either way as no reduction" do
    query = "SELECT * FROM t WHERE a = $1 AND $2::boolean"
    sets = { slow: %w[5 true], dead: %w[5 false] }
    report = single_test(query, sets, [on_a])
    dead = [report.baseline, report.results.first].map { |r| r.plans[:dead].total_cost }

    expect(dead).to eq([0.0, 0.0])
    expect(described_class::Cost.new(before: dead[0], after: dead[1]).reduction).to eq(0.0)
    entry = rank(query, sets, report).top.first
    expect(entry.reductions[:dead]).to eq(0.0)
    expect(entry.worst_reduction).to eq(0.0)
  end

  it "refuses literal sets that differ from the baseline's or a result's" do
    report = single_test(point, point_sets, [on_a, candidate(key: %w[a c])])
    other = single_test(point, { slow: ["5"] }, [on_a])
    mismatch = [ArgumentError, "literal sets must match the baseline's and every result's"]

    expect { rank(point, { slow: ["5"] }, report) }.to raise_error(*mismatch)
    expect { rank(point, point_sets, report, results: [*report.results, *other.results]) }
      .to raise_error(*mismatch)
    expect { rank(point, point_sets, other, results: report.results) }.to raise_error(*mismatch)
    expect(leftovers).to eq(clean)
  end

  it "leaves no hypothetical index, prepared statement, or transaction behind" do
    report = single_test(join, join_sets, [on_x, on_y])
    conn.exec("SELECT * FROM hypopg_create_index('CREATE INDEX ON public.o (cid)')")
    ranking = rank(join, join_sets, report)

    expect(ranking.combination.candidates.size).to eq(2)
    expect(leftovers).to eq(clean)
  end

  def rank_error(...)
    rank(...)
    nil
  rescue Quaack::Enclave::SingleCandidateTest::Error => e
    e
  end

  it "raises an error with a rule and SQLSTATE that never quotes a literal, and leaves nothing behind" do
    report = single_test(join, join_sets, [on_x, on_y])
    error = rank_error(join, { slow: ["5", sentinel], typical: %w[70000 70000] }, report)

    expect(error).to have_attributes(rule: :explain_failed, sqlstate: "22P02", cause: nil)
    expect(error.full_message).not_to include(sentinel)
    expect(leftovers).to eq(clean)
  end

  it "refuses a literal that isn't a String without quoting it, even with nothing to combine" do
    report = single_test(point, point_sets, [on_a])
    error = rank_error(point, { slow: ["5"], typical: [Struct.new(:s).new(sentinel)] }, report)

    expect(error).to have_attributes(rule: :bad_literal, sqlstate: nil, cause: nil)
    expect(error.full_message).not_to include(sentinel)
  end

  # The wrapper records, for each hypopg_reset, the DDL of every index
  # created after it, so each list is one measurement's indexes.
  it "never measures a candidate together with itself" do
    recording = Class.new(SimpleDelegator) do
      attr_reader :created

      def exec(sql, *)
        (@created ||= []) << [] if sql.include?("hypopg_reset")
        super
      end

      def exec_params(sql, params, *)
        @created.last << params.first if sql.include?("hypopg_create_index")
        super
      end
    end.new(conn)
    report = single_test(branches, branch_sets, [on_a, on_x, on_z, on_y])
    rank(branches, branch_sets, report, connection: recording)
    measured = recording.created.reject(&:empty?)

    expect(measured.map(&:size).tally).to eq(2 => 3, 3 => 2)
    expect(measured).to all(satisfy { |ddls| ddls.uniq == ddls })
  end

  # The heavy set sorts all of w, so its baseline costs much more. The index
  # on a saves the same amount from both sets, which is a small fraction of
  # the heavy set's cost. The index on z saves less from the light set, but
  # a bigger fraction of it, and saves the sort from the heavy set.
  it "ranks by the fraction of the cost saved, not the amount" do
    query = "SELECT a FROM t WHERE a = $1 UNION ALL (SELECT z FROM w WHERE z <= $2 ORDER BY z)"
    sets = { light: %w[5 10], heavy: %w[5 50000] }
    ranking = ranked(query, sets, [on_a, on_z])
    saved = ranking.top.to_h { |e| [e.candidates.first, e.costs.values.map { |c| c.before - c.after }.min] }

    expect(ranking.top.map(&:candidates)).to eq([[on_z], [on_a]])
    expect(saved[on_a]).to be > saved[on_z] * 2
    expect(ranking.top.map(&:worst_reduction)).to eq(ranking.top.map(&:worst_reduction).sort.reverse)
  end

  # The partial index helps its branch less than the others help theirs,
  # so the greedy step adds it after the best single index.
  it "tags a combination partial when an index added after the first has a predicate" do
    query = "SELECT a FROM t WHERE c <= $1 AND flag = 'closed' UNION ALL SELECT a FROM t WHERE a = $2 " \
            "UNION ALL SELECT x FROM o WHERE x = $3"
    closed = candidate(key: ["c"], predicate: "flag = 'closed'")
    ranking = ranked(query, { slow: %w[20000 5 5] }, [closed, on_x, on_a])

    expect(ranking.combination.candidates.first).to eq(on_a)
    expect(ranking.combination.candidates.drop(1)).to include(closed)
    expect(ranking.combination.partial).to be(true)
  end

  # s = 0 sorts 90,000 rows, so the heavy set's baseline costs most, and
  # the index on a saves the smallest fraction of it. The index on c saves
  # that sort, but only for s = 0: for s = 10, sorting one row is cheaper.
  # The light set comes first, so the plans' first literal set doesn't use
  # the index on c.
  it "keeps a combination whose added index is used for only some literal sets" do
    query = "SELECT a FROM t WHERE a = $1 UNION ALL (SELECT a FROM t WHERE s = $2 ORDER BY c)"
    ranking = ranked(query, { light: %w[5 10], heavy: %w[5 0] }, [candidate(key: ["c"]), on_a])

    expect(ranking.top.first.candidates).to eq([on_a])
    expect(ranking.combination.ddl).to eq([on_a.to_ddl, candidate(key: ["c"]).to_ddl])
    expect(ranking.combination.used).to eq(light: [true, false], heavy: [true, true])
    expect(ranking.combination.worst_reduction).to be > ranking.top.first.worst_reduction
  end

  it "freezes what it returns" do
    ranking = ranked(join, join_sets, [on_x, on_y])
    entries = [*ranking.top, ranking.combination]

    expect([ranking, ranking.top, *entries]).to all(be_frozen)
    expect(entries.flat_map { |e| [e.candidates, e.ddl, e.costs, e.used, *e.used.values, e.canonical_plans] })
      .to all(be_frozen)
  end
end
