# frozen_string_literal: true

require "quaack/enclave/fuzz"
require "quaack/enclave/counterexamples"
require "quaack/enclave/result_comparison"
require "quaack/enclave/production_comparison"
require "quaack/enclave/constant_value"

# Task 20261110-13: the queries ResultComparison and Exercised derive from
# the $n form keep the $n, carry the Binding, and match the literal form's
# once each $n is bound; and the analyses read a $n's constant through the
# Binding that ResultComparison.compare, its load orders and rerun, and
# Fuzz.search hand on.
RSpec.describe "the arena's queries on the $n form" do
  let(:result_comparison) { Quaack::Enclave::ResultComparison }
  let(:shape_class) { result_comparison::Shape }

  before { shape_class.forget }

  def binding_for(sql, values)
    map = values.each_with_index.to_h { |(value, type), i| ["$#{i + 1}", { "value" => value, "type" => type }] }
    Quaack::Enclave::Redaction.binding(sql, map)
  end

  # sql with each $n replaced by the constant its binding stands for, so
  # it can be set beside the literal form's.
  def inline(sql, binding)
    tree = PgQuery.parse(sql).tree
    Quaack::Enclave::Counterexamples.replace_params(tree) do |param|
      PgQuery::Node.new(a_const: Quaack::Enclave::ConstantValue.from_node(param, binding))
    end
    PgQuery.deparse(tree)
  end

  let(:literal) do
    "SELECT o.id, o.total FROM public.orders o WHERE o.total * 1.5 > 3 ORDER BY o.total LIMIT 5 OFFSET 0"
  end
  let(:placeholders) do
    "SELECT o.id, o.total FROM public.orders o WHERE o.total * $1 > $2 ORDER BY o.total LIMIT $3 OFFSET $4"
  end
  let(:binding) { binding_for(placeholders, [%w[1.5 numeric], %w[3 integer], %w[5 integer], %w[0 integer]]) }

  describe "Shape" do
    it "reads a $n OFFSET of 0 through its binding, so the LIMIT cuts one end only" do
      shape = shape_class.parse(placeholders, :original, binding:)

      expect([shape.offset, shape.cut_both_ends?]).to eq([0, false])
      expect(shape_class.parse(literal, :original).cut_both_ends?).to be(false)
    end

    it "keeps a Shape with a binding apart from one without" do
      shape_class.parse(placeholders, :original, binding:)

      expect(shape_class.parse(placeholders, :original).offset).to be_nil
    end

    it "derives queries that keep the $n and match the literal form's once bound" do
      shape = shape_class.parse(placeholders, :original, binding:)
      plain = shape_class.parse(literal, :original)
      derived = lambda { |s|
        [s.without_limit, s.with_tiebreaker([1]), s.with_tiebreaker([1], limited: false), s.through_window([1]),
         s.probe]
      }

      expect(derived.call(shape)).to all(include("$1"))
      normalized = derived.call(plain).map { |sql| PgQuery.deparse(PgQuery.parse(sql).tree) }
      expect(derived.call(shape).map { inline(it, binding) }).to eq(normalized)
    end

    it "carries the binding to the Shape of its forced picks" do
      sql = "SELECT DISTINCT ON (o.status) o.id FROM public.orders o ORDER BY o.status LIMIT $1 OFFSET $2"
      bound = binding_for(sql, [%w[5 integer], %w[0 integer]])
      forced = result_comparison::Picks.forced(shape_class.parse(sql, :original, binding: bound), false)

      expect([forced.binding, forced.offset]).to eq([bound, 0])
    end
  end

  describe "Exercised's loosened queries" do
    it "keep the $n and match the literal form's once bound" do
      atoms = lambda { |sql|
        Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: Class.new do
          def fetch(*)
            %w[id total]
          end
        end.new)
      }
      loosened = ->(sql) { atoms.call(sql).map { Quaack::Enclave::PredicateAtoms.with_true(PgQuery.parse(sql), it) } }

      expect(loosened.call(placeholders)).to all(include("$3"))
      expect(loosened.call(placeholders).map { inline(it, binding) })
        .to eq(loosened.call(literal).map { PgQuery.deparse(PgQuery.parse(it).tree) })
    end
  end

  # The comparisons on the arena hand the binding to every Shape they parse.
  describe "the comparisons' Shapes" do
    let(:conn) { racetrack_and_arena.arena.connection }
    let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
    # The arena still runs SQL as text until stage 3, so the queries that
    # run hold no $n; the binding only has to reach their Shapes.
    let(:original) { "SELECT 1 AS n" }
    let(:bound) { binding_for("SELECT 1 LIMIT $1 OFFSET $2", [%w[5 integer], %w[0 integer]]) }

    it "ResultComparison.compare parses both with the binding" do
      allow(shape_class).to receive(:parse).and_call_original

      runner.with_fixture([]) do |tx|
        result_comparison.compare(tx, original: "SELECT 1 AS n", candidate: "SELECT 1 AS n", binding: bound)
      end

      expect(shape_class).to have_received(:parse).with("SELECT 1 AS n", :original, binding: bound)
      expect(shape_class).to have_received(:parse).with("SELECT 1 AS n", :candidate, binding: bound)
    end

    it "compare_in_load_orders and the original's rerun parse it with the binding" do
      allow(shape_class).to receive(:parse).and_call_original
      result_comparison.compare_in_load_orders(runner, [], original:, candidate: original, binding: bound)
      expect(shape_class).to have_received(:parse).with(original, :candidate, binding: bound)

      shape_class.forget
      Quaack::Enclave::ResultComparison::OriginalRerun.fails?(runner, [], "SELECT 2 AS n", binding: bound)
      expect(shape_class).to have_received(:parse).with("SELECT 2 AS n", :candidate, binding: bound)
    end

    it "ProductionComparison parses both with the binding" do
      allow(shape_class).to receive(:parse).and_call_original

      Quaack::Enclave::ProductionComparison.compare(connection: conn, original: "SELECT 3 AS n",
                                                    candidate: "SELECT 3 AS n", params: [], timeout_ms: 10_000,
                                                    binding: bound)

      expect(shape_class).to have_received(:parse).with("SELECT 3 AS n", :original, binding: bound)
      expect(shape_class).to have_received(:parse).with("SELECT 3 AS n", :candidate, binding: bound)
    end

    it "Fuzz.search's unjudged check, Session and Domains get the binding" do
      conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id int PRIMARY KEY, points numeric)")
      # Its own literal, since the arena runs text until stage 3: the
      # binding only has to reach each part.
      # max is a pick (Picks), so every trial goes to the official compare.
      sql = "SELECT max(i.points) FROM fx.items i WHERE 100 / i.points > 2"
      allow(shape_class).to receive(:parse).and_call_original
      allow(Quaack::Enclave::Fuzz::Domains).to receive(:new).and_call_original
      allow(Quaack::Enclave::Fuzz::Reach).to receive(:worst_case?).and_call_original
      allow(Quaack::Enclave::Fuzz).to receive(:unjudged?).and_call_original
      allow(result_comparison::Picks).to receive(:any?).and_call_original
      allow(result_comparison).to receive(:compare).and_call_original
      Quaack::Enclave::Fuzz.run(conn, sql, sql, stop: Quaack::Enclave::Fuzz::StopRule.trials(1), binding: bound)

      expect(Quaack::Enclave::Fuzz).to have_received(:unjudged?).with(sql, sql, bound)
      expect(shape_class).to have_received(:parse).with(sql, :candidate, binding: bound).at_least(:twice)
      expect(result_comparison::Picks).to have_received(:any?).with(sql, sql, binding: bound)
      expect(result_comparison).to have_received(:compare).with(satisfy { |tx|
        tx.binding == bound
      }, original: sql, candidate: sql)
                                                          .at_least(:once)
      expect(Quaack::Enclave::Fuzz::Domains).to have_received(:new).with(conn, anything, [sql, sql], binding: bound)
      expect(Quaack::Enclave::Fuzz::Reach).to have_received(:worst_case?).with(sql, bound)
    ensure
      conn.exec("DROP SCHEMA IF EXISTS fx CASCADE")
    end
  end

  # A threshold's solutions come from a $n's value too, through Domains'
  # Tree and Facts.
  describe "Fuzz::Domains" do
    let(:conn) { racetrack_and_arena.arena.connection }

    before { conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id int PRIMARY KEY, points numeric)") }
    after { conn.exec("DROP SCHEMA IF EXISTS fx CASCADE") }

    def values(sql, binding = nil)
      footprint = Quaack::Enclave::Fuzz.send(:footprint, [sql])
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, footprint)
      Quaack::Enclave::Fuzz::Domains.new(conn, catalog, [sql], binding:).values(footprint.first, "points")
    end

    it "solves a $n threshold as it solves the literal one" do
      sql = "SELECT i.id FROM fx.items i WHERE 100 / i.points > $1"
      bound = binding_for(sql, [%w[3 integer]])

      expect(values("SELECT i.id FROM fx.items i WHERE 100 / i.points > 3")).to include("33.3333333333333333")
      expect(values(sql, bound)).to include("33.3333333333333333")
      expect(values(sql)).not_to include("33.3333333333333333")
    end
  end

  # Task 20261110-15: ValuePools reads a $n side of a pooled atom through
  # the binding, so a column's pool, and its literal's neighbours, are the
  # same on both forms.
  describe "ValuePools on the $n form" do
    let(:conn) { racetrack_and_arena.arena.connection }

    before { conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id int PRIMARY KEY, points numeric, name text)") }
    after { conn.exec("DROP SCHEMA IF EXISTS fx CASCADE") }

    def values(sql, column, binding = nil)
      footprint = Quaack::Enclave::Fuzz.send(:footprint, [sql])
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, footprint)
      Quaack::Enclave::Fuzz::Domains.new(conn, catalog, [sql], binding:).values(footprint.first, column)
    end

    it "gives a compared column the same values as the literal form" do
      literal = "SELECT i.id FROM fx.items i WHERE i.points >= 7.5 AND i.name LIKE 'ab%'"
      sql = "SELECT i.id FROM fx.items i WHERE i.points >= $1 AND i.name LIKE $2"
      bound = binding_for(sql, [%w[7.5 numeric], %w[ab% unknown]])

      expect(values(sql, "points", bound)).to eq(values(literal, "points"))
      expect(values(sql, "name", bound)).to eq(values(literal, "name"))
      expect(values(sql, "points", bound)).to include("7.5", "6.5", "8.5")
      expect(values(sql, "name", bound)).to include("AB%", "ab")
    end

    it "sorts each pool's values the same way, the probe's $1 apart from the query's" do
      pools = lambda do |sql, binding = nil|
        parse = PgQuery.parse(sql)
        schema = Quaack::Enclave::Fuzz::Catalog.new(conn, Quaack::Enclave::Fuzz.send(:footprint, [sql])).schema
        atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: schema.column_names)
        Quaack::Enclave::ValuePools.build(conn, parse, atoms, schema, binding:).transform_values(&:to_h)
      end
      sql = "SELECT i.id FROM fx.items i WHERE i.points * $1 >= $2 AND i.name = $3"
      bound = binding_for(sql, [%w[2 integer], %w[7.5 numeric], %w[ab unknown]])
      literal = pools.call("SELECT i.id FROM fx.items i WHERE i.points * 2 >= 7.5 AND i.name = 'ab'")

      expect(pools.call(sql, bound)).to eq(literal)
      expect(literal.values.map { it[:satisfying] }).to all(be_any)
    end

    # 20261110-15's review: a $n in a list, a negative cast one, and NULL.
    it "reads a $n in an IN list, a negative one under a cast, and a NULL as the literals" do
      pools = lambda do |sql, binding = nil|
        parse = PgQuery.parse(sql)
        schema = Quaack::Enclave::Fuzz::Catalog.new(conn, Quaack::Enclave::Fuzz.send(:footprint, [sql])).schema
        atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: schema.column_names)
        Quaack::Enclave::ValuePools.build(conn, parse, atoms, schema, binding:).transform_values(&:to_h)
      end
      sql = "SELECT i.id FROM fx.items i WHERE i.id IN ($1, $2) AND i.points > $3::numeric " \
            "AND i.name IS DISTINCT FROM $4"
      bound = binding_for(sql, [%w[4 integer], %w[9 integer], %w[-2.5 unknown], [nil, "unknown"]])
      literal = pools.call("SELECT i.id FROM fx.items i WHERE i.id IN (4, 9) AND i.points > '-2.5'::numeric " \
                           "AND i.name IS DISTINCT FROM NULL")

      expect(pools.call(sql, bound)).to eq(literal)
      expect(literal.values.first[:satisfying]).to include("4", "9")
    end

    # 20261110-13's review: Domains' Dictionary reads a $n's constant too,
    # for a column the queries read but don't compare.
    it "gives a read column the $n's constant through the Dictionary" do
      literal = "SELECT i.name FROM fx.items i WHERE i.points >= 7.5"
      sql = "SELECT i.name FROM fx.items i WHERE i.points >= $1"
      bound = binding_for(sql, [%w[7.5 numeric]])

      expect(values(literal, "name")).to include("7.5")
      expect(values(sql, "name", bound)).to include("7.5")
    end
  end

  # Task 20261110-14: the arena runs $n SQL with the Binding's values as
  # parameters, each typed as its literal was.
  describe "ArenaRunner::Typed" do
    let(:conn) { racetrack_and_arena.arena.connection }
    let(:typed_class) { Quaack::Enclave::ArenaRunner::Typed }

    it "types a numeric $n numeric, an unused integer integer, and an untyped one nothing types text" do
      sql = "SELECT concat($3, 'x'), 2 * $1"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: %w[numeric integer unknown unknown],
                                                      values: %w[1.5 7 a z])
      params = typed_class.new(bound).params(conn, sql)

      expect(params).to eq([{ value: "1.5", type: 1700 }, { value: "7", type: 23 }, { value: "a", type: 25 },
                            { value: "z", type: 25 }])
      expect(conn.exec_params(sql, params).values).to eq([%w[ax 3.0]])
    end

    it "keeps an open transaction usable when a try fails, and leaves no prepared statement" do
      sql = "SELECT concat($1, 'x')"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["unknown"], values: ["a"])
      conn.exec("BEGIN")
      typed_class.new(bound).params(conn, sql)

      expect(conn.exec("SELECT count(*) FROM pg_prepared_statements").getvalue(0, 0)).to eq("0")
    ensure
      conn.exec("ROLLBACK")
    end

    it "runs an ArenaRunner's queries with the binding, which its Transaction hands to compare" do
      sql = "SELECT 2 * $1 AS n"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      runner = Quaack::Enclave::ArenaRunner.new(conn, binding: bound)

      rows, handed = runner.with_fixture([]) { |tx| [tx.query(sql).rows, tx.binding] }

      expect([rows, handed]).to eq([[["3.0"]], bound])
    end

    it "leaves the types to Postgres when the PREPARE fails, raising nothing" do
      bound = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT $1", types: ["integer"], values: ["7"])

      expect(typed_class.new(bound).params(conn, "SELECT no_such_column, $1")).to eq([{ value: "7", type: 0 }])
    end

    # Task 20261112-090000-1: a PREPARE that fails cleanly fails the same
    # way every time, so its fallback is kept, and a second call doesn't
    # PREPARE again.
    it "keeps the fallback when the PREPARE fails in a clean transaction, which stays usable" do
      sql = "SELECT no_such_column, $1"
      bound = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT $1", types: ["integer"], values: ["7"])
      typed = typed_class.new(bound)
      prepares = []
      allow(conn).to(receive(:exec).and_wrap_original do |m, q|
        prepares << q if q.start_with?("PREPARE")
        m.call(q)
      end)
      conn.exec("BEGIN")

      first = typed.params(conn, sql)
      state = conn.transaction_status
      second = typed.params(conn, sql)

      expect([first, second, state, prepares.size]).to eq(([[{ value: "7", type: 0 }]] * 2) + [PG::PQTRANS_INTRANS, 1])
      expect(conn.exec("SELECT 1").getvalue(0, 0)).to eq("1")
    ensure
      conn.exec("ROLLBACK")
    end

    # A PREPARE lost to the connection, forced here at the connection, may
    # work next time, so its fallback isn't kept.
    it "tries the PREPARE again after it failed on the connection" do
      sql = "SELECT 2 * $1"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      typed = typed_class.new(bound)
      lost = false
      allow(conn).to(receive(:exec).and_wrap_original do |m, q|
        if q.start_with?("PREPARE") && !lost
          lost = true
          raise PG::ConnectionBad, "gone"
        end
        m.call(q)
      end)

      expect([typed.params(conn, sql), typed.params(conn, sql)]).to eq([[{ value: "1.5", type: 0 }],
                                                                        [{ value: "1.5", type: 1700 }]])
    end

    # Task 20261112-100000-1: a PREPARE that fails with a SQLSTATE that
    # means the session failed, forced here at the connection, may work
    # next time, so its fallback isn't kept.
    %w[08006 57014].each do |code|
      it "tries the PREPARE again after it failed with session-failure SQLSTATE #{code}" do
        sql = "SELECT 2 * $1"
        bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
        typed = typed_class.new(bound)
        prepares = 0
        allow(conn).to(receive(:exec).and_wrap_original do |m, q|
          if q.start_with?("PREPARE")
            prepares += 1
            if prepares == 1
              error = PG::Error.new("failed")
              allow(error).to receive(:result).and_return(instance_double(PG::Result, error_field: code))
              raise error
            end
          end
          m.call(q)
        end)

        first = typed.params(conn, sql)
        typed.params(conn, sql)

        expect([first, prepares]).to eq([[{ value: "1.5", type: 0 }], 2])
      end
    end

    it "declares an unused untyped $n text up front, so one PREPARE does" do
      sql = "SELECT 1 + $1"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: %w[integer unknown], values: %w[1 z])
      prepares = []
      allow(conn).to(receive(:exec).and_wrap_original do |m, q|
        prepares << q if q.start_with?("PREPARE")
        m.call(q)
      end)

      expect(typed_class.new(bound).params(conn, sql)).to eq([{ value: "1", type: 23 }, { value: "z", type: 25 }])
      expect(prepares.size).to eq(1)
    end

    it "fails a query in an aborted transaction with an ArenaRunner::Error that carries only its SQLSTATE" do
      sql = "SELECT 2 * $1 AS n"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      runner = Quaack::Enclave::ArenaRunner.new(conn, binding: bound)

      error = runner.with_fixture([]) do |tx|
        expect { tx.query("SELECT 1 / 0") }.to raise_error(Quaack::Enclave::ArenaRunner::Error)
        tx.query(sql)
      rescue Quaack::Enclave::ArenaRunner::Error => e
        e
      end

      expect(error).to have_attributes(rule: :query_failed, sqlstate: "25P02", index: 1)
      expect(error.cause).to be_nil
    end

    # A Postgres error reading the types back, such as a lost connection's,
    # forced here at the connection, mustn't leave raw: the query runs
    # with its types left to Postgres, and fails through the runner's own
    # handling.
    it "fails the query through the runner, with only its SQLSTATE, when reading the types back fails" do
      sql = "SELECT 2 * $1 AS n"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      allow(conn).to receive(:exec_params).and_wrap_original do |m, q, *rest|
        raise PG::ConnectionBad, "gone" if q == typed_class::TYPES_SQL

        m.call(q, *rest)
      end

      runner = Quaack::Enclave::ArenaRunner.new(conn, binding: bound)

      # Untyped, 2 * $1 takes the integer's type, and 1.5 fails it.
      expect do
        runner.with_fixture([]) do |tx|
          tx.query(sql)
        end
      end.to raise_error(Quaack::Enclave::ArenaRunner::Error) { |e|
               expect([e.rule, e.sqlstate, e.cause]).to eq([:query_failed, "22P02", nil])
             }
    end

    # Task 20261110-17: a query sent in an aborted transaction can't be
    # typed, but that mustn't stick: the next world runs it typed.
    it "types a query again in a later world after an aborted transaction left it untyped" do
      sql = "SELECT 2 * $1 AS n"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      runner = Quaack::Enclave::ArenaRunner.new(conn, binding: bound)

      runner.with_fixture([]) do |tx|
        expect { tx.query("SELECT 1 / 0") }.to raise_error(Quaack::Enclave::ArenaRunner::Error)
        expect { tx.query(sql) }.to raise_error(Quaack::Enclave::ArenaRunner::Error)
      end

      expect(runner.with_fixture([]) { |tx| tx.query(sql).rows }).to eq([["3.0"]])
    end

    # A real Postgres error reading the types back, in a transaction, is
    # rolled back to a savepoint, so the caller's transaction stays usable.
    it "keeps the transaction usable when reading the types back fails in Postgres" do
      sql = "SELECT 2 * $1 AS n"
      bound = Quaack::Enclave::Redaction::Binding.new(sql:, types: ["numeric"], values: ["1.5"])
      allow(conn).to receive(:exec_params).and_wrap_original do |m, q, *rest|
        q == typed_class::TYPES_SQL ? m.call("SELECT 1 / 0", []) : m.call(q, *rest)
      end
      conn.exec("BEGIN")
      params = typed_class.new(bound).params(conn, sql)

      expect([params, conn.transaction_status]).to eq([[{ value: "1.5", type: 0 }], PG::PQTRANS_INTRANS])
    ensure
      conn.exec("ROLLBACK")
    end

    it "leaves the types to Postgres when the query doesn't parse, raising nothing" do
      bound = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT $1", types: ["integer"], values: ["7"])

      expect(typed_class.new(bound).params(conn, "SELECT $1 FROM")).to eq([{ value: "7", type: 0 }])
    end

    it "gives no parameters with no binding" do
      expect(typed_class.new(nil).params(conn, "SELECT 1")).to eq([])
    end

    it "keeps the values out of inspect" do
      bound = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT $1", types: ["unknown"], values: ["s3cret"])

      expect(typed_class.new(bound).inspect).not_to include("s3cret")
    end
  end

  describe "the fuzz search's other queries on the $n form" do
    let(:conn) { racetrack_and_arena.arena.connection }

    before { conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id int PRIMARY KEY, qty int)") }
    after { conn.exec("DROP SCHEMA IF EXISTS fx CASCADE") }

    it "Differ finds the same loosened query differing as on the literal form" do
      differing = lambda do |original, loosened, typed|
        conn.exec("BEGIN; INSERT INTO fx.items VALUES (1, 1), (2, 3)")
        Quaack::Enclave::Fuzz::Differ.differing(conn, original, [loosened], *typed)
      ensure
        conn.exec("ROLLBACK")
      end
      sql = "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2"
      typed = Quaack::Enclave::ArenaRunner::Typed.new(binding_for(sql, [%w[1.5 numeric], %w[3 integer]]))

      expect(differing.call("SELECT i.id FROM fx.items i WHERE i.qty * 1.5 > 3",
                            "SELECT i.id FROM fx.items i WHERE true", [])).to eq([0])
      expect(differing.call(sql, "SELECT i.id FROM fx.items i WHERE true", [typed])).to eq([0])
    end

    it "Differ's one-statement multiset check runs on the $n form, and Session hands it the binding" do
      sql = "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2"
      bound = binding_for(sql, [%w[1.5 numeric], %w[3 integer]])
      typed = Quaack::Enclave::ArenaRunner::Typed.new(bound)
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, Quaack::Enclave::Fuzz.send(:footprint, [sql]))
      session = Quaack::Enclave::Fuzz::Session.new(conn, catalog, [sql, sql], honour: [], statement_timeout_ms: 10_000,
                                                                              binding: bound)
      allow(Quaack::Enclave::Fuzz::Differ).to receive(:differing).and_call_original
      conn.exec("BEGIN; INSERT INTO fx.items VALUES (1, 1), (2, 3)")

      expect(Quaack::Enclave::Fuzz::Differ.multisets(conn, sql, ["SELECT i.id FROM fx.items i"], typed)).to eq([0])
      expect(session.differing(sql, ["SELECT i.id FROM fx.items i"])).to eq([0])
      expect(Quaack::Enclave::Fuzz::Differ).to have_received(:differing).with(conn, sql, anything, satisfy { |typed|
        typed.binding == bound
      })
    ensure
      conn.exec("ROLLBACK")
    end

    it "Session's Shapes and Lift's runner get the binding" do
      sql = "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2"
      bound = binding_for(sql, [%w[1.5 numeric], %w[3 integer]])
      allow(shape_class).to receive(:parse).and_call_original
      allow(Quaack::Enclave::DenormalizedFixture::Runner).to receive(:new).and_call_original
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, Quaack::Enclave::Fuzz.send(:footprint, [sql]))

      Quaack::Enclave::Fuzz::Session.new(conn, catalog, [sql, sql], honour: [], statement_timeout_ms: 10_000,
                                                                    binding: bound)
      expect(shape_class).to have_received(:parse).with(sql, :original, binding: bound).twice

      Quaack::Enclave::Fuzz::Lift.new(conn, catalog, nil, honour: [], statement_timeout_ms: 10_000, binding: bound)
      expect(Quaack::Enclave::DenormalizedFixture::Runner).to have_received(:new)
        .with(conn, [], statement_timeout_ms: 10_000, binding: bound)
    end

    it "the fuzz search passes an equivalent rewrite of a numeric $n on an integer column" do
      sql = "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2"
      bound = binding_for(sql, [%w[1.5 numeric], %w[3 integer]])
      candidate = "SELECT i.id FROM fx.items i WHERE $1 * i.qty > $2"

      result = Quaack::Enclave::Fuzz.run(conn, sql, candidate, stop: Quaack::Enclave::Fuzz::StopRule.trials(50),
                                                               binding: bound)

      expect(result).to have_attributes(verdict: :passed)
      expect(result.trials).to be_positive
    end

    it "the fuzz search disproves a wrong one" do
      sql = "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2"
      bound = binding_for(sql, [%w[1.5 numeric], %w[3 integer]])
      candidate = "SELECT i.id FROM fx.items i WHERE i.qty > $2"

      result = Quaack::Enclave::Fuzz.run(conn, sql, candidate, stop: Quaack::Enclave::Fuzz::StopRule.trials(500),
                                                               binding: bound)

      expect(result).to have_attributes(verdict: :disproved)
    end
  end
end
