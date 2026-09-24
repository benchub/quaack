# frozen_string_literal: true

require "json"
require_relative "canonical_plan"
require_relative "index_candidate"
require_relative "plan_node"

module Quaack
  module Enclave
    # README 5a-4: test each index candidate on its own with HypoPG, on the
    # racetrack. Step 8 and step 11 call it the same way for a rewrite
    # candidate, with the rewrite's query in place of the original's.
    #
    #   SingleCandidateTest.run(connection,
    #                           query: "SELECT * FROM public.orders WHERE status = $1",
    #                           literal_sets: { slow: ["open"], worst: ["shipped"], typical: ["held"] },
    #                           candidates: survivors)
    #   # => Report(baseline: Baseline(plans: { slow: Plan, ... }),
    #   #           results: [Result(candidate:, size:, plans: { slow: Plan, ... }, refusal: nil), ...])
    #
    # connection is a live racetrack connection with the hypopg extension,
    # not inside a transaction. query is the query text with $n
    # placeholders. candidates are IndexCandidates, as Dedupe leaves them.
    #
    # Until 3e literal sets (20260922-21) and 3g redaction (20260922-23)
    # land, literal_sets is a stand-in: a Hash from each set's name to its
    # values, as text in parameter order, with nil for NULL.
    #
    # Each literal is planned the way the production session plans it,
    # with its real value, not with a generic plan. The query is prepared
    # once, and each EXPLAIN runs EXECUTE with plan_cache_mode set to
    # force_custom_plan, so every EXPLAIN plans afresh, seeing the
    # hypothetical index of the moment. A value goes into EXECUTE as a
    # quoted literal, which Postgres reads with the parameter's type, just
    # as it reads a bound text parameter. (EXECUTE can't take a bound
    # parameter, since its own parameter types are unknown.)
    #
    # The baseline plans each literal set with no hypothetical index. Then,
    # for each candidate in order: hypopg_reset, hypopg_create_index with
    # its DDL, hypopg_relation_size, and an EXPLAIN per literal set. A
    # candidate the planner never uses keeps its result, and so does one
    # HypoPG refuses, recorded with a Refusal.
    #
    # The run happens inside a transaction that's rolled back, and
    # hypopg_reset runs at the end, since hypothetical indexes don't roll
    # back. A hypothetical index the caller made earlier is gone afterward.
    # Postgres notices are dropped during the run, since a notice can quote
    # a literal, and the caller's notice receiver is put back after.
    #
    # Trust boundary: the literals and the raw plans are value-class data
    # and stay in the enclave. inspect and to_s of every result leave the
    # raw plan out. Any error from Postgres becomes an Error with a rule and
    # the SQLSTATE, with no message or cause from Postgres, since a
    # Postgres message can quote a literal.
    #
    # Which fields are which, for whoever sends these through egress later:
    # - Shape-class, which could leave: Plan#used, Plan#total_cost,
    #   Result#size, Result#used?, and Refusal.
    # - Enclave-only: Plan#canonical_plan (see 20260923-28), and
    #   Result#candidate, since a partial candidate's predicate can hold a
    #   literal.
    # - Value-class: Plan#raw_plan, which holds the literals.
    # Nothing here goes through egress yet.
    module SingleCandidateTest
      # rule is :in_transaction or :explain_failed. sqlstate is the
      # Postgres SQLSTATE, or nil if there wasn't one.
      class Error < StandardError
        attr_reader :rule, :sqlstate

        def initialize(rule, sqlstate = nil)
          @rule = rule
          @sqlstate = sqlstate
          super(sqlstate ? "#{rule} (SQLSTATE #{sqlstate})" : rule.to_s)
        end
      end

      # results has one Result per candidate, in the order given.
      Report = Data.define(:baseline, :results)

      # The plans with no hypothetical index. Here and in Result, plans maps
      # each literal set's name to its Plan. Each baseline Plan's used is
      # false.
      Baseline = Data.define(:plans)

      # One candidate's test. size is hypopg_relation_size in bytes. A
      # refused candidate has a refusal, a nil size, and no plans.
      Result = Data.define(:candidate, :size, :plans, :refusal) do
        # True if the planner used the candidate for any literal set.
        def used? = plans.values.any?(&:used)
      end

      # One EXPLAIN: whether the plan uses this candidate's hypothetical
      # index, the root's Total Cost, the CanonicalPlan, and the parsed
      # EXPLAIN (FORMAT JSON), deep-frozen.
      Plan = Data.define(:used, :total_cost, :canonical_plan, :raw_plan) do
        def inspect = "#<data #{self.class} used=#{used}, total_cost=#{total_cost}, raw_plan=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      # A candidate HypoPG wouldn't create. rule is :hypopg_refused.
      Refusal = Data.define(:rule, :sqlstate)

      # The name of the prepared statement and of the savepoint around each
      # hypopg_create_index.
      STATEMENT = "quaack_5a4"

      CREATE_SQL = "SELECT indexrelid, hypopg_relation_size(indexrelid) FROM hypopg_create_index($1)"

      # libpq's PG_DIAG_SQLSTATE, the field code for an error's SQLSTATE.
      SQLSTATE_FIELD = "C".ord

      module_function

      def run(connection, query:, literal_sets:, candidates:)
        raise Error, :in_transaction unless connection.transaction_status.zero?

        Run.new(connection, query, literal_sets, candidates).report
      end

      # The SQLSTATE of a Postgres error, or nil.
      def sqlstate(error)
        result = error.result if error.respond_to?(:result)
        result&.error_field(SQLSTATE_FIELD)
      end

      # Runs the block, turning a Postgres error into an Error that carries
      # nothing from it.
      def guarded
        yield
      rescue StandardError => e
        raise if e.is_a?(Error) || !e.respond_to?(:result)

        raise Error.new(:explain_failed, sqlstate(e)), cause: nil
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end

      # One call to run.
      class Run
        def initialize(connection, query, literal_sets, candidates)
          @connection = connection
          @query = query
          @literal_sets = literal_sets
          @candidates = candidates
        end

        def report
          previous = @connection.set_notice_receiver { nil }
          begin
            SingleCandidateTest.guarded { start }
            baseline = Baseline.new(plans: plans(nil, nil))
            Report.new(baseline:, results: @candidates.map { |c| test(c) }.freeze)
          ensure
            SingleCandidateTest.guarded { finish }
            @connection.set_notice_receiver(&previous)
          end
        end

        private

        def start
          @connection.exec("BEGIN")
          @connection.exec("SET LOCAL plan_cache_mode = force_custom_plan")
          @connection.exec("SELECT hypopg_reset()")
          @connection.exec("PREPARE #{STATEMENT} AS #{@query}")
          @prepared = true
        end

        def finish
          @connection.exec("ROLLBACK") unless @connection.transaction_status.zero?
          @connection.exec("DEALLOCATE #{STATEMENT}") if @prepared
          @connection.exec("SELECT hypopg_reset()")
        end

        def test(candidate)
          oid, size, sqlstate = SingleCandidateTest.guarded { create(candidate) }
          return refused(candidate, sqlstate) if oid.nil?

          Result.new(candidate:, size:, plans: plans(oid, candidate), refusal: nil)
        end

        # The new index's oid and size, or, if HypoPG refused it, nil, nil,
        # and the SQLSTATE.
        def create(candidate)
          @connection.exec("SELECT hypopg_reset()")
          @connection.exec("SAVEPOINT #{STATEMENT}")
          created = @connection.exec_params(CREATE_SQL, [candidate.to_ddl])
          @connection.exec("RELEASE SAVEPOINT #{STATEMENT}")
          [Integer(created.getvalue(0, 0)), Integer(created.getvalue(0, 1))]
        rescue StandardError => e
          raise unless e.respond_to?(:result)

          @connection.exec("ROLLBACK TO SAVEPOINT #{STATEMENT}")
          [nil, nil, SingleCandidateTest.sqlstate(e)]
        end

        def refused(candidate, sqlstate)
          Result.new(candidate:, size: nil, plans: {}.freeze,
                     refusal: Refusal.new(rule: :hypopg_refused, sqlstate:))
        end

        def plans(oid, candidate)
          identities = oid ? { oid => candidate.to_ddl } : {}
          @literal_sets.to_h { |name, values| [name, plan(explain(values), oid, identities)] }.freeze
        end

        def explain(values)
          arguments = values.map { |v| v.nil? ? "NULL" : @connection.escape_literal(v) }.join(", ")
          execute = arguments.empty? ? STATEMENT : "#{STATEMENT}(#{arguments})"
          json = SingleCandidateTest.guarded do
            @connection.exec("EXPLAIN (FORMAT JSON) EXECUTE #{execute}").getvalue(0, 0)
          end
          SingleCandidateTest.deep_freeze(JSON.parse(json))
        end

        def plan(explain, oid, identities)
          root = explain.first["Plan"]
          Plan.new(used: !oid.nil? && uses?(PlanNode.new(root), oid),
                   total_cost: root["Total Cost"],
                   canonical_plan: CanonicalPlan.new(explain, hypothetical_indexes: identities),
                   raw_plan: explain)
        end

        def uses?(root, oid)
          root.subtree.any? { |node| node["Index Name"].is_a?(String) && node["Index Name"].start_with?("<#{oid}>") }
        end
      end

      private_constant :Run
    end
  end
end
