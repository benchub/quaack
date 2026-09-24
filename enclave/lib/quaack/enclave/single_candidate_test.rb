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
    # not inside a transaction. query is the text of one statement, with $n
    # placeholders or none. candidates are IndexCandidates, as Dedupe leaves
    # them.
    #
    # Until 3e literal sets (20260922-21) and 3g redaction (20260922-23)
    # land, literal_sets is a stand-in: a Hash from each set's name to its
    # values, in parameter order. Each value is a String in a valid
    # encoding with no NUL, or nil for NULL. Anything else raises
    # Error(:bad_literal) before the database is touched.
    #
    # Each literal is planned the way the production session plans it,
    # with its real value, not with a generic plan. Each EXPLAIN prepares
    # the query afresh, with the extended protocol, which refuses more than
    # one statement. It runs EXPLAIN EXECUTE once and deallocates, so every
    # plan is a new one that sees the hypothetical index of the moment. The
    # run sets plan_cache_mode = force_custom_plan for its transaction,
    # because the setting matters: under force_generic_plan, which the
    # session or the database may set, Postgres plans even a statement's
    # first EXECUTE generically, without the literal. A statement with no
    # parameters still gets a generic plan, by design, and keeps it for as
    # long as it's prepared. That's fine, since it's prepared afresh for
    # each EXPLAIN. A value goes into EXECUTE as a quoted literal,
    # which Postgres reads with the parameter's type, just as it reads a
    # bound text parameter. EXECUTE can't take a bound parameter, since its
    # own parameter types are unknown.
    #
    # The baseline plans each literal set with no hypothetical index. Then,
    # for each candidate in order: hypopg_reset, hypopg_create_index with
    # its DDL, hypopg_relation_size, and an EXPLAIN per literal set. A
    # candidate the planner never uses keeps its result, and so does one
    # HypoPG refuses, recorded with a Refusal. Each result's canonical plan
    # names the hypothetical index by the candidate's to_ddl, so a caller
    # that compares these plans with others must name hypothetical indexes
    # the same way.
    #
    # A failure creating the index counts as a refusal unless its SQLSTATE
    # says the session, not the definition, is the problem: a connection
    # error (class 08), a transaction state or rollback (25, 40), a lack of
    # resources (53), a cancel, timeout, or shutdown (57), a lock timeout
    # (55P03), a system error (58), corrupt data (XX001, XX002), or no
    # SQLSTATE at all, such as a failure to send. Those stop the run with
    # Error(:hypopg_failed). HypoPG reports much of what it refuses, such
    # as a column that doesn't exist, as XX000, so that counts as a
    # refusal.
    #
    # The run happens inside a transaction that's rolled back, and
    # hypopg_reset runs at the end, since hypothetical indexes don't roll
    # back. A hypothetical index the caller made earlier is gone afterward.
    # The transaction also sets hypopg.enabled = on, since with it off,
    # HypoPG still creates and sizes each index but the planner never sees
    # it, so every candidate would look unused. The run refuses, with
    # Error(:indexes_hidden), while HypoPG hides any real index in the
    # session, since every plan would skip it. If the run fails and
    # cleanup fails too, the run's error is the one raised. Postgres
    # notices are dropped during the run, since a notice can quote a
    # literal, and the caller's notice receiver is put back after, even if
    # cleanup fails.
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
      # rule is one of :in_transaction, :bad_literal, :indexes_hidden,
      # :prepare_failed, :explain_failed, :hypopg_failed, or
      # :cleanup_failed. sqlstate is the
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

      CREATE_SQL = "SELECT indexrelid, indexname, hypopg_relation_size(indexrelid) FROM hypopg_create_index($1)"

      # SQLSTATE classes and codes that mean the session failed, not the
      # candidate. See the comment at the top.
      SESSION_FAILURE = /\A(?:08|25|40|53|57|58)|\A(?:55P03|XX001|XX002)\z/

      # libpq's PG_DIAG_SQLSTATE, the field code for an error's SQLSTATE.
      SQLSTATE_FIELD = "C".ord

      module_function

      def run(connection, query:, literal_sets:, candidates:)
        raise Error, :bad_literal unless literal_sets?(literal_sets)
        raise Error, :in_transaction unless connection.transaction_status.zero?

        Run.new(connection, query, literal_sets, candidates).report
      end

      def literal_sets?(sets)
        sets.is_a?(Hash) && sets.each_value.all? { |values| values.is_a?(Array) && values.all? { |v| literal?(v) } }
      end

      def literal?(value)
        value.nil? || (value.instance_of?(String) && value.valid_encoding? && !value.include?("\0"))
      end

      # The SQLSTATE of a Postgres error, or nil.
      def sqlstate(error)
        result = error.result if error.respond_to?(:result)
        result&.error_field(SQLSTATE_FIELD)
      end

      def postgres_error?(error) = !error.is_a?(Error) && error.respond_to?(:result)

      # Runs the block, turning a Postgres error into an Error with the rule
      # that carries nothing from it.
      def guarded(rule)
        yield
      rescue StandardError => e
        raise unless postgres_error?(e)

        raise Error.new(rule, sqlstate(e)), cause: nil
      end

      # The parsed EXPLAIN JSON, deep-frozen. A deep plan nests past JSON's
      # default limit of 100, since each node takes two levels, so there's
      # no limit. Unreadable output is an Error that quotes none of it.
      def parse_plan(json)
        deep_freeze(JSON.parse(json, max_nesting: false))
      rescue JSON::ParserError
        raise Error, :explain_failed, cause: nil
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
            tested
          ensure
            @connection.set_notice_receiver(&previous)
          end
        end

        private

        # If the run fails and cleanup fails too, the run's error is the
        # one raised.
        def tested
          failed = true
          SingleCandidateTest.guarded(:explain_failed) { start }
          baseline = Baseline.new(plans: plans(nil, nil, nil))
          report = Report.new(baseline:, results: @candidates.map { |c| test(c) }.freeze)
          failed = false
          report
        ensure
          cleanup(failed)
        end

        def cleanup(failed)
          SingleCandidateTest.guarded(:cleanup_failed) { finish }
        rescue StandardError
          raise unless failed
        end

        def start
          @connection.exec("BEGIN")
          @connection.exec("SET LOCAL plan_cache_mode = force_custom_plan")
          @connection.exec("SET LOCAL hypopg.enabled = on")
          @connection.exec("SELECT hypopg_reset()")
          raise Error, :indexes_hidden if hidden_indexes?
        end

        # HypoPG keeps real indexes hidden with hypopg_hide_index for the
        # session, and hypopg_reset doesn't unhide them, so the baseline and
        # every candidate would plan without them. They aren't unhidden
        # here, since that isn't transactional and the caller hid them.
        # HypoPG before 1.4 has no hypopg_hidden_indexes, so the run fails
        # closed there, as explain_failed with 42883.
        def hidden_indexes?
          @connection.exec("SELECT count(*) FROM hypopg_hidden_indexes()").getvalue(0, 0) != "0"
        end

        def finish
          @connection.exec("ROLLBACK") unless @connection.transaction_status.zero?
          deallocate if @prepared
          @connection.exec("SELECT hypopg_reset()")
        end

        def deallocate
          @connection.exec("DEALLOCATE #{STATEMENT}")
          @prepared = false
        end

        def test(candidate)
          oid, name, size, sqlstate = SingleCandidateTest.guarded(:hypopg_failed) { create(candidate) }
          return refused(candidate, sqlstate) if oid.nil?

          Result.new(candidate:, size:, plans: plans(oid, name, candidate), refusal: nil)
        end

        # The new index's oid, name, and size, or, if HypoPG refused it,
        # three nils and the SQLSTATE.
        def create(candidate)
          @connection.exec("SELECT hypopg_reset()")
          # The savepoint is there for a refused create to roll back to. It's
          # never released: nothing in it writes, and the run's rollback
          # ends every one left open.
          @connection.exec("SAVEPOINT #{STATEMENT}")
          created = @connection.exec_params(CREATE_SQL, [candidate.to_ddl])
          [Integer(created.getvalue(0, 0)), created.getvalue(0, 1), Integer(created.getvalue(0, 2))]
        rescue StandardError => e
          raise unless SingleCandidateTest.postgres_error?(e)

          [nil, nil, nil, refusal_sqlstate(SingleCandidateTest.sqlstate(e))]
        end

        # Rolls back a refused create and returns its SQLSTATE, or raises
        # if the failure wasn't a refusal.
        def refusal_sqlstate(sqlstate)
          raise Error.new(:hypopg_failed, sqlstate), cause: nil if sqlstate.nil? || SESSION_FAILURE.match?(sqlstate)

          @connection.exec("ROLLBACK TO SAVEPOINT #{STATEMENT}")
          sqlstate
        end

        def refused(candidate, sqlstate)
          Result.new(candidate:, size: nil, plans: {}.freeze,
                     refusal: Refusal.new(rule: :hypopg_refused, sqlstate:))
        end

        def plans(oid, index_name, candidate)
          identities = oid ? { oid => candidate.to_ddl } : {}
          @literal_sets.to_h { |set, values| [set, plan(explain(values), index_name, identities)] }.freeze
        end

        def explain(values)
          SingleCandidateTest.guarded(:prepare_failed) do
            @connection.prepare(STATEMENT, @query)
            @prepared = true
          end
          json = SingleCandidateTest.guarded(:explain_failed) do
            @connection.exec("EXPLAIN (FORMAT JSON) EXECUTE #{execute(values)}").getvalue(0, 0)
          end
          SingleCandidateTest.guarded(:cleanup_failed) { deallocate }
          SingleCandidateTest.parse_plan(json)
        end

        # EXECUTE of the prepared statement with these values. With no
        # values, it takes no parentheses.
        def execute(values)
          return STATEMENT if values.empty?

          "#{STATEMENT}(#{values.map { |v| v.nil? ? "NULL" : @connection.escape_literal(v) }.join(", ")})"
        end

        # used is whether any node scans the hypothetical index, by the exact
        # name HypoPG gave it. Only this candidate's hypothetical index
        # exists while it plans, since the run resets HypoPG before creating
        # it. (A hypothetical index that a function the planner folds
        # creates in the middle of planning doesn't show up in the plan, as
        # tried on HypoPG 1.4.) But a real index can have a name that looks
        # like a hypothetical one, such as "<1>x", so matching any name that
        # starts with "<" would count it.
        def plan(explain, index_name, identities)
          root = explain.first["Plan"]
          used = !index_name.nil? && PlanNode.new(root).subtree.any? { |node| node["Index Name"] == index_name }
          Plan.new(used:, total_cost: root["Total Cost"],
                   canonical_plan: CanonicalPlan.new(explain, hypothetical_indexes: identities), raw_plan: explain)
        end
      end

      private_constant :Run
    end
  end
end
