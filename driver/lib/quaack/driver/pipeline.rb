# frozen_string_literal: true

require_relative "counterexamples"
require_relative "enclave_error"
require_relative "generator_three"
require_relative "operator_candidates"
require_relative "progress"
require_relative "refinement_round"
require_relative "report"
require_relative "rewrite_generation"
require_relative "setup"
require_relative "step_summary"

module Quaack
  module Driver
    # What `quaack run --run ID` drives: every remaining step of a run, in
    # order, over the transport to the run's jump server.
    #
    #   Pipeline.new(transport:, client:, run_id:, rewrites: nil, out: nil, setup: nil).run
    #   # => the report's path, or nil if none was written (ReportStage)
    #
    # rewrites are the operator's own (DESIGN.md step 7), from `--rewrites`.
    # setup, the run-server flags as a Hash, has it do steps 2 to 4a first
    # (Setup), unless the store says the run has had them; nil leaves them
    # to the caller.
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
          Pipeline.run_step(progress, entries["index_search_#{SEARCH}"], "index-search") do
            transport.call("index-search", args:)
          end
          llm(transport, client, run_id, SEARCH, { generated: entries["index_generated_#{SEARCH}"],
                                                   ranked: entries["index_ranking_#{SEARCH}"] }, progress)
        end

        # 5a-5 unless done[:generated], 5a-6, and 5a-7 unless done[:ranked],
        # for search. Returns 5a-6's result, from refine.
        def llm(transport, client, run_id, search, done, progress = Progress::NULL) # rubocop:disable Metrics/ParameterLists
          args = { run: run_id, search: }
          payload = payload(transport, args)
          Pipeline.run_step(progress, done[:generated], "5a-5") do
            generate(transport, client, run_id, search, payload.call)
          end
          refined = Pipeline.step(progress, "5a-6") { refine(transport, client, run_id, search, payload) }
          Pipeline.run_step(progress, done[:ranked], "5a-7") { transport.call("index-rank", args:) }
          refined
        end

        # index-payload's payload, fetched on the first call only.
        def payload(transport, args)
          fetched = nil
          -> { fetched ||= transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" } }
        end

        def generate(transport, client, run_id, search, payload)
          index_test = GeneratorThree.index_test(transport, run_id:, search:)
          step = search == SEARCH ? GeneratorThree::STEP : GeneratorThree::REWRITE_STEP
          result = GeneratorThree.new(client:, index_test:, step:).run(payload)
          index_test.call([]) if result.rounds.empty?
          result
        end

        # RefinementRound's result, or, when it skips the round, :refined if
        # the round already ran, else nil.
        def refine(transport, client, run_id, search, payload)
          feedback = nil
          fetch = RefinementRound.index_feedback(transport, run_id:, search:)
          index_test = RefinementRound.index_test(transport, run_id:, search:)
          step = search == SEARCH ? RefinementRound::STEP : RefinementRound::REWRITE_STEP
          result = RefinementRound.new(client:, index_feedback: -> { feedback = fetch.call }, index_test:, step:)
                                  .run(payload)
          result || (:refined if feedback["refined"])
        end
      end

      # DESIGN.md 6c, 6a, step 7, and step 8, after step 5:
      # 1. 6c: rewrite-rules, the mechanical rules, unless the store says
      #    they were applied (rewrite_rules_applied). It needs no LLM and
      #    no payload, and the enclave stores its survivors as rewrite_<n>.
      #    6a: RewriteGeneration on rewrite-payload, unless the store says
      #    it ran (rewrites_generated). Its rewrite-check stores the
      #    survivors after 6c's.
      #    Step 7: OperatorCandidates on the same payload, for the operator's
      #    rewrites, unless there are none or the store says it ran
      #    (operator_rewrites_checked). Its survivors are stored after 6a's.
      #    If any of the three ran, status is asked again for them. The
      #    payload is fetched only if 6a or step 7 has to run.
      # 2. Step 8, for each stored rewrite_<n> in order: index-search,
      #    index-rank, and rewrite-prune, each skipped when its output is
      #    stored.
      module RewriteStage
        STEP8 = { "index-search" => "index_search_rewrite_", "index-rank" => "index_ranking_rewrite_",
                  "rewrite-prune" => "rewrite_pruned_" }.freeze

        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          entries = generated(transport, client, run_id, entries, rewrites, progress)
          Pipeline.step(progress, "step 8") do
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.map do |number|
              step8(transport, run_id, entries, number, progress.within("Rewrite #{number}"))
            end.to_a
          end
        end

        # entries, asked again if 6c, 6a, or step 7 still had to run, after
        # running them; else the skips are printed.
        def generated(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          return skipped(entries, rewrites, progress) if Pipeline.checked?(entries, rewrites)

          Pipeline.run_step(progress, entries["rewrite_rules_applied"], "6c") do
            transport.call("rewrite-rules", args: { run: run_id })
          end
          if Pipeline.llm_checked?(entries, rewrites)
            skipped(entries, rewrites, progress, from: 1)
          else
            generate(transport, client, run_id, entries, rewrites, progress)
          end
          Pipeline.status(transport, run_id)
        end

        # Prints the skips of 6c, 6a, and step 7, or of those from the
        # given one on, and returns entries.
        def skipped(entries, rewrites, progress, from: 0)
          ["6c", "6a", ("step 7" if rewrites)].compact.drop(from).each { Pipeline.skip(progress, it) }
          entries
        end

        def generate(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          payload = transport.call("rewrite-payload", args: { run: run_id }).messages
                             .find { it["type"] == "rewrite_payload" }
          Pipeline.run_step(progress, entries["rewrites_generated"], "6a") do
            RewriteGeneration.new(client:, rewrite_check: RewriteGeneration.rewrite_check(transport, run_id:))
                             .run(payload)
          end
          operator(transport, client, run_id, entries, rewrites, payload, progress) unless rewrites.nil?
        end

        # Step 7, unless the store says it ran.
        def operator(transport, client, run_id, entries, rewrites, payload, progress) # rubocop:disable Metrics/ParameterLists
          Pipeline.run_step(progress, entries["operator_rewrites_checked"], "step 7") do
            raise OperatorCandidates::Error, "no_rewrite_payload" unless payload

            OperatorCandidates.new(client:, rewrite_check: OperatorCandidates.rewrite_check(transport, run_id:))
                              .run(payload, rewrites)
          end
        end

        # Whether any of step 8's sub-steps ran for the rewrite, rather than
        # all being stored already.
        def step8(transport, run_id, entries, number, progress)
          ran = STEP8.values.any? { !entries["#{it}#{number}"] }
          STEP8.each do |subcommand, output|
            Pipeline.run_step(progress, entries["#{output}#{number}"], subcommand) do
              transport.call(subcommand, args: { run: run_id, search: "rewrite_#{number}" })
            end
          end
          ran
        end
      end

      # DESIGN.md steps 9 and 10, after step 8. If 6c, 6a, or step 7 ran in this run, it asks
      # status again, for the rewrites it stored. For each stored rewrite_<n> not yet decided
      # (rewrite_survived_<n>): rewrite-test (step 9), unless it's stored
      # (rewrite_tested_<n>), and, if the rewrite passed, the three 10a to
      # 10c rounds (Counterexamples) on counterexample-payload, each round
      # a numbered counterexample-round. The enclave records survival. It
      # returns whether each rewrite it tested passed both steps.
      module CounterexampleStage
        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          Pipeline.step(progress, "steps 9-10") do
            entries = Pipeline.status(transport, run_id) unless Pipeline.checked?(entries, rewrites)
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.map do |number|
              undecided(transport, client, run_id, entries, number, progress.within("Rewrite #{number}"))
            end.to_a.compact
          end
        end

        # Whether rewrite number passed, or nil, printing the skip, if the
        # store says it's decided.
        def undecided(transport, client, run_id, entries, number, progress) # rubocop:disable Metrics/ParameterLists
          if entries["rewrite_survived_#{number}"]
            progress.skip("steps 9-10", Pipeline::SAY.fetch("rewrite-tested"))
            return
          end

          rewrite(transport, client, { run: run_id, search: "rewrite_#{number}" },
                  entries["rewrite_tested_#{number}"], progress)
        end

        # Whether the rewrite passed step 9 and steps 10a to 10c.
        def rewrite(transport, client, args, tested, progress)
          passed = Pipeline.run_step(progress, tested, "rewrite-test") do
            message(transport.call("rewrite-test", args:), "rewrite_test")["passed"]
          end
          return false unless tested || passed

          Pipeline.step(progress, "10a-10c") do
            payload = message(transport.call("counterexample-payload", args:), "counterexample_payload")
            !Counterexamples.new(client:).run(payload, compare: compare(transport, args)).disproved
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
          Pipeline.step(progress, "step 11") do
            entries = Pipeline.status(transport, run_id)
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.select { entries["rewrite_step11_#{it}"] }.map do |n|
              asked?(transport, client, run_id, entries, n, progress.within("Rewrite #{n}"))
            end.to_a
          end
        end

        # Runs IndexStage.llm for rewrite n, and returns whether any of 5a-5
        # to 5a-7 did anything, rather than finding it already done.
        def asked?(transport, client, run_id, entries, number, progress) # rubocop:disable Metrics/ParameterLists
          done = { generated: entries["index_generated_rewrite_#{number}"],
                   ranked: entries["index_llm_ranked_rewrite_#{number}"] }
          refined = IndexStage.llm(transport, client, run_id, "rewrite_#{number}", done, progress)
          !done[:generated] || !done[:ranked] || refined.is_a?(RefinementRound::Result)
        end
      end

      # DESIGN.md step 4b, before steps 9 and 10, which refuse without the
      # arena: arena-setup, unless the store holds arena_setup.
      module ArenaStage
        module_function

        def run(transport:, run_id:, entries:, progress: Progress::NULL, **)
          Pipeline.run_step(progress, entries["arena_setup"], "4b") do
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
            Pipeline.run_step(progress, done[output], NUMBERS.fetch(subcommand)) do
              call(transport, subcommand, run_id, progress).tap { done[output] = true }
            end
          end
        end

        # Calls the step, printing each progress message it sends, and
        # returns how many it sent: for 12a, how many indexes it built.
        def call(transport, subcommand, run_id, progress)
          lines = 0
          transport.call(subcommand, args: { run: run_id }) do |message|
            lines += 1
            progress.note(building(message))
          end
          lines
        end

        # A 12a progress message as its line: which index is starting, and
        # its DDL, which the enclave sends only through
        # CandidateDdlRedaction, when there is one.
        def building(message)
          line = "Building index #{message["index"].to_i}/#{message["total"].to_i}"
          message["ddl"].is_a?(String) ? "#{line}: #{message["ddl"]}" : line
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

          Pipeline.step(progress, "15") do
            payload = CounterexampleStage.message(transport.call("report-payload", args: { run: run_id }), "report")
            Report.write(payload, run_id:, path: out, llm_calls: client ? client.burndown.llm_calls : {})
          end
        end
      end

      STAGES = [IndexStage, RewriteStage, ArenaStage, CounterexampleStage, RewriteIndexStage].freeze

      # The number of steps a run counts in its progress: 17, plus step 7
      # with rewrites, plus the report with out, plus Setup's eleven when
      # the run does setup first. Sub-steps for each rewrite print under
      # their step, uncounted, since how many there are isn't known until
      # the run gets there.
      def self.total(rewrites:, out:, setup: false)
        17 + (rewrites.nil? ? 0 : 1) + (out ? 1 : 0) + (setup ? Setup::STEPS.size : 0)
      end

      # Skips the step, printing so, if done, or runs the block as a step.
      def self.run_step(progress, done, name, &)
        done ? skip(progress, name) : step(progress, name, &)
      end

      # Runs the block as the step name, saying what it does, and then what
      # it did, from StepSummary.
      def self.step(progress, name, &) = progress.step(name, SAY.fetch(name), summary: StepSummary::SUMMARY[name], &)

      def self.skip(progress, name) = progress.skip(name, SAY.fetch(name))

      # What each step does, in plain English, for its progress line. The
      # step's ID follows it in parentheses.
      SAY = {
        "index-search" => "Checking the query plan and searching for indexes",
        "5a-5" => "Asking the LLM for index ideas the mechanical search missed",
        "5a-6" => "Asking the LLM to improve its index ideas",
        "5a-7" => "Ranking the index ideas",
        "6c" => "Applying QUAACK's own rewrite rules to the query",
        "6a" => "Asking the LLM for rewrites of the query",
        "step 7" => "Checking your own rewrites",
        "step 8" => "Searching for indexes for each rewrite",
        "index-rank" => "Ranking the index ideas",
        "rewrite-prune" => "Dropping the rewrite if its plan can't win",
        "4b" => "Setting up the arena, a second database for test rows",
        "steps 9-10" => "Testing each rewrite for wrong results",
        "rewrite-tested" => "Testing the rewrite for wrong results",
        "rewrite-test" => "Testing the rewrite on generated rows",
        "10a-10c" => "Asking the LLM for rows that could break the rewrite",
        "step 11" => "Asking the LLM for index ideas for each rewrite",
        "12a" => "Building the candidate indexes",
        "13" => "Measuring the original query",
        "13a" => "Measuring the original query with each set of indexes",
        "14" => "Measuring each rewrite",
        "14b" => "Dropping choices that lose to the original on any literal",
        "14c" => "Checking that each rewrite returns the same rows on production data",
        "14d" => "Picking the top three",
        "15" => "Writing the report"
      }.freeze

      # The entries `quaacks status` says the run's store holds.
      def self.status(transport, run_id)
        transport.call("status", args: { run: run_id }).messages.find { it["type"] == "status" }.fetch("entries")
      end

      # Whether entries say 6c and 6a ran, and step 7 too if there are
      # rewrites.
      def self.checked?(entries, rewrites) = entries["rewrite_rules_applied"] && llm_checked?(entries, rewrites)

      # Whether entries say 6a ran, and step 7 too if there are rewrites.
      def self.llm_checked?(entries, rewrites)
        entries["rewrites_generated"] && (rewrites.nil? || rewrites.empty? || entries["operator_rewrites_checked"])
      end

      # setup is nil, or the run-server flags for Setup (an empty Hash for
      # none). Given setup, the run first does steps 2 to 4a, unless the
      # store says it has had them.
      def initialize(transport:, client:, run_id:, rewrites: nil, out: nil, stderr: nil, setup: nil) # rubocop:disable Metrics/ParameterLists
        @stderr = stderr
        @out = out
        @transport = transport
        @client = client
        @run_id = run_id
        @rewrites = rewrites
        @setup = setup
      end

      def run
        entries = self.class.status(@transport, @run_id)
        setup = @setup && !Setup.done?(entries)
        @progress = progress(setup)
        Setup.run(transport: @transport, run_id: @run_id, entries:, server: @setup, progress: @progress) if setup
        STAGES.each do |stage|
          stage.run(transport: @transport, client: @client, run_id: @run_id, entries:, rewrites: @rewrites,
                    progress: @progress)
        end
        MeasurementStage.run(transport: @transport, run_id: @run_id, entries:, progress: @progress)
        ReportStage.run(transport: @transport, client: @client, run_id: @run_id, out: @out, progress: @progress)
      end

      private

      # With stderr, a Progress there, which the client is given too.
      def progress(setup)
        progress = if @stderr
                     Progress.new(io: @stderr, total: self.class.total(rewrites: @rewrites, out: @out, setup:))
                   else
                     Progress::NULL
                   end
        @client&.progress = progress
        progress
      end
    end
  end
end
