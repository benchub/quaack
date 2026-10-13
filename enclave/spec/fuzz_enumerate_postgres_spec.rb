# frozen_string_literal: true

require "quaack/enclave/deadline"
require "quaack/enclave/fuzz"

# rewrite-test's enumerate stage (task 20261012-3, DESIGN.md's rewrite-test):
# after the fuzz search passes, every small world over each table's row
# kinds, in order of weight, so a pass can say no database of up to bound
# rows over the queries' value classes tells the two queries apart.
RSpec.describe Quaack::Enclave::Fuzz::Enumerate do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:fuzz) { Quaack::Enclave::Fuzz }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA s;
      CREATE TABLE s.topics (id integer PRIMARY KEY, posted_at timestamp, kind text NOT NULL);
    SQL
  end

  def both(original, candidate, worlds: 3000, stop: fuzz::StopRule.trials(40))
    fuzz.search(conn, original, candidate, stop:, enumerate: described_class::Limit.worlds(worlds))
  end

  describe "Limit" do
    let(:limit) { described_class::Limit }

    it "runs for 30 seconds unless QUAACKS_ENUMERATE_WORLDS caps it at a count of worlds, and 0 turns it off" do
      expect(limit.from_env({})).to have_attributes(cap: 30, clock: limit::MONOTONIC)
      expect(limit.from_env({ "QUAACKS_ENUMERATE_WORLDS" => "25" })).to have_attributes(cap: 25, clock: nil)
      expect(limit.from_env({ "QUAACKS_ENUMERATE_WORLDS" => "0" })).to be_nil
      expect { limit.from_env({ "QUAACKS_ENUMERATE_WORLDS" => "x" }) }.to raise_error(ArgumentError)
    end

    it "is over once it has tried its count of worlds, or once its seconds have passed" do
      expect([limit.worlds(3).over?(2, nil), limit.worlds(3).over?(3, nil)]).to eq([false, true])
      now = 100.0
      timed = limit.new(cap: 30, clock: -> { now })
      started = timed.start
      now = 129.0
      expect(timed.over?(10_000, started)).to be(false)
      now = 130.0
      expect(timed.over?(0, started)).to be(true)
    end
  end

  # NULLS LAST only matters with a NULL posted_at and a non-NULL one in the
  # same result. The fuzz search, at the specs' 40 trials, draws a NULL in a
  # third of its worlds at most, and this pair's seed misses it.
  it "disproves a wrong rewrite the fuzz search passed, with its size per table, never its rows" do
    original = "SELECT id FROM s.topics WHERE kind = 'news' ORDER BY posted_at DESC NULLS LAST, id DESC LIMIT 10"
    candidate = "SELECT id FROM s.topics WHERE kind = 'news' ORDER BY posted_at DESC, id DESC LIMIT 10"

    result = both(original, candidate)

    expect(result.fuzz).to have_attributes(verdict: :passed)
    expect(result.enumerate).to have_attributes(verdict: :disproved, rule: :value, sizes: [["s", "topics", 2]])
    expect(result.enumerate.worlds).to be_between(1, 2999)
  end

  it "passes a sound rewrite with the most rows of every world it tried, and counts the worlds it compared" do
    result = both("SELECT id FROM s.topics WHERE kind = 'news' AND posted_at > '2024-01-01'",
                  "SELECT id FROM s.topics WHERE posted_at > '2024-01-01' AND kind = 'news'")

    expect(result.fuzz.verdict).to eq(:passed)
    expect(result.enumerate).to have_attributes(verdict: :passed, rule: nil, sizes: [])
    expect(result.enumerate.bound).to be_between(1, 4)
    expect(result.enumerate.worlds).to be_between(1, 3000)
  end

  it "stops at its cap of worlds, and its bound is what it finished" do
    pair = ["SELECT id FROM s.topics WHERE kind = 'news' AND posted_at > '2024-01-01'",
            "SELECT id FROM s.topics WHERE posted_at > '2024-01-01' AND kind = 'news'"]

    small = both(*pair, worlds: 2).enumerate
    large = both(*pair, worlds: 3000).enumerate

    expect(small).to have_attributes(verdict: :untested, worlds: 2, bound: 0)
    expect(large.bound).to be_positive
  end

  # The original fails on an empty kind, which the candidate's constant
  # puts in kind's classes, so a world with one is illegal and never a
  # kill, though the candidate leaves the row out.
  it "never counts a world the original fails on as a kill" do
    result = both("SELECT id FROM s.topics WHERE length(kind) / length(kind) = 1",
                  "SELECT id FROM s.topics WHERE kind > ''")

    expect(result.enumerate).to have_attributes(verdict: :passed, rule: nil)
  end

  # The original fails on every row, so only empty worlds run both.
  it "counts only the worlds both queries ran on" do
    result = both("SELECT id FROM s.topics WHERE length(kind) / 0 = 1", "SELECT id FROM s.topics WHERE false")

    expect(result.fuzz.verdict).to eq(:passed)
    expect(result.enumerate).to have_attributes(verdict: :passed, worlds: 1)
  end

  # An item's owner, out of the footprint, must point back at an item, so
  # the lift can't build it, and no kill on items lifts.
  it "drops a kill that doesn't lift, and never disproves on it" do
    conn.exec(<<~SQL)
      CREATE TABLE s.items (id integer PRIMARY KEY, owner_id integer NOT NULL);
      CREATE TABLE s.owners (id integer PRIMARY KEY, item_id integer NOT NULL REFERENCES s.items);
      ALTER TABLE s.items ADD FOREIGN KEY (owner_id) REFERENCES s.owners;
    SQL

    result = both("SELECT id FROM s.items WHERE id > 1", "SELECT id FROM s.items WHERE id >= 1")

    expect(result.fuzz.verdict).to eq(:passed)
    expect(result.enumerate.rule).to be_nil
    expect(result.enumerate.verdict).not_to eq(:disproved)
  end

  it "runs only after the fuzz search passes" do
    disproved = both("SELECT id FROM s.topics WHERE kind = 'news'", "SELECT id FROM s.topics")
    off = fuzz.search(conn, "SELECT id FROM s.topics WHERE kind = 'news'",
                      "SELECT id FROM s.topics WHERE 'news' = kind", stop: fuzz::StopRule.trials(40), enumerate: nil)

    expect(disproved.fuzz.verdict).to eq(:disproved)
    expect([disproved.enumerate, off.enumerate]).to all(have_attributes(verdict: :untested, worlds: 0, bound: nil))
    expect(off.fuzz.verdict).to eq(:passed)
  end

  # The clock stands still for the fuzz search, and ticks at each check of
  # the deadline once enumerate is running.
  def enumerating(ticks)
    clock = lambda do
      next 0 unless caller_locations.any? { it.path.end_with?("fuzz/enumerate.rb") }

      ticks[0] += 1
    end
    Quaack::Enclave::Deadline.new(ticks[1], clock:)
  end

  def within(deadline, &) = Quaack::Enclave::Deadline.within(deadline, &)

  let(:pair) { ["SELECT id FROM s.topics WHERE kind = 'news'", "SELECT id FROM s.topics WHERE 'news' = kind"] }

  it "is untested when the rewrite's deadline runs out before it finishes a bound, and the fuzz pass stands" do
    result = within(enumerating([0, 1])) { both(*pair) }

    expect(result.fuzz.verdict).to eq(:passed)
    expect(result.enumerate).to have_attributes(verdict: :untested, bound: 0)
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "passes with the bound it finished when the rewrite's deadline runs out later" do
    finished = both(*pair, worlds: 10_000).enumerate
    result = within(enumerating([0, 200])) { both(*pair, worlds: 10_000) }

    expect(result.enumerate).to have_attributes(verdict: :passed, bound: 1)
    expect(result.enumerate.worlds).to be < finished.worlds
  end

  # The bound is true: every world of at most bound rows, each row one of
  # its table's kinds, every child row wired to each parent row or NULL, is
  # one the enumerator gives by the weight it says. A brute force over the
  # same kinds checks it, and that one more row isn't covered.
  describe "the bound" do
    let(:p_id) { "p_id integer REFERENCES s.p" }

    before do
      conn.exec(<<~SQL)
        CREATE TABLE s.p (id integer PRIMARY KEY, a integer);
        CREATE TABLE s.c (cid integer PRIMARY KEY, #{p_id}, b text, d boolean);
      SQL
    end

    let(:queries) do
      ["SELECT c.b FROM s.c LEFT JOIN s.p ON p.id = c.p_id WHERE p.a > 1 AND c.b = 'x' AND c.d",
       "SELECT c.b FROM s.c LEFT JOIN s.p ON p.id = c.p_id WHERE p.a >= 2 AND c.b = 'x' AND c.d"]
    end
    let(:catalog) { fuzz::Catalog.new(conn, fuzz.footprint(queries)) }
    let(:domains) { fuzz::Domains.new(conn, catalog, queries) }
    let(:plan) { fuzz::Generator.new(catalog, domains).plan }
    let(:kinds) { described_class::Kinds.new(catalog, plan, domains) }
    let(:worlds) { described_class::Worlds.new(catalog, plan, domains, kinds) }
    let(:p_table) { catalog.footprint.find { it.name == "p" } }
    let(:c_table) { catalog.footprint.find { it.name == "c" } }

    def kind_columns(table) = kinds.for(table).kinds.first.keys

    # A world as each table's sorted row descriptions: a row's kind cells,
    # and for c the kind cells of the p row it points to, or nil.
    def canonical(rows)
      ps, cs = rows.partition { it.table == p_table }
      by_id = ps.to_h { [it.cells["id"], kind_of(it)] }
      [sorted(ps.map { kind_of(it) }), sorted(cs.map { [kind_of(it), by_id[it.cells["p_id"]]] })]
    end

    def sorted(list) = list.sort_by(&:inspect)

    def kind_of(row) = row.cells.slice(*kind_columns(row.table))

    def yielded(weight)
      (0..weight).flat_map { |w| enum_for(:each_world, w).map { canonical(it) } }.to_set
    end

    def each_world(weight, &) = worlds.each(weight, &)

    # Every world of at most rows rows, at most 4 a table, over the kinds,
    # each c row pointing at one of the p rows, or NULL where p_id allows it.
    def brute_force(rows)
      splits = (0..4).to_a.product((0..4).to_a).select { it.sum <= rows }
      splits.each_with_object(Set.new) do |(np, nc), found|
        kinds.for(p_table).kinds.repeated_combination(np) { |ps| wirings(ps, nc, found) }
      end
    end

    def wirings(parents, count, found)
      kinds.for(c_table).kinds.repeated_combination(count) do |children|
        ((p_id.include?("NOT NULL") ? [] : [nil]) + parents).repeated_permutation(count) do |wires|
          found << [parents.sort_by(&:inspect), children.zip(wires).sort_by(&:inspect)]
        end
      end
    end

    it "covers every world of up to bound rows by the weight it finished, and not every world of one more" do
      weight = 6
      bound = worlds.bound(weight)
      got = yielded(weight)

      expect([kind_columns(p_table), kind_columns(c_table)]).to eq([%w[a], %w[b d]])
      expect(bound).to eq(2)
      expect(brute_force(bound) - got).to be_empty
      expect(brute_force(bound + 1) - got).not_to be_empty
    end

    # Task 20261012-3's review (B1): a child whose key can't be NULL has
    # rows only in a world that has a parent row for it.
    context "when the child's foreign key is NOT NULL" do
      let(:p_id) { "p_id integer NOT NULL REFERENCES s.p" }

      it "covers every world of up to bound rows, children wired only to parents, and not every one of one more" do
        weight = 6
        bound = worlds.bound(weight)
        got = yielded(weight)

        expect(bound).to eq(2)
        expect(brute_force(bound).count { it.last.any? }).to be_positive
        expect(brute_force(bound) - got).to be_empty
        expect(brute_force(bound + 1) - got).not_to be_empty
        expect(got.flat_map(&:last).map(&:last)).not_to include(nil)
      end
    end

    it "gives a bound of 0 before it finishes any weight, and never more than 4" do
      expect(worlds.bound(-1)).to eq(0)
      expect(worlds.bound(worlds.max_weight)).to eq(4)
    end
  end

  # id is read, and its own classes are few, so a world of more rows than
  # that would repeat one: the repeat gets a fresh id, as the fuzz search's
  # rows do, and the world still loads.
  it "gives a row that repeats a unique key's values a fresh one, so worlds of more rows than classes load" do
    sql = "SELECT id FROM s.topics WHERE kind = 'news'"
    catalog = fuzz::Catalog.new(conn, fuzz.footprint([sql]))
    domains = fuzz::Domains.new(conn, catalog, [sql])
    plan = fuzz::Generator.new(catalog, domains).plan
    worlds = described_class::Worlds.new(catalog, plan, domains, described_class::Kinds.new(catalog, plan, domains))
    four = worlds.enum_for(:each, 4).select { it.size == 4 }
    ids = described_class::Kinds.new(catalog, plan, domains).domains(catalog.footprint.first)["id"]

    expect(ids.size).to be < 4
    expect(four).not_to be_empty
    expect(four.map { |rows| rows.map { it.cells["id"] }.uniq.size }).to all(eq(4))
  end

  describe "Kinds" do
    before do
      conn.exec("CREATE TABLE s.wide (id integer PRIMARY KEY, a integer, b integer, c integer, d integer)")
      conn.exec("CREATE TABLE s.flags (id integer PRIMARY KEY, done boolean)")
    end

    let(:flags) { "SELECT id FROM s.flags WHERE done" }

    let(:narrow) { "SELECT id FROM s.topics WHERE kind = 'news' AND posted_at > '2024-01-01'" }
    let(:wide) { "SELECT id FROM s.wide WHERE a = 1 AND b = 2 AND c = 3 AND d = 4" }

    def kinds_for(sql)
      catalog = fuzz::Catalog.new(conn, fuzz.footprint([sql]))
      domains = fuzz::Domains.new(conn, catalog, [sql])
      plan = fuzz::Generator.new(catalog, domains).plan
      kinds = described_class::Kinds.new(catalog, plan, domains)
      [kinds, catalog.footprint.first]
    end

    it "puts a base row first, then each single-column change of it, then the rest of the full product" do
      kinds, table = kinds_for(flags)
      domains = kinds.domains(table)
      kind = kinds.for(table)
      base = kind.kinds.first
      singles = kind.kinds[1...kind.base]

      expect(base).to eq("id" => "1", "done" => "t")
      expect(singles).to all(satisfy { |k| k.one? { |c, v| base[c] != v } })
      expect(singles.size).to eq(domains.sum { |_, values| values.size - 1 })
      expect(kind.kinds.size).to eq(domains.values.map(&:size).reduce(:*))
      expect(kind.kinds.map { kind.cost(kind.kinds.index(it)) }.tally.keys).to eq([0, 1, 2])
    end

    it "gives a column NULL when it may hold one, and the queries' own constants first" do
      kinds, table = kinds_for(narrow)

      expect(kinds.domains(table)["posted_at"]).to include(nil)
      expect(kinds.domains(table)["kind"]).not_to include(nil)
      expect(kinds.domains(table)["kind"].first).to eq("news")
      expect(kinds.domains(table).values).to all(satisfy { it.compact.size <= described_class::Kinds::DOMAIN })
    end

    it "covers every pair of two columns' values when the full product is too many kinds" do
      kinds, table = kinds_for(wide)
      domains = kinds.domains(table)
      rows = kinds.for(table).kinds
      pairs = domains.keys.combination(2).flat_map do |x, y|
        domains[x].product(domains[y]).map { [x, it[0], y, it[1]] }
      end

      expect(domains.values.map(&:size).reduce(:*)).to be > described_class::Kinds::MAX_KINDS
      expect(rows.size).to be < domains.values.map(&:size).reduce(:*)
      expect(pairs.reject { |x, a, y, b| rows.any? { it[x] == a && it[y] == b } }).to be_empty
    end
  end
end
