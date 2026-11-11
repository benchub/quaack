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
      expect(result_comparison).to have_received(:compare).with(anything, original: sql, candidate: sql, binding: bound)
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
end
