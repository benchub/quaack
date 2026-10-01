# frozen_string_literal: true

require_relative "counterexamples"
require_relative "enclave_error"
require_relative "generator_three"
require_relative "operator_candidates"
require_relative "progress"
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
    # rewrites are the operator's own (DESIGN.md step 7), from `--rewrites`.
    # With stderr, a Progress there shows each step as it runs or is skipped,
    # and the client is given it too, so each LLM ask and retry shows under it.
    #
    # It resumes. It first asks `quaacks status` which step outputs the
    # store holds, and skips the steps whose outputs are there. Each
    # orchestration task adds its stage to STAGES, and the entries it
    # checks to the enclave's Status::ENTRIES. An EnclaveError, such as the
    # plan gate's abort, stops the run where it is.
    class Pipeline
      # DESIGN.md step 5 and 5a, for the original query:
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

        def run(transport:, client:, run_id:, entries:, progress: Progress::NULL, **) # rubocop:disable Metrics/ParameterLists
          args = { run: run_id, search: SEARCH }
          Pipeline.run_step(progress, entries["index_search_#{SEARCH}"], "index-search",
                            "plan gate and index search") do
            transport.call("index-search", args:)
          end
          llm(transport, client, run_id, SEARCH, { generated: entries["index_generated_#{SEARCH}"],
                                                   ranked: entries["index_ranking_#{SEARCH}"] }, progress)
        end

        # 5a-5 unless done[:generated], 5a-6, and 5a-7 unless done[:ranked],
        # for search.
        def llm(transport, client, run_id, search, done, progress = Progress::NULL) # rubocop:disable Metrics/ParameterLists
          args = { run: run_id, search: }
          fetched = nil
          payload = lambda do
            fetched ||= transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" }
          end
          Pipeline.run_step(progress, done[:generated], "5a-5", "generator three (LLM)") do
            generate(transport, client, run_id, search, payload.call)
          end
          progress.step("5a-6", "refinement round (LLM)") { refine(transport, client, run_id, search, payload) }
          Pipeline.run_step(progress, done[:ranked], "5a-7", "index-rank") { transport.call("index-rank", args:) }
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

      # DESIGN.md 6a, step 7, and step 8, after step 5:
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

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          entries = generated(transport, client, run_id, entries, rewrites, progress)
          progress.step("step 8", "rewrite index searches") do
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.each do |number|
              step8(transport, run_id, entries, number, progress.within("rewrite_#{number}"))
            end
          end
        end

        # entries, asked again if 6a or step 7 still had to run, after
        # running them; else the skips are printed.
        def generated(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          if Pipeline.checked?(entries, rewrites)
            progress.skip("6a")
            progress.skip("step 7") if rewrites
            return entries
          end
          generate(transport, client, run_id, entries, rewrites, progress)
          Pipeline.status(transport, run_id)
        end

        def generate(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          payload = transport.call("rewrite-payload", args: { run: run_id }).messages
                             .find { it["type"] == "rewrite_payload" }
          Pipeline.run_step(progress, entries["rewrites_generated"], "6a", "rewrite generation (LLM)") do
            RewriteGeneration.new(client:, rewrite_check: RewriteGeneration.rewrite_check(transport, run_id:))
                             .run(payload)
          end
          operator(transport, client, run_id, entries, rewrites, payload, progress) unless rewrites.nil?
        end

        # Step 7, unless the store says it ran.
        def operator(transport, client, run_id, entries, rewrites, payload, progress) # rubocop:disable Metrics/ParameterLists
          Pipeline.run_step(progress, entries["operator_rewrites_checked"], "step 7", "operator rewrites (LLM)") do
            raise OperatorCandidates::Error, "no_rewrite_payload" unless payload

            OperatorCandidates.new(client:, rewrite_check: OperatorCandidates.rewrite_check(transport, run_id:))
                              .run(payload, rewrites)
          end
        end

        def step8(transport, run_id, entries, number, progress)
          STEP8.each do |subcommand, output|
            Pipeline.run_step(progress, entries["#{output}#{number}"], subcommand) do
              transport.call(subcommand, args: { run: run_id, search: "rewrite_#{number}" })
            end
          end
        end
      end

      # DESIGN.md steps 9 and 10, after step 8. If 6a or step 7 ran in this run, it asks
      # status again, for the rewrites it stored. For each stored rewrite_<n> not yet decided
      # (rewrite_survived_<n>): rewrite-test (step 9), unless it's stored
      # (rewrite_tested_<n>), and, if the rewrite passed, the three 10a to
      # 10c rounds (Counterexamples) on counterexample-payload, each round
      # a numbered counterexample-round. The enclave records survival.
      module CounterexampleStage
        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          progress.step("steps 9-10", "counterexamples (LLM)") do
            entries = Pipeline.status(transport, run_id) unless Pipeline.checked?(entries, rewrites)
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.each do |number|
              sub = progress.within("rewrite_#{number}")
              next sub.skip("steps 9-10") if entries["rewrite_survived_#{number}"]

              rewrite(transport, client, { run: run_id, search: "rewrite_#{number}" },
                      entries["rewrite_tested_#{number}"], sub)
            end
          end
        end

        def rewrite(transport, client, args, tested, progress)
          passed = Pipeline.run_step(progress, tested, "rewrite-test") do
            message(transport.call("rewrite-test", args:), "rewrite_test")["passed"]
          end
          return unless tested || passed

          progress.step("counterexample rounds (LLM)") do
            payload = message(transport.call("counterexample-payload", args:), "counterexample_payload")
            Counterexamples.new(client:).run(payload, compare: compare(transport, args))
          end
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

      # DESIGN.md step 11, after steps 9 and 10: status is asked again, then IndexStage's
      # 5a-5, 5a-6, and 5a-7 run for each stored rewrite_<n> it marks
      # rewrite_step11_<n>: survived steps 9 and 10, and not pruned in step
      # 8. 5a-5 is skipped once index_generated_rewrite_<n> is stored, and
      # the second 5a-7 once index_llm_ranked_rewrite_<n> is.
      module RewriteIndexStage
        module_function

        def run(transport:, client:, run_id:, progress: Progress::NULL, **)
          progress.step("step 11", "rewrite indexes (LLM)") do
            entries = Pipeline.status(transport, run_id)
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.select { entries["rewrite_step11_#{it}"] }.each do |n|
              IndexStage.llm(transport, client, run_id, "rewrite_#{n}",
                             { generated: entries["index_generated_rewrite_#{n}"],
                               ranked: entries["index_llm_ranked_rewrite_#{n}"] }, progress.within("rewrite_#{n}"))
            end
          end
        end
      end

      # DESIGN.md step 4b, before steps 9 and 10, which refuse without the
      # arena: arena-setup, unless the store holds arena_setup.
      module ArenaStage
        module_function

        def run(transport:, run_id:, entries:, progress: Progress::NULL, **)
          Pipeline.run_step(progress, entries["arena_setup"], "4b", "arena-setup") do
            transport.call("arena-setup", args: { run: run_id })
          end
        end
      end

      # DESIGN.md 12a to 14d, after step 11, in order: each step whose output
      # isn't stored. Earlier stages don't write these outputs, so the
      # entries from the start of the run still hold. It returns them with
      # the steps it ran marked done, for ReportStage.
      module MeasurementStage
        STEPS = { "index-build" => "index_build", "baseline" => "baseline", "index-baseline" => "index_baseline",
                  "candidate-runs" => "candidate_runs", "minimax" => "minimax",
                  "result-comparison" => "result_comparison", "selection" => "selection" }.freeze
        # Each step's number in DESIGN.md.
        NUMBERS = { "index-build" => "12a", "baseline" => "13", "index-baseline" => "13a", "candidate-runs" => "14",
                    "minimax" => "14b", "result-comparison" => "14c", "selection" => "14d" }.freeze

        module_function

        def run(transport:, run_id:, entries:, progress: Progress::NULL, **)
          STEPS.each_with_object(entries.dup) do |(subcommand, output), done|
            Pipeline.run_step(progress, done[output], NUMBERS.fetch(subcommand), subcommand) do
              transport.call(subcommand, args: { run: run_id })
              done[output] = true
            end
          end
        end
      end

      # DESIGN.md step 15, last: once the store holds selection (14d), the
      # report message from report-payload rendered as HTML to out.
      # MeasurementStage has stored selection by the time it runs. It writes
      # nothing, and asks for nothing, when there's no out. Rerunning
      # renders it again.
      module ReportStage
        module_function

        def run(transport:, run_id:, out:, client: nil, progress: Progress::NULL, **) # rubocop:disable Metrics/ParameterLists
          return unless out

          progress.step("15", "report") do
            payload = CounterexampleStage.message(transport.call("report-payload", args: { run: run_id }), "report")
            Report.write(payload, run_id:, path: out, llm_calls: client ? client.burndown.llm_calls : {})
          end
        end
      end

      STAGES = [IndexStage, RewriteStage, ArenaStage, CounterexampleStage, RewriteIndexStage].freeze

      # The number of steps a run counts in its progress: 16, plus step 7
      # with rewrites, plus the report with out. Sub-steps for each rewrite
      # print under their step, uncounted, since how many there are isn't
      # known until the run gets there.
      def self.total(rewrites:, out:) = 16 + (rewrites.nil? ? 0 : 1) + (out ? 1 : 0)

      # Skips the step, printing so, if done, or runs the block as a step.
      def self.run_step(progress, done, name, description = nil, &)
        done ? progress.skip(name) : progress.step(name, description, &)
      end

      # The entries `quaacks status` says the run's store holds.
      def self.status(transport, run_id)
        transport.call("status", args: { run: run_id }).messages.find { it["type"] == "status" }.fetch("entries")
      end

      # Whether entries say 6a ran, and step 7 too if there are rewrites.
      def self.checked?(entries, rewrites)
        entries["rewrites_generated"] && (rewrites.nil? || rewrites.empty? || entries["operator_rewrites_checked"])
      end

      def initialize(transport:, client:, run_id:, rewrites: nil, out: nil, stderr: nil) # rubocop:disable Metrics/ParameterLists
        @progress = stderr ? Progress.new(io: stderr, total: self.class.total(rewrites:, out:)) : Progress::NULL
        client&.progress = @progress
        @out = out
        @transport = transport
        @client = client
        @run_id = run_id
        @rewrites = rewrites
      end

      def run
        entries = self.class.status(@transport, @run_id)
        STAGES.each do |stage|
          stage.run(transport: @transport, client: @client, run_id: @run_id, entries:, rewrites: @rewrites,
                    progress: @progress)
        end
        MeasurementStage.run(transport: @transport, run_id: @run_id, entries:, progress: @progress)
        ReportStage.run(transport: @transport, client: @client, run_id: @run_id, out: @out, progress: @progress)
      end
    end
  end
end
