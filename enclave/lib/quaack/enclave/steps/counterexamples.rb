# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_entry"
require_relative "../arena_runner"
require_relative "../predicate_atoms"
require_relative "../counterexamples"
require_relative "../deadline"
require_relative "../denormalized_fixture"
require_relative "../redaction"
require_relative "../rewrite_burndown"
require_relative "../run_server"
require_relative "../scenarios"
require_relative "../table_name"
require_relative "index_payload"
require_relative "index_search"
require_relative "rewrite_fuzz"

module Quaack
  module Enclave
    module Steps
      # DESIGN.md rewrite-test and counterexamples for one stored rewrite, on the arena. Each
      # takes --search rewrite_<n>. The original runs as anchored_query; the
      # candidate is the rewrite's SQL with each $n bound to its literal
      # from placeholder_map (Enclave::Counterexamples.bind). The arena's
      # fixtures honour the rewrite's own denormalized_equal assumptions
      # when a rewrite-rules rule wrote it (DenormalizedFixture).
      #
      # Store entries, which the driver resumes by and rewrite-index-ideas reads:
      #   rewrite_tested_<n>   rewrite-test's result (RewriteFuzz.result):
      #                        { "passed", "rule", "stage", "trials",
      #                          "worlds", "bound", "untested",
      #                          "untested_atoms", "untested_unchanged" },
      #                        plus "sizes" for a disproof. An entry from
      #                        before task 20261012-4 has ScenarioTests'
      #                        fields instead: "scenario", "dropped",
      #                        "refused", "untested_states" and the like
      #                        (RewriteFate reads both)
      #   rewrite_round_<n>    { "round", "evidence", "rule", "covered" }, the
      #                        last counterexample-compare round run (see
      #                        Round.finish)
      #   rewrite_survived_<n> { "survived" => Boolean }, written once
      #                        rewrite-test and counterexamples are done with the rewrite:
      #                        false when plan-pruning discarded it, rewrite-test
      #                        disproved it, or a round found a mismatch;
      #                        true after a matching round 3, with
      #                        "evidence" false if no round's inserts
      #                        ever loaded, so the report can flag it.
      module Counterexamples
        OPTIONS = { "search" => :value }.freeze
        REQUIRED = %w[search].freeze

        class Error < IndexSearch::Error; end

        module_function

        def search!(store, search, prefix)
          unless search.is_a?(String) && search != "original" && IndexSearch.search?(store, search)
            raise Error, "#{prefix}_unknown_search"
          end

          search.delete_prefix("rewrite_")
        end

        # The original and the candidate, each with its $n bound.
        # Refuses (<prefix>_no_arena_setup) a run whose arena hasn't been set up by arena-setup.
        def arena!(store, prefix)
          raise Error, "#{prefix}_no_arena_setup" unless store.entry?("arena_setup")
        end

        def queries(store, search)
          map = Redaction.placeholder_map(store)
          [store.read("anchored_query"), RewriteEntry.run_sql(store.read(search))].map { Enclave::Counterexamples.bind(it, map) }
        end

        # The rewrite's own denormalized_equal assumptions, from a rewrite-rules rule,
        # that the arena's fixtures honour (DenormalizedFixture).
        def honour(store, search) = DenormalizedFixture.copies(store.read(search))

        def survived(store, number, survived)
          store.write("rewrite_survived_#{number}", "survived" => survived)
        end

        # `quaacks rewrite-test` (rewrite-test): the disproof search,
        # fuzz then enumerate (RewriteFuzz). A rewrite whose
        # rewrite_pruned_<n> says discarded is skipped, with rule discarded.
        # Sends one rewrite_test: rewrite, passed, rule, stage, trials,
        # worlds, bound.
        #
        # deadline is the rewrite's budget (Deadline, five minutes from the
        # call). The search can only disprove a rewrite, so one it couldn't
        # test, or didn't finish, isn't disproved: it goes on to
        # counterexamples and the later stages as passed, with why as its
        # rule, the report's caution (RewriteFuzz), and the next rewrite is
        # tested as usual. (An entry from before task 20261011-15 has
        # passed false, and RewriteFate calls it rewrite_test_out_of_time.)
        # The step still ends cleanly, unless a cancel QUAACK didn't send
        # ends it.
        module RewriteTest
          module_function

          def call(store:, options:, deadline: Deadline.new, **)
            search = options.fetch("search")
            number = Counterexamples.search!(store, search, "rewrite_test")
            result = discarded?(store, number) ? discarded : test(store, search, deadline)
            # Survival first: a crash between the two writes leaves the
            # rewrite untested, so a resumed run tests it again.
            Counterexamples.survived(store, number, false) unless result["passed"]
            store.write("rewrite_tested_#{number}", result)
            [{ type: :rewrite_test, rewrite: search, **result.slice(*MESSAGE_KEYS).transform_keys(&:to_sym) }]
          end

          MESSAGE_KEYS = %w[passed rule stage trials worlds bound].freeze

          def discarded?(store, number)
            store.entry?("rewrite_pruned_#{number}") && store.read("rewrite_pruned_#{number}")["discarded"]
          end

          def discarded
            { "passed" => false, "rule" => "discarded", "untested" => [], "untested_atoms" => [],
              "untested_unchanged" => [] }
          end

          # The search's result, once its burndown is recorded. The
          # arena's connection is made only when the search needs it.
          def test(store, search, deadline)
            Counterexamples.arena!(store, "rewrite_test")
            connection = nil
            connect = -> { connection ||= Enclave::RunServer.connect(store, :arena) }
            results = RewriteFuzz.call(store, search, deadline, connect)
            RewriteFuzz.record(store, search, results)
            RewriteFuzz.result(store, search, results)
          ensure
            connection&.close
          end
        end

        # `quaacks counterexample-payload` (llm-counterexamples): the shape-only payload for
        # the LLM, as one counterexample_payload: original (the redacted
        # query), candidate ({ "sql" }, the rewrite's SQL with $n
        # placeholders; its transformation and assumptions stay here),
        # placeholders and schema as in index_payload, and untested_atoms
        # (rewrite-test's redacted shapes, less the USING and NATURAL JOIN
        # markers no insert can cover). It doesn't connect to anything.
        module Payload
          module_function

          def call(store:, options:, **)
            search = options.fetch("search")
            number = Counterexamples.search!(store, search, "counterexample_payload")
            tested = store.read("rewrite_tested_#{number}") if store.entry?("rewrite_tested_#{number}")
            raise Error, "counterexample_payload_untested" unless tested

            untested = tested["untested"].reject { PredicateAtoms.marker_shape?(it) }
            [{ type: :counterexample_payload, original: store.read("redacted_query"),
               candidate: { "sql" => store.read(search)["sql"] },
               placeholders: IndexPayload.placeholders(store),
               schema: IndexPayload.schema(store), untested_atoms: untested }]
          end
        end

        # `quaacks counterexample-round --round <1 to 3>` (counterexample-compare and counterexample-rollback).
        # stdin is {"inserts": [String, ...]}, the LLM's inserts. It needs
        # rewrite-test to have passed. Sends one counterexample_round: match,
        # rule, load_order, covered (redacted atom shapes), refused (each
        # refused insert's index and rule), and load_failed.
        module Round
          OPTIONS = { "search" => :value, "round" => :value }.freeze
          REQUIRED = %w[search round].freeze
          ROUNDS = %w[1 2 3].freeze

          module_function

          def call(store:, options:, input:, **)
            search = options.fetch("search")
            number = Counterexamples.search!(store, search, "counterexample_round")
            inserts = check(store, number, options.fetch("round"), input)
            outcome, loads = run(store, search, number, inserts)
            finish(store, number, options.fetch("round"), outcome, loads)
            [{ type: :counterexample_round, **outcome }]
          end

          def check(store, number, round, input)
            tested = "rewrite_tested_#{number}"
            raise Error, "counterexample_round_untested" unless store.entry?(tested) && store.read(tested)["passed"]
            raise Error, "counterexample_round_bad_round" unless ROUNDS.include?(round)

            Counterexamples.arena!(store, "counterexample_round")
            sequence!(store, number, round)

            inserts(input)
          end

          def inserts(input)
            inserts = input["inserts"] if input.is_a?(Hash) && input.keys == ["inserts"]
            raise Error, "counterexample_round_bad_inserts" unless inserts.is_a?(Array) && inserts.all?(String)

            inserts
          end

          # The round's outcome, and how many fixtures it loaded. Inserts
          # whose parent rows Scenarios' rules can't build, such as in a NOT
          # NULL foreign key cycle, fail to load, by the rule (a
          # Scenarios::Error), which disproves nothing.
          def run(store, search, number, inserts)
            connection = Enclave::RunServer.connect(store, :arena)
            prepared = prepare(connection, store, inserts, Counterexamples.queries(store, search))
            runner = DenormalizedFixture::Runner.new(connection, Counterexamples.honour(store, search))
            round = compare(runner, connection, prepared, store, search, number)
            [outcome(round, prepared.refused), runner.loads]
          rescue Scenarios::Error => e
            [{ match: nil, rule: e.rule.to_s, load_order: nil, covered: [], refused: [], load_failed: true }, 0]
          ensure
            connection&.close
          end

          def outcome(round, refused)
            { match: round.match, rule: round.rule&.to_s, load_order: round.load_order&.to_s, covered: round.covered,
              refused:, load_failed: round.load_failed }
          end

          def prepare(connection, store, inserts, queries)
            Enclave::Counterexamples.prepare(connection, inserts, placeholder_map: Redaction.placeholder_map(store),
                                                                  tables: tables(store), queries:,
                                                                  settings: Enclave::RunServer.plan_settings(store))
          end

          # The original's atoms are extracted only to cover untested ones,
          # as Fuzz::Coverage numbered them: on the schema of both queries'
          # tables and what their foreign keys reach.
          def compare(runner, connection, prepared, store, search, number) # rubocop:disable Metrics/ParameterLists
            original, candidate = Counterexamples.queries(store, search)
            untested = store.read("rewrite_tested_#{number}")["untested_atoms"]
            atoms = untested.empty? ? [] : atoms(connection, original, candidate)
            Enclave::Counterexamples.compare(runner, prepared,
                                             original:, candidate:, atoms:, untested:)
          end

          def atoms(connection, original, candidate)
            schema = Fuzz::Catalog.new(connection, Fuzz.footprint([original, candidate])).schema
            PredicateAtoms.extract(PgQuery.parse(original), column_names: schema.column_names)
          end

          def tables(store)
            store.read("schema_subset")["tables"].map { |schema, name| TableName.new(schema:, name:) }
          end

          # Round 1 may always start (a resumed run starts over); a later
          # round needs the one before it recorded in rewrite_round_<n>.
          def sequence!(store, number, round)
            raise Error, "counterexample_round_decided" if store.entry?("rewrite_survived_#{number}")

            last = store.entry?("rewrite_round_#{number}") ? store.read("rewrite_round_#{number}")["round"] : 0
            raise Error, "counterexample_round_out_of_order" unless round == "1" || Integer(round) == last + 1
          end

          # rewrite_round_<n> also says whether any round so far, from round
          # 1, compared the queries on loaded fixtures ("evidence"), which
          # untested atoms' shapes any round so far covered ("covered"), and
          # holds this round's "rule": nil for a match, the comparison's
          # rule for a mismatch, or the arena runner's when a statement
          # failed, or original_failed when the round's rows made the
          # original fail (Enclave::Counterexamples.compare), which decides
          # nothing. RewriteFate reads it to tell a disproof from a
          # candidate that failed to run. "fixture_loads" counts the
          # fixtures the rounds so far loaded, for the burndown, which is
          # recorded once survival is decided, before rewrite_survived_<n>
          # (RewriteBurndown.record_round).
          def finish(store, number, round, outcome, loads)
            last = round == "1" ? { "evidence" => false, "covered" => [] } : store.read("rewrite_round_#{number}")
            entry = { "round" => Integer(round), "evidence" => !outcome[:match].nil? || last["evidence"],
                      "rule" => outcome[:rule], "covered" => covered(last, outcome),
                      "fixture_loads" => last.fetch("fixture_loads", 0) + loads }
            store.write("rewrite_round_#{number}", entry)
            decide(store, number, entry, outcome[:match] != false)
          end

          def decide(store, number, entry, survived)
            return unless !survived || entry["round"] == ROUNDS.last.to_i

            RewriteBurndown.record_round(store, "rewrite_#{number}", entry, survived:)
            return Counterexamples.survived(store, number, false) unless survived

            store.write("rewrite_survived_#{number}", "survived" => true, "evidence" => entry["evidence"])
          end

          def covered(last, outcome) = (Array(last["covered"]) + outcome[:covered]).uniq
        end
      end
    end
  end
end
