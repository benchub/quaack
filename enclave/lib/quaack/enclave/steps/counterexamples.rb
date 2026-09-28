# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_entry"
require_relative "../arena_runner"
require_relative "../counterexamples"
require_relative "../redaction"
require_relative "../run_server"
require_relative "../scenarios"
require_relative "../step_nine"
require_relative "../table_name"
require_relative "index_payload"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # DESIGN.md steps 9 and 10 for one stored rewrite, on the arena. Each
      # takes --search rewrite_<n>. The original runs as anchored_query; the
      # candidate is the rewrite's SQL with each $n bound to its literal
      # from placeholder_map (Enclave::Counterexamples.bind).
      #
      # Store entries, which the driver resumes by and step 11 reads:
      #   rewrite_tested_<n>   { "passed", "scenario", "rule", "untested",
      #                          "untested_atoms" }, step 9's result
      #   rewrite_survived_<n> { "survived" => Boolean }, written once
      #                        steps 9 and 10 are done with the rewrite:
      #                        false when step 8 discarded it, step 9
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
        # Refuses (<prefix>_no_arena_setup) a run whose arena 4b hasn't set up.
        def arena!(store, prefix)
          raise Error, "#{prefix}_no_arena_setup" unless store.entry?("arena_setup")
        end

        def queries(store, search)
          map = Redaction.placeholder_map(store)
          [store.read("anchored_query"), RewriteEntry.run_sql(store.read(search))].map { Enclave::Counterexamples.bind(it, map) }
        end

        def survived(store, number, survived)
          store.write("rewrite_survived_#{number}", "survived" => survived)
        end

        # `quaacks rewrite-test` (step 9). A rewrite whose
        # rewrite_pruned_<n> says discarded is skipped, with rule discarded.
        # Sends one rewrite_test: rewrite, passed, scenario, rule.
        module RewriteTest
          module_function

          def call(store:, options:, **)
            search = options.fetch("search")
            number = Counterexamples.search!(store, search, "rewrite_test")
            result = discarded?(store, number) ? discarded : test(store, search)
            store.write("rewrite_tested_#{number}", result)
            Counterexamples.survived(store, number, false) unless result["passed"]
            [{ type: :rewrite_test, rewrite: search,
               **result.slice("passed", "scenario", "rule").transform_keys(&:to_sym) }]
          end

          def discarded?(store, number)
            store.entry?("rewrite_pruned_#{number}") && store.read("rewrite_pruned_#{number}")["discarded"]
          end

          def discarded
            { "passed" => false, "scenario" => nil, "rule" => "discarded", "untested" => [], "untested_atoms" => [] }
          end

          def test(store, search)
            Counterexamples.arena!(store, "rewrite_test")
            connection = Enclave::RunServer.connect(store, :arena)
            original, candidate = Counterexamples.queries(store, search)
            report = StepNine.run(connection, original, [candidate])
            result = report.results.first
            { "passed" => result.passed, "scenario" => result.scenario&.to_s, "rule" => result.rule&.to_s,
              "untested" => report.untested, "untested_atoms" => report.untested_atoms }
          ensure
            connection&.close
          end
        end

        # `quaacks counterexample-payload` (10a): the shape-only payload for
        # the LLM, as one counterexample_payload: original (the redacted
        # query), candidate ({ "sql" }, the rewrite's SQL with $n
        # placeholders; its transformation and assumptions stay here),
        # placeholders and schema as in index_payload, and untested_atoms
        # (step 9's redacted shapes). It doesn't connect to anything.
        module Payload
          module_function

          def call(store:, options:, **)
            search = options.fetch("search")
            number = Counterexamples.search!(store, search, "counterexample_payload")
            tested = store.read("rewrite_tested_#{number}") if store.entry?("rewrite_tested_#{number}")
            raise Error, "counterexample_payload_untested" unless tested

            [{ type: :counterexample_payload, original: store.read("redacted_query"),
               candidate: { "sql" => store.read(search)["sql"] },
               placeholders: IndexPayload.placeholders(store),
               schema: IndexPayload.schema(store), untested_atoms: tested["untested"] }]
          end
        end

        # `quaacks counterexample-round --round <1 to 3>` (10b and 10c).
        # stdin is {"inserts": [String, ...]}, the LLM's inserts. It needs
        # step 9 to have passed. Sends one counterexample_round: match,
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
            outcome = run(store, search, number, inserts)
            finish(store, number, options.fetch("round"), outcome)
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

          def run(store, search, number, inserts)
            connection = Enclave::RunServer.connect(store, :arena)
            prepared = prepare(connection, store, inserts)
            round = compare(connection, prepared, store, search, number)
            { match: round.match, rule: round.rule&.to_s, load_order: round.load_order&.to_s, covered: round.covered,
              refused: prepared.refused, load_failed: round.load_failed }
          ensure
            connection&.close
          end

          def prepare(connection, store, inserts)
            Enclave::Counterexamples.prepare(connection, inserts, placeholder_map: Redaction.placeholder_map(store),
                                                                  tables: tables(store))
          end

          def compare(connection, prepared, store, search, number)
            original, candidate = Counterexamples.queries(store, search)
            untested = store.read("rewrite_tested_#{number}")["untested_atoms"]
            atoms = Scenarios::Builder.new(connection, PgQuery.parse(original)).atoms
            Enclave::Counterexamples.compare(ArenaRunner.new(connection), prepared,
                                             original:, candidate:, atoms:, untested:)
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
          # 1, compared the queries on loaded fixtures ("evidence").
          def finish(store, number, round, outcome)
            evidence = !outcome[:match].nil? || (round != "1" && store.read("rewrite_round_#{number}")["evidence"])
            store.write("rewrite_round_#{number}", "round" => Integer(round), "evidence" => evidence)
            return Counterexamples.survived(store, number, false) if outcome[:match] == false
            return unless round == ROUNDS.last

            store.write("rewrite_survived_#{number}", "survived" => true, "evidence" => evidence)
          end
        end
      end
    end
  end
end
