# frozen_string_literal: true

require_relative "counterexamples"
require_relative "enclave_error"
require_relative "generator_three"
require_relative "operator_candidates"
require_relative "refinement_round"
require_relative "report"
require_relative "rewrite_generation"

module Quaack
  module Driver
    # What `quaack run --run ID` drives: every remaining step of a run, in
    # order, over the transport to the run's jump server.
    #
    #   Pipeline.new(transport:, client:, run_id:, rewrites: nil, out: nil).run
    #   # => the report's path, or nil if none was written (ReportStage)
    #
    # rewrites are the operator's own (README step 7), from `--rewrites`.
    #
    # It resumes. It first asks `quaacks status` which step outputs the
    # store holds, and skips the steps whose outputs are there. Each
    # orchestration task adds its stage to STAGES, and the entries it
    # checks to the enclave's Status::ENTRIES. An EnclaveError, such as the
    # plan gate's abort, stops the run where it is.
    class Pipeline
      # README step 5 and 5a, for the original query:
      # 1. index-search: the plan gate, 5a-1 and 5a-2 filtered by 5a-3, and
      #    5a-4 on the mechanical candidates.
      # 2. 5a-5: GeneratorThree, on index-payload. If the LLM proposes
      #    nothing, an index-test with no DDL records that 5a-5 ran.
      # 3. 5a-6: RefinementRound, which index-feedback tells whether to run.
      #    index-payload is fetched only when 5a-5 or 5a-6 asks the LLM.
      # 4. index-rank: 5a-7.
      module IndexStage
        SEARCH = "original"

        module_function

        def run(transport:, client:, run_id:, entries:, **)
          args = { run: run_id, search: SEARCH }
          transport.call("index-search", args:) unless entries["index_search_#{SEARCH}"]
          llm(transport, client, run_id, SEARCH, { generated: entries["index_generated_#{SEARCH}"],
                                                   ranked: entries["index_ranking_#{SEARCH}"] })
        end

        # 5a-5 unless done[:generated], 5a-6, and 5a-7 unless done[:ranked],
        # for search.
        def llm(transport, client, run_id, search, done)
          args = { run: run_id, search: }
          fetched = nil
          payload = lambda do
            fetched ||= transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" }
          end
          generate(transport, client, run_id, search, payload.call) unless done[:generated]
          refine(transport, client, run_id, search, payload)
          transport.call("index-rank", args:) unless done[:ranked]
        end

        def generate(transport, client, run_id, search, payload)
          index_test = GeneratorThree.index_test(transport, run_id:, search:)
          result = GeneratorThree.new(client:, index_test:).run(payload)
          index_test.call([]) if result.rounds.empty?
        end

        def refine(transport, client, run_id, search, payload)
          index_feedback = RefinementRound.index_feedback(transport, run_id:, search:)
          index_test = RefinementRound.index_test(transport, run_id:, search:)
          RefinementRound.new(client:, index_feedback:, index_test:).run(payload)
        end
      end

      # README 6a, step 7, and step 8, after step 5:
      # 1. 6a: RewriteGeneration on rewrite-payload, unless the store says
      #    it ran (rewrites_generated). Its rewrite-check stores the
      #    survivors as rewrite_<n>.
      #    Step 7: OperatorCandidates on the same payload, for the operator's
      #    rewrites, unless there are none or the store says it ran
      #    (operator_rewrites_checked). Its survivors are stored after 6a's.
      #    If either ran, status is asked again for them.
      # 2. Step 8, for each stored rewrite_<n> in order: index-search,
      #    index-rank, and rewrite-prune, each skipped when its output is
      #    stored.
      module RewriteStage
        STEP8 = { "index-search" => "index_search_rewrite_", "index-rank" => "index_ranking_rewrite_",
                  "rewrite-prune" => "rewrite_pruned_" }.freeze

        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil)
          unless Pipeline.checked?(entries, rewrites)
            generate(transport, client, run_id, entries, rewrites)
            entries = Pipeline.status(transport, run_id)
          end
          (1..).lazy.take_while { entries["rewrite_#{it}"] }.each { step8(transport, run_id, entries, it) }
        end

        def generate(transport, client, run_id, entries, rewrites)
          payload = transport.call("rewrite-payload", args: { run: run_id }).messages
                             .find { it["type"] == "rewrite_payload" }
          unless entries["rewrites_generated"]
            RewriteGeneration.new(client:, rewrite_check: RewriteGeneration.rewrite_check(transport, run_id:))
                             .run(payload)
          end
          return if rewrites.nil? || rewrites.empty? || entries["operator_rewrites_checked"]
          raise OperatorCandidates::Error, "no_rewrite_payload" unless payload

          OperatorCandidates.new(client:, rewrite_check: OperatorCandidates.rewrite_check(transport, run_id:))
                            .run(payload, rewrites)
        end

        def step8(transport, run_id, entries, number)
          STEP8.each do |subcommand, output|
            next if entries["#{output}#{number}"]

            transport.call(subcommand, args: { run: run_id, search: "rewrite_#{number}" })
          end
        end
      end

      # README steps 9 and 10, after step 8. If 6a or step 7 ran in this run, it asks
      # status again, for the rewrites it stored. For each stored rewrite_<n> not yet decided
      # (rewrite_survived_<n>): rewrite-test (step 9), unless it's stored
      # (rewrite_tested_<n>), and, if the rewrite passed, the three 10a to
      # 10c rounds (Counterexamples) on counterexample-payload, each round
      # a numbered counterexample-round. The enclave records survival.
      module CounterexampleStage
        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil)
          entries = Pipeline.status(transport, run_id) unless Pipeline.checked?(entries, rewrites)
          (1..).lazy.take_while { entries["rewrite_#{it}"] }.each do |number|
            next if entries["rewrite_survived_#{number}"]

            rewrite(transport, client, { run: run_id, search: "rewrite_#{number}" },
                    entries["rewrite_tested_#{number}"])
          end
        end

        def rewrite(transport, client, args, tested)
          return unless tested || message(transport.call("rewrite-test", args:), "rewrite_test")["passed"]

          payload = message(transport.call("counterexample-payload", args:), "counterexample_payload")
          Counterexamples.new(client:).run(payload, compare: compare(transport, args))
        end

        def compare(transport, args)
          round = 0
          lambda do |inserts|
            round += 1
            reply = transport.call("counterexample-round", args: args.merge(round: round.to_s),
                                                           input: { "inserts" => inserts })
            message(reply, "counterexample_round")
          end
        end

        # The reply's message of this type. A reply without one fails the
        # run with the rule no_<type>, as an EnclaveError.
        def message(reply, type)
          reply.messages.find { it["type"] == type } ||
            raise(EnclaveError.new(subcommand: type.tr("_", "-"), rule: "no_#{type}"))
        end
      end

      # README step 11, after steps 9 and 10: status is asked again, then IndexStage's
      # 5a-5, 5a-6, and 5a-7 run for each stored rewrite_<n> it marks
      # rewrite_step11_<n>: survived steps 9 and 10, and not pruned in step
      # 8. 5a-5 is skipped once index_generated_rewrite_<n> is stored, and
      # the second 5a-7 once index_llm_ranked_rewrite_<n> is.
      module RewriteIndexStage
        module_function

        def run(transport:, client:, run_id:, **)
          entries = Pipeline.status(transport, run_id)
          (1..).lazy.take_while { entries["rewrite_#{it}"] }.select { entries["rewrite_step11_#{it}"] }.each do |n|
            IndexStage.llm(transport, client, run_id, "rewrite_#{n}",
                           { generated: entries["index_generated_rewrite_#{n}"],
                             ranked: entries["index_llm_ranked_rewrite_#{n}"] })
          end
        end
      end

      # README step 4b, before steps 9 and 10, which refuse without the
      # arena: arena-setup, unless the store holds arena_setup.
      module ArenaStage
        module_function

        def run(transport:, run_id:, entries:, **)
          transport.call("arena-setup", args: { run: run_id }) unless entries["arena_setup"]
        end
      end

      # README 12a to 14d, after step 11, in order: each step whose output
      # isn't stored. Earlier stages don't write these outputs, so the
      # entries from the start of the run still hold. It returns them with
      # the steps it ran marked done, for ReportStage.
      module MeasurementStage
        STEPS = { "index-build" => "index_build", "baseline" => "baseline", "index-baseline" => "index_baseline",
                  "candidate-runs" => "candidate_runs", "minimax" => "minimax",
                  "result-comparison" => "result_comparison", "selection" => "selection" }.freeze

        module_function

        def run(transport:, run_id:, entries:, **)
          STEPS.each_with_object(entries.dup) do |(subcommand, output), done|
            next if done[output]

            transport.call(subcommand, args: { run: run_id })
            done[output] = true
          end
        end
      end

      # README step 15, last: once the store holds selection (14d), the
      # report message from report-payload rendered as HTML to out.
      # MeasurementStage has stored selection by the time it runs. It writes
      # nothing, and asks for nothing, when there's no out. Rerunning
      # renders it again.
      module ReportStage
        module_function

        def run(transport:, run_id:, out:, client: nil, **)
          return unless out

          payload = CounterexampleStage.message(transport.call("report-payload", args: { run: run_id }), "report")
          Report.write(payload, run_id:, path: out, llm_calls: client ? client.burndown.llm_calls : {})
        end
      end

      STAGES = [IndexStage, RewriteStage, ArenaStage, CounterexampleStage, RewriteIndexStage].freeze

      # The entries `quaacks status` says the run's store holds.
      def self.status(transport, run_id)
        transport.call("status", args: { run: run_id }).messages.find { it["type"] == "status" }.fetch("entries")
      end

      # Whether entries say 6a ran, and step 7 too if there are rewrites.
      def self.checked?(entries, rewrites)
        entries["rewrites_generated"] && (rewrites.nil? || rewrites.empty? || entries["operator_rewrites_checked"])
      end

      def initialize(transport:, client:, run_id:, rewrites: nil, out: nil)
        @out = out
        @transport = transport
        @client = client
        @run_id = run_id
        @rewrites = rewrites
      end

      def run
        entries = self.class.status(@transport, @run_id)
        STAGES.each { it.run(transport: @transport, client: @client, run_id: @run_id, entries:, rewrites: @rewrites) }
        entries = MeasurementStage.run(transport: @transport, run_id: @run_id, entries:)
        ReportStage.run(transport: @transport, client: @client, run_id: @run_id, out: @out)
      end
    end
  end
end
