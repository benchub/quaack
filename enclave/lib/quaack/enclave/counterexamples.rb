# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "arena_fixture"
require_relative "arena_schema"
require_relative "insert_check"
require_relative "result_comparison"
require_relative "scenarios"
require_relative "vacuity_guard"
require_relative "counterexamples/evaluated"
require_relative "counterexamples/parent_rows"
require_relative "counterexamples/deferral"

module Quaack
  module Enclave
    # llm-counterexamples, the enclave's half: turns the LLM's counterexample inserts into
    # a fixture for counterexample-compare.
    #
    #   prepared = Counterexamples.prepare(arena_connection, inserts,
    #                                      placeholder_map: map, tables: subset_tables,
    #                                      queries: [original, candidate])
    #   prepared.rows     # => parent FixtureRows that fill foreign-key gaps, parents first
    #   prepared.inserts  # => the accepted inserts, bound, parents' tables first
    #   prepared.refused  # => [{ index: 0, rule: "insert_select" }, ...]
    #
    # The LLM sees only shapes, so it writes $n where it wants one of the
    # query's literals, numbered as in redact's redacted query. Each $n is
    # bound to its real value from the placeholder map (Redaction's form),
    # as a string constant the column's type reads, or NULL for a NULL
    # literal. A $n the map doesn't have refuses the insert with
    # unknown_placeholder. The bound insert then goes through the inbound
    # check (InsertCheck), and a refusal keeps only its rule. Each value of
    # an accepted insert is then evaluated in arena (see Evaluated); one
    # Postgres can't evaluate, such as a bad cast, refuses the insert with
    # bad_value, and Postgres's message, which can quote the value, is
    # dropped. Any other error there, such as a statement timeout, goes up.
    # tables are the schema-dump subset schema's tables. The connection is
    # arena's: the check reads its catalog, which matches production's
    # schema.
    #
    # Accepted inserts are ordered so each table's inserts come after
    # those of the tables it references, keeping the LLM's order
    # otherwise. Any foreign-key value that no insert supplies gets a
    # parent row, built by the rewrite-test rules (see ParentRows), and so do
    # that row's own NOT NULL foreign keys, however far up. queries are the
    # SQL the fixture runs: a parent row leaves NULL a nullable column
    # rewrite-test can't fill only when none of them reads it. Constraints are
    # never bypassed.
    #
    # A foreign-key cycle can leave no parents-first order. rewrite-test's
    # Topology, given no atoms, cuts nullable foreign keys, one at a time
    # while each still closes a cycle (see Deferral). An insert that sets a
    # cut column becomes an
    # ArenaRunner::DeferredInsert: it loads with NULL there, and once every
    # insert has loaded, an UPDATE keyed to the row's tableoid and ctid
    # sets the LLM's value. So the loaded data is exactly the LLM's rows.
    # prepared.inserts holds Strings and DeferredInserts.
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
      # the untested atoms this round's fixture exercised. load_failed is
      # true when the fixture itself failed to load, and then match is nil.
      Round = Data.define(:match, :rule, :load_order, :covered, :load_failed)

      # The runner rules that mean the fixture, not the candidate, failed.
      LOAD_RULES = %i[fixture_load_failed reverse_load_failed insert_failed].freeze

      # The runner steps that load the fixture. A failure in one of them,
      # whatever its rule (a statement_timeout, say), is a load failure.
      LOAD_STEPS = %i[load insert].freeze

      module_function

      # counterexample-compare and counterexample-rollback. Runs fixture-compare's comparison on the prepared fixture,
      # in both load orders (ResultComparison.compare_in_both_orders: the parent rows reverse, the inserts keep their
      # order), then vacuity-guard's test for each untested atom (indexes into atoms, the original's PredicateAtoms),
      # each in its own arena transaction that rolls back. A fixture that fails to load disproves nothing: the round
      # reports the runner's rule, with match nil, load_failed true, and nothing covered. Any other runner failure,
      # such as the candidate failing to run (query_failed), disproves it, with match false. Untested atoms with_true
      # can't replace are skipped.
      def compare(runner, prepared, original:, candidate:, atoms:, untested:) # rubocop:disable Metrics/ParameterLists
        verdict = ResultComparison.compare_in_both_orders(runner, prepared.rows, original:, candidate:,
                                                                                 inserts: prepared.inserts)
        Round.new(match: verdict.match?, rule: verdict.rule, load_order: verdict.load_order,
                  covered: covered(runner, prepared, original, atoms, untested), load_failed: false)
      rescue ArenaRunner::Error => e
        load_failed = LOAD_RULES.include?(e.rule) || LOAD_STEPS.include?(e.step)
        Round.new(match: load_failed ? nil : false, rule: e.rule, load_order: nil, covered: [], load_failed:)
      end

      def covered(runner, prepared, original, atoms, untested)
        parse = PgQuery.parse(original)
        replaceable = untested.select { |i| atoms[i].replaceable }
        loosened = replaceable.to_h { |i| [i, PredicateAtoms.with_true(parse, atoms[i])] }
        VacuityGuard.exercised_atoms(runner, prepared.rows, original, loosened, inserts: prepared.inserts)
                    .map { |i| atoms[i].shape }
      end

      def prepare(conn, inserts, placeholder_map:, tables:, queries: nil, settings: nil) # rubocop:disable Metrics/ParameterLists
        accepted, refused = check(conn, inserts, placeholder_map, tables, settings)
        schema = ArenaSchema.load_closure(conn, accepted.map(&:table).uniq)
        topology = Scenarios::Topology.new(schema, [])
        accepted = parents_first(topology, accepted)
        Prepared.new(rows: ParentRows.new(conn, schema, accepted, reads(schema, queries)).rows,
                     inserts: accepted.map { |a| Deferral.insert(a, topology.cut_columns(a.table)) }, refused:)
      end

      # What the queries read, or nil, so every column counts as read, when
      # there are none.
      def reads(schema, queries)
        queries && Scenarios::Reads.new(queries.map { PgQuery.parse(it) }, schema.column_names)
      end

      def parents_first(topology, accepted)
        order = topology.order
        accepted.each_with_index.sort_by { |a, i| [order.index(a.table), i] }.map(&:first)
      end

      # The accepted inserts, each Evaluated, and the refusals.
      def check(conn, inserts, placeholder_map, tables, settings)
        accepted = []
        refused = []
        inserts.each_with_index do |sql, index|
          accepted << Evaluated.of(conn, InsertCheck.check(bind(sql, placeholder_map), tables, settings, conn))
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
