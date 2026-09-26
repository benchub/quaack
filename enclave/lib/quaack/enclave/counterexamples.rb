# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "arena_fixture"
require_relative "arena_schema"
require_relative "insert_check"
require_relative "result_comparison"
require_relative "scenarios"
require_relative "vacuity_guard"
require_relative "counterexamples/parent_rows"

module Quaack
  module Enclave
    # 10a, the enclave's half: turns the LLM's counterexample inserts into
    # a fixture for 10b.
    #
    #   prepared = Counterexamples.prepare(arena_connection, inserts,
    #                                      placeholder_map: map, tables: subset_tables)
    #   prepared.rows     # => parent FixtureRows that fill foreign-key gaps, parents first
    #   prepared.inserts  # => the accepted inserts, bound, parents' tables first
    #   prepared.refused  # => [{ index: 0, rule: "insert_select" }, ...]
    #
    # The LLM sees only shapes, so it writes $n where it wants one of the
    # query's literals, numbered as in 3g's redacted query. Each $n is
    # bound to its real value from the placeholder map (Redaction's form),
    # as a string constant the column's type reads, or NULL for a NULL
    # literal. A $n the map doesn't have refuses the insert with
    # unknown_placeholder. The bound insert then goes through the inbound
    # check (InsertCheck), and a refusal keeps only its rule. tables are
    # the 3b subset schema's tables. The connection is arena's: the check
    # reads its catalog, which matches production's schema.
    #
    # Accepted inserts are ordered so each table's inserts come after
    # those of the tables it references, keeping the LLM's order
    # otherwise. Any foreign-key value that no insert supplies gets a
    # parent row, built by the step 9 rules (see ParentRows), and so do
    # that row's own NOT NULL foreign keys, however far up. Constraints are
    # never bypassed.
    #
    # Trust boundary: rows and inserts hold real values and stay in the
    # enclave. refused holds indexes and rule names only.
    module Counterexamples
      class Refusal < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      Prepared = Data.define(:rows, :inserts, :refused) do
        def inspect = "#<data #{self.class} rows=<redacted> inserts=<redacted> refused=#{refused}>"

        alias_method :to_s, :inspect
      end

      # One round's outcome: whether the candidate still matched, the
      # verdict's rule and load order when it didn't, and the shapes of
      # the untested atoms this round's fixture exercised.
      Round = Data.define(:match, :rule, :load_order, :covered)

      module_function

      # 10b and 10c. Runs 9d's comparison on the prepared fixture, in both
      # load orders (ResultComparison.compare_in_both_orders: the parent
      # rows reverse, the inserts keep their order), then 9c's test for each
      # untested atom (indexes into atoms, the original's PredicateAtoms),
      # each in its own arena transaction that rolls back. A fixture that
      # fails to load disproves nothing: the round reports the runner's
      # rule, with match false and nothing covered.
      def compare(runner, prepared, original:, candidate:, atoms:, untested:) # rubocop:disable Metrics/ParameterLists
        verdict = ResultComparison.compare_in_both_orders(runner, prepared.rows, original:, candidate:,
                                                                                 inserts: prepared.inserts)
        Round.new(match: verdict.match?, rule: verdict.rule, load_order: verdict.load_order,
                  covered: covered(runner, prepared, original, atoms, untested))
      rescue ArenaRunner::Error => e
        Round.new(match: false, rule: e.rule, load_order: nil, covered: [])
      end

      def covered(runner, prepared, original, atoms, untested)
        parse = PgQuery.parse(original)
        loosened = untested.to_h { |i| [i, PredicateAtoms.with_true(parse, atoms[i])] }
        VacuityGuard.exercised_atoms(runner, prepared.rows, original, loosened, inserts: prepared.inserts)
                    .map { |i| atoms[i].shape }
      end

      def prepare(conn, inserts, placeholder_map:, tables:, settings: nil)
        accepted, refused = check(conn, inserts, placeholder_map, tables, settings)
        schema = ArenaSchema.load_closure(conn, accepted.map(&:table).uniq)
        accepted = parents_first(schema, accepted)
        Prepared.new(rows: ParentRows.new(conn, schema, accepted).rows, inserts: accepted.map(&:sql), refused:)
      end

      def parents_first(schema, accepted)
        order = Scenarios::Topology.new(schema, []).order
        accepted.each_with_index.sort_by { |a, i| [order.index(a.table), i] }.map(&:first)
      end

      def check(conn, inserts, placeholder_map, tables, settings)
        accepted = []
        refused = []
        inserts.each_with_index do |sql, index|
          accepted << InsertCheck.check(bind(sql, placeholder_map), tables, settings, conn)
        rescue InsertCheck::Error, Refusal => e
          refused << { index:, rule: e.rule.to_s }
        end
        [accepted, refused]
      end

      # The insert with each $n replaced by its literal.
      def bind(sql, placeholder_map)
        tree = PgQuery.parse(sql).tree
        replace_params(tree, placeholder_map)
        PgQuery.deparse(tree)
      rescue PgQuery::ParseError
        raise Refusal, "unparsable"
      end

      def replace_params(node, map)
        case node
        when Google::Protobuf::RepeatedField
          node.each_with_index { |c, i| param?(c) ? node[i] = literal(c, map) : replace_params(c, map) }
        when Google::Protobuf::MessageExts
          node.class.descriptor.each do |field|
            value = field.get(node)
            param?(value) ? field.set(node, literal(value, map)) : replace_params(value, map)
          end
        end
      end

      def param?(value) = value.is_a?(PgQuery::Node) && value.param_ref

      def literal(param, map)
        entry = map["$#{param.param_ref.number}"] or raise Refusal, "unknown_placeholder"
        return PgQuery::Node.new(a_const: PgQuery::A_Const.new(isnull: true)) if entry["value"].nil?

        PgQuery::Node.new(a_const: PgQuery::A_Const.new(sval: PgQuery::String.new(sval: entry["value"])))
      end
    end
  end
end
