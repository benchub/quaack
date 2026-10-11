# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"

# Task 20261011-4: RowSet finds collisions and parents by hash lookups, not by
# scanning every row of the table, and decides exactly as the scans did.
RSpec.describe Quaack::Enclave::Scenarios::RowSet do
  # The scans RowSet used before 20261011-4, kept as the reference. It
  # shares evaluate (and so Postgres) with RowSet.
  slow = Class.new(described_class) do
    def initialize(...)
      super
      @rows = Hash.new { |h, k| h[k] = [] }
    end

    def add?(group_rows)
      fresh = group_rows.reject { |r| @rows[r.table].include?(r) }.uniq
      fresh.each_with_index do |r, i|
        next @rows[r.table] << r unless collides?(r) || orphan?(r, group_rows)

        fresh.first(i).each { @rows[it.table].delete(it) }
        return false
      end
      true
    end

    def add_any?(tries)
      tried = []
      tries.each do |rows|
        break if rows.nil? || tried.include?(rows)
        return true if add?(rows)

        tried << rows
      end
      false
    end

    def parents_of(rows)
      found = []
      queue = rows.dup
      while (row = queue.shift)
        outside_parents(row, rows).each do |parent|
          next if found.include?(parent) || rows.include?(parent)

          found << parent
          queue << parent
        end
      end
      found
    end

    def in_order(tables) = tables.flat_map { |t| @rows[t] }

    private

    def outside_parents(row, rows)
      @schema.constraints(row.table).foreign_keys.filter_map do |key|
        wanted = values(row, key.columns)
        next if rows.any? { |r| r.table == key.parent && values(r, key.parent_columns) == wanted }

        parent(row, key)
      end
    end

    def parent(row, key)
      wanted = values(row, key.columns)
      @rows[key.parent].find { values(it, key.parent_columns) == wanted } unless wanted.any?(&:nil?)
    end

    def orphan?(row, group_rows)
      @schema.constraints(row.table).foreign_keys.any? do |fk|
        key = values(row, fk.columns)
        key.none?(&:nil?) && parent(row, fk).nil? &&
          group_rows.none? { |r| r.table == fk.parent && values(r, fk.parent_columns) == key }
      end
    end

    def collides?(row)
      constraints = @schema.constraints(row.table)
      constraints.uniques.any? do |columns|
        clash?(row, constraints.nulls_not_distinct.include?(columns)) { |r| values(r, columns) }
      end || constraints.expressions.any? do |index|
        clash?(row, index.nulls_not_distinct) { |r| evaluate(r, index) }
      end
    end

    def clash?(row, nulls_collide)
      key = yield(row)
      return true if key == :error
      return false if key.any?(&:nil?) && !nulls_collide

      @rows[row.table].any? { |other| yield(other) == key }
    end

    def values(row, columns) = columns.map { |c| row.columns.index(c)&.then { |i| row.values[i] } }
  end

  let(:conn) { racetrack_and_arena.arena.connection }
  let(:names) { %w[p c g] }
  let(:tables) { names.map { Quaack::Enclave::TableName.new(schema: "fx", name: it) } }
  let(:schema) do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.p (id integer PRIMARY KEY, t integer, code text UNIQUE NULLS NOT DISTINCT,
                         UNIQUE (t, id));
      CREATE TABLE fx.c (id integer PRIMARY KEY, p_id integer REFERENCES fx.p, t integer, a integer, b integer,
                         email text, UNIQUE (a, b), FOREIGN KEY (t, p_id) REFERENCES fx.p (t, id));
      CREATE UNIQUE INDEX ON fx.c (lower(email));
      CREATE TABLE fx.g (id integer PRIMARY KEY, c_id integer REFERENCES fx.c, k integer);
      CREATE UNIQUE INDEX ON fx.g (k, (id % 3)) NULLS NOT DISTINCT;
    SQL
    Quaack::Enclave::ArenaSchema.load_closure(conn, tables)
  end

  def fixture_row(name, **pairs)
    Quaack::Enclave::ArenaRunner::FixtureRow.new(table: Quaack::Enclave::TableName.new(schema: "fx", name:),
                                                 columns: pairs.keys.map(&:to_s), values: pairs.values)
  end

  def pick(rng, size) = rng.rand(4).zero? ? nil : rng.rand(size).to_s

  def random_row(rng)
    case rng.rand(3)
    when 0 then fixture_row("p", id: rng.rand(5).to_s, t: pick(rng, 2), code: pick(rng, 3))
    when 1 then random_child(rng)
    else fixture_row("g", id: rng.rand(6).to_s, c_id: pick(rng, 6), k: pick(rng, 2))
    end
  end

  def random_child(rng)
    fixture_row("c", id: rng.rand(6).to_s, p_id: pick(rng, 5), t: pick(rng, 2), a: pick(rng, 3), b: pick(rng, 2),
                     email: [nil, "x", "X", "y"].sample(random: rng))
  end

  def random_group(rng) = Array.new(1 + rng.rand(3)) { random_row(rng) }

  it "decides, orders, and finds parents exactly as the scans did, over random cases" do
    evaluated = {}
    200.times do |seed|
      rng = Random.new(seed)
      fast = described_class.new(schema, conn, evaluated)
      ref = slow.new(schema, conn, evaluated)
      30.times do
        if rng.rand(3).zero?
          tries = Array.new(1 + rng.rand(3)) { rng.rand(5).zero? ? nil : random_group(rng) }
          tries << tries.first if rng.rand(4).zero?
          expect(fast.add_any?(tries)).to eq(ref.add_any?(tries)), "seed #{seed}"
        else
          group = random_group(rng)
          expect(fast.add?(group)).to eq(ref.add?(group)), "seed #{seed}"
        end
        expect(fast.in_order(tables)).to eq(ref.in_order(tables)), "seed #{seed}"
        # A probe sometimes holds a row already here.
        probe = random_group(rng) + ref.in_order(tables).sample(rng.rand(2), random: rng)
        expect(fast.parents_of(probe)).to eq(ref.parents_of(probe)), "seed #{seed}"
      end
    end
  end

  # Work is counted as key computations (values and evaluate calls), not
  # time. The scans compute every earlier row's keys on every add.
  it "computes a near-linear number of keys as the rows grow" do
    counts = [500, 2000].map do |n|
      calls = 0
      counter = Module.new do
        define_method(:values) { |*a| (calls += 1) && super(*a) }
        define_method(:evaluate) { |*a| (calls += 1) && super(*a) }
        private :values, :evaluate
      end
      set = described_class.new(schema, conn)
      set.singleton_class.prepend(counter)
      n.times do |i|
        p = fixture_row("p", id: i.to_s, t: "1", code: "c#{i}")
        c = fixture_row("c", id: i.to_s, p_id: i.to_s, t: "1", a: i.to_s, b: "0", email: "e#{i}")
        g = fixture_row("g", id: i.to_s, c_id: i.to_s, k: i.to_s)
        expect(set.add?([p, c, g])).to be(true)
        set.add?([fixture_row("p", id: (n + i).to_s, code: "c#{i}")])
      end
      expect(set.parents_of([fixture_row("g", id: "x", c_id: (n - 1).to_s)]).size).to eq(2)
      calls
    end
    expect(counts[1]).to be < counts[0] * 5
  end
end
