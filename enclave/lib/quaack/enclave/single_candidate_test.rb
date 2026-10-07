# frozen_string_literal: true

require "json"
require_relative "canonical_plan"
require_relative "index_candidate"
require_relative "plan_node"
require_relative "redaction"
require_relative "single_candidate_test/hypopg"

module Quaack
  module Enclave
    # SingleCandidateTest's Baseline and Result record the literal sets
    # they were measured with. The values are value-class, so their inspect
    # leaves them out.
    module RecordedLiteralSets
      # A frozen copy of valid literal sets (SingleCandidateTest.literal_sets?).
      def self.copy(sets) = sets.to_h { |set, values| [set, values.map { it&.dup&.freeze }.freeze] }.freeze

      def inspect
        shown = to_h.map { |name, value| "#{name}=#{name == :literal_sets ? "<redacted>" : value.inspect}" }
        "#<data #{self.class} #{shown.join(", ")}>"
      end

      def to_s = inspect

      def pretty_print(pp) = pp.text(inspect)
    end

    # DESIGN.md's index-test: test each index candidate on its own with HypoPG, on the
    # racetrack. plan-pruning and rewrite-index-ideas call it the same way for a rewrite
    # candidate, with the rewrite's query in place of the original's.
    #
    #   SingleCandidateTest.run(connection,
    #                           query: "SELECT * FROM public.orders WHERE status = $1",
    #                           literal_sets: { slow: ["open"], worst: ["shipped"], typical: ["held"] },
    #                           candidates: survivors)
    #   # => Report(baseline: Baseline(plans: { slow: Plan, ... }, literal_sets:),
    #   #           results: [Result(candidate:, size:, plans: { slow: Plan, ... }, refusal: nil,
    #   #                            literal_sets:), ...])
    #
    # connection is a live racetrack connection with the hypopg extension,
    # not inside a transaction. query is the text of one statement, with $n
    # placeholders or none. candidates are IndexCandidates, as Dedupe leaves
    # them.
    #
    # session takes the same arguments but candidates, and yields a Session
    # whose measure creates several hypothetical indexes at once. index-rank's
    # IndexRanking uses it to measure combinations. run is built on it, so
    # everything below holds for both.
    #
    # Until literal sets (20260922-21) and redaction (20260922-23)
    # land, literal_sets is a stand-in: a Hash from each set's name to its
    # values, in parameter order. Each value is a String in a valid
    # encoding with no NUL, or nil for NULL. Anything else raises
    # Error(:bad_literal) before the database is touched.
    #
    # types, if given, is each $n's type for PREPARE, in order, as
    # Redaction::Binding declares it: the type its original literal had,
    # such as integer for the 7 of now()::date - 7, so Postgres doesn't
    # infer another from context (date there). The query must then be one
    # statement. Without types, Postgres infers every type.
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
    # The run happens inside a READ ONLY transaction that's rolled back, so
    # even a write the planner makes while folding a function fails, and
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
    # - Value-class: Plan#raw_plan, which holds the literals, and
    #   Baseline#literal_sets and Result#literal_sets, which are them.
    # Nothing here goes through egress yet.
    module SingleCandidateTest
      # rule is one of :in_transaction, :bad_literal, :indexes_hidden,
      # :prepare_failed, :explain_failed, :hypopg_failed, :cleanup_failed,
      # or :session_closed, for a Session measured after its block ended.
      # sqlstate is the Postgres SQLSTATE, or nil if there wasn't one.
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
      # each literal set's name to its Plan, and literal_sets is a frozen
      # copy of the literal_sets it was measured with, so index-rank can
      # check that its baseline and results were measured with the same
      # values. Each baseline Plan's used is false.
      Baseline = Data.define(:plans, :literal_sets) { include RecordedLiteralSets }

      # One candidate's test. size is hypopg_relation_size in bytes. A
      # refused candidate has a refusal, a nil size, and no plans.
      Result = Data.define(:candidate, :size, :plans, :refusal, :literal_sets) do
        include RecordedLiteralSets

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

      # What a Session measures with several hypothetical indexes present at
      # once: sizes has each one's hypopg_relation_size, in the order given,
      # and plans maps each literal set's name to a Measured. A refused
      # measurement has a refusal, nil sizes, and no plans.
      Measurement = Data.define(:sizes, :plans, :refusal)

      # Like Plan, but used has one boolean per hypothetical index, in the
      # order given.
      Measured = Data.define(:used, :total_cost, :canonical_plan, :raw_plan) do
        def inspect = "#<data #{self.class} used=#{used}, total_cost=#{total_cost}, raw_plan=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      # A candidate HypoPG wouldn't create, rule :hypopg_refused, or one whose
      # DDL can't be rendered, rule :unrenderable with a nil sqlstate.
      Refusal = Data.define(:rule, :sqlstate)

      # The name of the prepared statement and of the savepoint around each
      # hypopg_create_index.
      STATEMENT = "quaack_5a4"

      # SQLSTATE classes and codes that mean the session failed, not the
      # candidate. See the comment at the top.
      SESSION_FAILURE = /\A(?:08|25|40|53|57|58)|\A(?:55P03|XX001|XX002)\z/

      # libpq's PG_DIAG_SQLSTATE, the field code for an error's SQLSTATE.
      SQLSTATE_FIELD = "C".ord

      module_function

      def run(connection, query:, literal_sets:, candidates:, types: nil)
        session(connection, query:, literal_sets:, types:) do |s|
          sets = RecordedLiteralSets.copy(literal_sets)
          baseline = Baseline.new(plans: plans(s.measure([])), literal_sets: sets)
          Report.new(baseline:, results: candidates.map { |c| result(c, s.measure([c]), sets) }.freeze)
        end
      end

      def result(candidate, measured, literal_sets)
        Result.new(candidate:, size: measured.sizes&.first, plans: plans(measured), refusal: measured.refusal,
                   literal_sets:)
      end

      # Plans for one candidate, or for the baseline, which has no index to
      # use.
      def plans(measured)
        measured.plans.transform_values { |p| Plan.new(**p.to_h, used: p.used.any?) }.freeze
      end

      # Checks the arguments, opens a Session, yields it, and returns what
      # the block returns. Everything the block does happens inside the
      # run's transaction, which is rolled back after.
      def session(connection, query:, literal_sets:, types: nil, &)
        raise Error, :bad_literal unless literal_sets?(literal_sets)
        raise Error, :in_transaction unless connection.transaction_status.zero?

        Session.new(connection, query, literal_sets, types).open(&)
      end

      def literal_sets?(sets)
        sets.is_a?(Hash) && !sets.empty? &&
          sets.each_value.all? { |values| values.is_a?(Array) && values.all? { |v| literal?(v) } }
      end

      def literal?(value)
        value.nil? || (value.instance_of?(String) && value.valid_encoding? && !value.include?("\0"))
      end

      # The SQLSTATE of a Postgres error, or nil.
      def sqlstate(error)
        return error.sqlstate if error.is_a?(Redaction::Error)

        result = error.result if error.respond_to?(:result)
        result&.error_field(SQLSTATE_FIELD)
      end

      # A Postgres error, or Redaction's for a typed prepare, which carries
      # only its rule and SQLSTATE.
      def postgres_error?(error) = error.is_a?(Redaction::Error) || (!error.is_a?(Error) && error.respond_to?(:result))

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

      def refused(sqlstate)
        Measurement.new(sizes: nil, plans: {}.freeze, refusal: Refusal.new(rule: :hypopg_refused, sqlstate:))
      end

      # Runs the block with every value read as the String Postgres sends,
      # whatever type map the caller set, and puts the caller's back.
      def string_results(connection)
        type_map = connection.type_map_for_results
        connection.type_map_for_results = PG::TypeMapAllStrings.new
        yield
      ensure
        connection.type_map_for_results = type_map
      end

      # A candidate whose to_ddl the deparse guard refuses, such as one with
      # a name over 63 bytes, is refused on its own instead of stopping the
      # run.
      def renderable?(candidate)
        candidate.to_ddl
        true
      rescue Deparse::Error
        false
      end

      # The refused Measurement if any candidate is unrenderable, or nil.
      def unrenderable(candidates)
        return if candidates.all? { renderable?(it) }

        Measurement.new(sizes: nil, plans: {}.freeze, refusal: Refusal.new(rule: :unrenderable, sqlstate: nil))
      end

      # EXECUTE of the prepared statement with these values. With no
      # values, it takes no parentheses.
      def execute(connection, values)
        return STATEMENT if values.empty?

        "#{STATEMENT}(#{values.map { |v| v.nil? ? "NULL" : connection.escape_literal(v) }.join(", ")})"
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end

      # The safety core that run and index-rank's IndexRanking share: one
      # transaction with its SET LOCALs, the hidden-index check, notices
      # dropped, a fresh prepare for each EXPLAIN, refusals, and cleanup that
      # keeps the first error. See the comment at the top. session yields
      # one, and it's good only inside that block: after, measure raises
      # Error(:session_closed) without touching the database.
      class Session
        def initialize(connection, query, literal_sets, types = nil)
          @connection = connection
          @query = query
          @literal_sets = literal_sets
          @types = types
        end

        def open(&)
          previous = @connection.set_notice_receiver { nil }
          begin
            SingleCandidateTest.string_results(@connection) { within(&) }
          ensure
            @connection.set_notice_receiver(&previous)
          end
        end

        # Every candidate's hypothetical index at once, and an EXPLAIN per
        # literal set. Only these indexes exist while it plans: HypoPG is
        # reset first, even for none. If HypoPG refuses one, the rest aren't
        # created, and the Measurement has the Refusal, nil sizes, and no
        # plans.
        def measure(candidates)
          raise Error, :session_closed unless @open

          SingleCandidateTest.guarded(:hypopg_failed) { @connection.exec(HypoPG.reset_sql(hypopg(:hypopg_failed))) }
          SingleCandidateTest.unrenderable(candidates) || created(candidates)
        end

        private

        def created(candidates)
          indexes = []
          candidates.each do |candidate|
            oid, name, size, sqlstate = SingleCandidateTest.guarded(:hypopg_failed) { create(candidate) }
            return SingleCandidateTest.refused(sqlstate) if oid.nil?

            indexes << [oid, name, size, candidate]
          end
          Measurement.new(sizes: indexes.map { |i| i[2] }.freeze, plans: plans(indexes), refusal: nil)
        end

        def within
          failed = true
          SingleCandidateTest.guarded(:explain_failed) { start }
          @open = true
          value = yield self
          failed = false
          value
        ensure
          @open = false
          cleanup(failed)
        end

        # If the run fails and cleanup fails too, the run's error is the
        # one raised.
        def cleanup(failed)
          SingleCandidateTest.guarded(:cleanup_failed) { finish }
        rescue StandardError
          raise unless failed
        end

        def start
          @connection.exec("BEGIN READ ONLY")
          @connection.exec("SET LOCAL plan_cache_mode = force_custom_plan")
          @connection.exec("SET LOCAL hypopg.enabled = on")
          @connection.exec(HypoPG.reset_sql(hypopg(:explain_failed)))
          raise Error, :indexes_hidden if hidden_indexes?
        end

        # HypoPG's schema, quoted, read once (see HypoPG.schema).
        def hypopg(rule) = (@hypopg ||= HypoPG.schema(@connection, rule))

        # HypoPG keeps real indexes hidden with hypopg_hide_index for the
        # session, and hypopg_reset doesn't unhide them, so the baseline and
        # every candidate would plan without them. They aren't unhidden
        # here, since that isn't transactional and the caller hid them.
        # HypoPG before 1.4 has no hypopg_hidden_indexes, so the run fails
        # closed there, as explain_failed with 42883.
        def hidden_indexes?
          @connection.exec(HypoPG.hidden_count_sql(hypopg(:explain_failed))).getvalue(0, 0) != "0"
        end

        def finish
          @connection.exec("ROLLBACK") unless @connection.transaction_status.zero?
          deallocate if @prepared
          @connection.exec(HypoPG.reset_sql(hypopg(:cleanup_failed)))
        end

        def deallocate
          @connection.exec("DEALLOCATE #{STATEMENT}")
          @prepared = false
        end

        # The new index's oid, name, and size, or, if HypoPG refused it,
        # three nils and the SQLSTATE.
        def create(candidate)
          # The savepoint is there for a refused create to roll back to. It's
          # never released: nothing in it writes, and the run's rollback
          # ends every one left open.
          @connection.exec("SAVEPOINT #{STATEMENT}")
          created = @connection.exec_params(HypoPG.create_sql(hypopg(:hypopg_failed)), [candidate.to_ddl])
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

        # indexes holds each hypothetical index's oid, name, size, and
        # candidate.
        def plans(indexes)
          identities = indexes.to_h { |oid, _, _, candidate| [oid, candidate.to_ddl] }
          names = indexes.map { |i| i[1] }
          @literal_sets.to_h { |set, values| [set, plan(explain(values), names, identities)] }.freeze
        end

        def explain(values)
          SingleCandidateTest.guarded(:prepare_failed) { Redaction.prepare(@connection, STATEMENT, @query, @types) }
          @prepared = true
          json = SingleCandidateTest.guarded(:explain_failed) do
            execute = SingleCandidateTest.execute(@connection, values)
            @connection.exec("EXPLAIN (FORMAT JSON) EXECUTE #{execute}").getvalue(0, 0)
          end
          SingleCandidateTest.guarded(:cleanup_failed) { deallocate }
          SingleCandidateTest.parse_plan(json)
        end

        # used says, for each hypothetical index, whether any node scans it,
        # by the exact name HypoPG gave it. Only this measurement's
        # hypothetical indexes exist while it plans, since measure resets
        # HypoPG first. (A hypothetical index that a function the planner
        # folds creates in the middle of planning doesn't show up in the
        # plan, as tried on HypoPG 1.4.) But a real index can have a name
        # that looks like a hypothetical one, such as "<1>x", so matching
        # any name that starts with "<" would count it.
        def plan(explain, index_names, identities)
          root = explain.first["Plan"]
          scanned = PlanNode.new(root).subtree.map { |node| node["Index Name"] }
          Measured.new(used: index_names.map { |name| scanned.include?(name) }.freeze, total_cost: root["Total Cost"],
                       canonical_plan: CanonicalPlan.new(explain, hypothetical_indexes: identities),
                       raw_plan: explain)
        end
      end
    end
  end
end
