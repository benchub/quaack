# frozen_string_literal: true

require_relative "counterexamples"
require_relative "enclave_error"
require_relative "generator_three"
require_relative "operator_candidates"
require_relative "progress"
require_relative "refinement_round"
require_relative "report"
require_relative "rewrite_generation"
require_relative "rewrite_names"
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
    # rewrites are the operator's own (DESIGN.md's operator-rewrites), from `--rewrites`.
    # setup, the run-server flags as a Hash, has it do setup first
    # (Setup), unless the store says the run has had them; nil leaves them
    # to the caller.
    # client is the LLM::Router every LLM step asks through, or nil for a
    # run with no LLM step left.
    # With stderr, a Progress there shows each step as it runs or is skipped,
    # and the client is given it too, so each LLM ask and retry shows under it.
    #
    # It resumes. It first asks `quaacks status` which step outputs the
    # store holds, and skips the steps whose outputs are there. Each
    # orchestration task adds its stage to STAGES, and the entries it
    # checks to the enclave's Status::ENTRIES. An EnclaveError, such as the
    # plan gate's abort, stops the run where it is.
    class Pipeline
      # DESIGN.md index-search, for the original query:
      # 1. index-search: the plan gate, index-from-query and index-from-plan filtered by index-dedupe, and
      #    index-test on the mechanical candidates.
      # 2. llm-index-ideas: GeneratorThree, on index-payload. If the LLM proposes
      #    nothing, an index-test with no DDL records that llm-index-ideas ran.
      # 3. llm-index-refine: RefinementRound, which index-feedback tells whether to run.
      #    index-payload is fetched only when llm-index-ideas or llm-index-refine asks the LLM.
      # 4. index-rank: index-rank.
      module IndexStage
        SEARCH = "original"
        # The LLM steps' names, and index-rank's, for the original query and
        # for a rewrite's search in rewrite-index-ideas.
        NAMES = %w[llm-index-ideas llm-index-refine index-rank].freeze
        REWRITE_NAMES = %w[rewrite-llm-index-ideas rewrite-llm-index-refine rewrite-index-rerank].freeze

        module_function

        def run(transport:, client:, run_id:, entries:, progress: Progress::NULL, **) # rubocop:disable Metrics/ParameterLists
          args = { run: run_id, search: SEARCH }
          Pipeline.run_step(progress, entries["index_search_#{SEARCH}"], "index-search") do
            transport.call("index-search", args:)
          end
          llm(transport, client, run_id, SEARCH, { generated: entries["index_generated_#{SEARCH}"],
                                                   ranked: entries["index_ranking_#{SEARCH}"] }, progress)
        end

        # llm-index-ideas unless done[:generated], llm-index-refine, and index-rank unless done[:ranked],
        # for search. Returns llm-index-refine's result, from refine.
        def llm(transport, client, run_id, search, done, progress = Progress::NULL) # rubocop:disable Metrics/ParameterLists
          args = { run: run_id, search: }
          payload = payload(transport, args, progress)
          names = search == SEARCH ? NAMES : REWRITE_NAMES
          Pipeline.run_step(progress, done[:generated], names[0]) do
            generate(transport, client, run_id, search, payload.call(names[0]), progress)
          end
          refined = Pipeline.step(progress, names[1]) { refine(transport, client, run_id, search, payload, progress) }
          Pipeline.run_step(progress, done[:ranked], names[2]) { transport.call("index-rank", args:) }
          refined
        end

        # index-payload's payload, fetched on the first call only, with a
        # note under the step it's called with.
        def payload(transport, args, progress)
          fetched = nil
          shape = "Reading the #{args[:search] == SEARCH ? "query" : "rewrite"}'s shape for the LLM"
          lambda do |step|
            fetched ||= begin
              progress.step_note(step, shape)
              transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" }
            end
          end
        end

        def generate(transport, client, run_id, search, payload, progress) # rubocop:disable Metrics/ParameterLists
          step = search == SEARCH ? GeneratorThree::STEP : GeneratorThree::REWRITE_STEP
          test = GeneratorThree.index_test(transport, run_id:, search:)
          index_test = Pipeline.noting(progress, step, "Testing the LLM's index ideas", test)
          result = GeneratorThree.new(client:, index_test:, step:).run(payload)
          none = Pipeline.noting(progress, step, "Recording that the LLM gave no index ideas", test)
          none.call([]) if result.rounds.empty?
          result
        end

        # RefinementRound's result, or, when it skips the round, :refined if
        # the round already ran, else nil.
        def refine(transport, client, run_id, search, payload, progress) # rubocop:disable Metrics/ParameterLists
          feedback = nil
          step = search == SEARCH ? RefinementRound::STEP : RefinementRound::REWRITE_STEP
          fetch = Pipeline.noting(progress, step, "Reading how the LLM's index ideas did",
                                  RefinementRound.index_feedback(transport, run_id:, search:))
          index_test = Pipeline.noting(progress, step, "Testing the LLM's revised index ideas",
                                       RefinementRound.index_test(transport, run_id:, search:))
          result = RefinementRound.new(client:, index_feedback: -> { feedback = fetch.call }, index_test:, step:)
                                  .run(-> { payload.call(step) })
          result || (:refined if feedback["refined"])
        end
      end

      # DESIGN.md's rewrite-rules, llm-rewrites, operator-rewrites, and plan-pruning, after index-search:
      # 1. rewrite-rules: rewrite-rules, the mechanical rules, unless the store says
      #    they were applied (rewrite_rules_applied). It needs no LLM and
      #    no payload, and the enclave stores its survivors as rewrite_<n>.
      #    llm-rewrites: RewriteGeneration on rewrite-payload, unless the store says
      #    it ran (rewrites_generated). Its rewrite-check stores the
      #    survivors after rewrite-rules'.
      #    operator-rewrites: OperatorCandidates on the same payload, for the operator's
      #    rewrites, unless there are none or the store says it ran
      #    (operator_rewrites_checked). Its survivors are stored after llm-rewrites'.
      #    If any of the three ran, status is asked again for them. The
      #    payload is fetched only if llm-rewrites or operator-rewrites has to run.
      # 2. plan-pruning, for each stored rewrite_<n> in order: index-search,
      #    index-rank, and rewrite-prune, each skipped when its output is
      #    stored.
      module RewriteStage
        # Each plan-pruning sub-step's name, its subcommand, and the entry it
        # stores, less the rewrite's number.
        PRUNING = { "rewrite-index-search" => %w[index-search index_search_rewrite_],
                    "rewrite-index-rank" => %w[index-rank index_ranking_rewrite_],
                    "rewrite-prune" => %w[rewrite-prune rewrite_pruned_] }.freeze

        # operator-rewrites' note for its rewrite-check.
        OPERATOR_CHECK = "Checking your rewrites against what the LLM says they assume"

        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          entries = generated(transport, client, run_id, entries, rewrites, progress)
          Pipeline.step(progress, "plan-pruning") do
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.map do |number|
              prune(transport, run_id, entries, number, Pipeline.within(progress, run_id, number))
            end.to_a
          end
        end

        # entries, asked again if rewrite-rules, llm-rewrites, or operator-rewrites still had to run, after
        # running them; else the skips are printed.
        def generated(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          return skipped(entries, rewrites, progress) if Pipeline.checked?(entries, rewrites)

          Pipeline.run_step(progress, entries["rewrite_rules_applied"], "rewrite-rules") do
            transport.call("rewrite-rules", args: { run: run_id })
          end
          if Pipeline.llm_checked?(entries, rewrites)
            skipped(entries, rewrites, progress, from: 1)
          else
            generate(transport, client, run_id, entries, rewrites, progress)
          end
          Pipeline.status(transport, run_id)
        end

        # Prints the skips of rewrite-rules, llm-rewrites, and operator-rewrites, or of those from the
        # given one on, and returns entries.
        def skipped(entries, rewrites, progress, from: 0)
          names = ["rewrite-rules", "llm-rewrites", ("operator-rewrites" if rewrites)].compact
          names.drop(from).each { Pipeline.skip(progress, it) }
          entries
        end

        def generate(transport, client, run_id, entries, rewrites, progress) # rubocop:disable Metrics/ParameterLists
          payload = transport.call("rewrite-payload", args: { run: run_id }).messages
                             .find { it["type"] == "rewrite_payload" }
          Pipeline.run_step(progress, entries["rewrites_generated"], "llm-rewrites") do
            rewrite_check = Pipeline.noting(progress, RewriteGeneration::STEP, "Checking the LLM's rewrites",
                                            RewriteGeneration.rewrite_check(transport, run_id:))
            RewriteGeneration.new(client:, rewrite_check:).run(payload)
          end
          operator(transport, client, run_id, entries, rewrites, payload, progress) unless rewrites.nil?
        end

        # operator-rewrites, unless the store says it ran.
        def operator(transport, client, run_id, entries, rewrites, payload, progress) # rubocop:disable Metrics/ParameterLists
          Pipeline.run_step(progress, entries["operator_rewrites_checked"], "operator-rewrites") do
            raise OperatorCandidates::Error, "no_rewrite_payload" unless payload

            rewrite_check = Pipeline.noting(progress, OperatorCandidates::STEP, OPERATOR_CHECK,
                                            OperatorCandidates.rewrite_check(transport, run_id:))
            OperatorCandidates.new(client:, rewrite_check:).run(payload, rewrites)
          end
        end

        # Whether any of plan-pruning's sub-steps ran for the rewrite, rather than
        # all being stored already.
        def prune(transport, run_id, entries, number, progress)
          ran = PRUNING.values.any? { |(_, output)| !entries["#{output}#{number}"] }
          PRUNING.each do |name, (subcommand, output)|
            Pipeline.run_step(progress, entries["#{output}#{number}"], name) do
              transport.call(subcommand, args: { run: run_id, search: "rewrite_#{number}" })
            end
          end
          ran
        end
      end

      # DESIGN.md rewrite-test and counterexamples, after plan-pruning. If rewrite-rules, llm-rewrites, or
      # operator-rewrites ran in this run, it asks status again, for the rewrites it stored. For each stored
      # rewrite_<n> not yet decided (rewrite_survived_<n>): rewrite-test, unless it's stored (rewrite_tested_<n>),
      # and, if the rewrite passed, the three llm-counterexamples to counterexample-rollback rounds (Counterexamples)
      # on counterexample-payload, each round a numbered counterexample-round. The enclave records survival. It
      # returns whether each rewrite it tested passed both steps.
      module CounterexampleStage
        module_function

        def run(transport:, client:, run_id:, entries:, rewrites: nil, progress: Progress::NULL) # rubocop:disable Metrics/ParameterLists
          Pipeline.step(progress, "rewrite-correctness") do
            entries = Pipeline.status(transport, run_id) unless Pipeline.checked?(entries, rewrites)
            (1..).lazy.take_while { entries["rewrite_#{it}"] }.map do |number|
              undecided(transport, client, run_id, entries, number, Pipeline.within(progress, run_id, number))
            end.to_a.compact
          end
        end

        # Whether rewrite number passed, or nil, printing the skip, if the
        # store says it's decided.
        def undecided(transport, client, run_id, entries, number, progress) # rubocop:disable Metrics/ParameterLists
          if entries["rewrite_survived_#{number}"]
            progress.skip("rewrite-correctness", Pipeline::SAY.fetch("rewrite-tested"))
            return
          end

          rewrite(transport, client, { run: run_id, search: "rewrite_#{number}" },
                  entries["rewrite_tested_#{number}"], progress)
        end

        # Whether the rewrite passed rewrite-test and counterexamples.
        def rewrite(transport, client, args, tested, progress)
          passed = Pipeline.run_step(progress, tested, "rewrite-test") do
            message(transport.call("rewrite-test", args:), "rewrite_test")["passed"]
          end
          return false unless tested || passed

          Pipeline.step(progress, "counterexamples") { survives_counterexamples?(transport, client, args, progress) }
        end

        # Whether no round of counterexamples disproved the rewrite. Each
        # enclave call gets a note of its own, so the LLM's line isn't left
        # open over it.
        def survives_counterexamples?(transport, client, args, progress)
          progress.step_note("counterexamples", "Reading the rewrite's shape for the LLM")
          payload = message(transport.call("counterexample-payload", args:), "counterexample_payload")
          rounds = Pipeline.noting(progress, "counterexamples", "Loading the LLM's rows and comparing results",
                                   compare(transport, args))
          label = RewriteNames.label(args[:run], args[:search])
          !Counterexamples.new(client:, label:).run(payload, compare: rounds).disproved
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

      # DESIGN.md's rewrite-index-ideas, after rewrite-test and counterexamples: status is asked again, then
      # IndexStage's llm-index-ideas, llm-index-refine, and index-rank run for each stored rewrite_<n> it marks
      # rewrite_index_ideas_<n>: survived rewrite-test and counterexamples, and not pruned in plan-pruning.
      # llm-index-ideas is skipped once index_generated_rewrite_<n> is stored, and the second index-rank once
      # index_llm_ranked_rewrite_<n> is.
      module RewriteIndexStage
        module_function

        def run(transport:, client:, run_id:, progress: Progress::NULL, **)
          Pipeline.step(progress, "rewrite-index-ideas") do
            entries = Pipeline.status(transport, run_id)
            numbers = (1..).lazy.take_while { entries["rewrite_#{it}"] }
            numbers.select { entries["rewrite_index_ideas_#{it}"] }.map do |n|
              asked?(transport, client, run_id, entries, n, Pipeline.within(progress, run_id, n))
            end.to_a
          end
        end

        # Runs IndexStage.llm for rewrite n, and returns whether any of llm-index-ideas
        # to index-rank did anything, rather than finding it already done.
        def asked?(transport, client, run_id, entries, number, progress) # rubocop:disable Metrics/ParameterLists
          done = { generated: entries["index_generated_rewrite_#{number}"],
                   ranked: entries["index_llm_ranked_rewrite_#{number}"] }
          refined = IndexStage.llm(transport, client, run_id, "rewrite_#{number}", done, progress)
          !done[:generated] || !done[:ranked] || refined.is_a?(RefinementRound::Result)
        end
      end

      # DESIGN.md's arena-setup, before rewrite-test and counterexamples, which refuse without the
      # arena: arena-setup, unless the store holds arena_setup.
      module ArenaStage
        module_function

        def run(transport:, run_id:, entries:, progress: Progress::NULL, **)
          Pipeline.run_step(progress, entries["arena_setup"], "arena-setup") do
            transport.call("arena-setup", args: { run: run_id })
          end
        end
      end

      # DESIGN.md index-build to selection, after rewrite-index-ideas, in order: each step whose output
      # isn't stored. Earlier stages don't write these outputs, so the
      # entries from the start of the run still hold. It returns them with
      # the steps it ran marked done, for ReportStage.
      module MeasurementStage
        STEPS = { "index-build" => "index_build", "baseline" => "baseline", "index-baseline" => "index_baseline",
                  "candidate-runs" => "candidate_runs", "minimax" => "minimax",
                  "result-comparison" => "result_comparison", "selection" => "selection" }.freeze

        module_function

        def run(transport:, run_id:, entries:, progress: Progress::NULL, **)
          STEPS.each_with_object(entries.dup) do |(subcommand, output), done|
            Pipeline.run_step(progress, done[output], subcommand) do
              call(transport, subcommand, run_id, progress).tap { done[output] = true }
            end
          end
        end

        # Calls the step and returns, for index-build, how many indexes it
        # built.
        def call(transport, subcommand, run_id, progress)
          return build_indexes(transport, run_id, progress) if subcommand == "index-build"

          transport.call(subcommand, args: { run: run_id })
        end

        # Builds each index in its own `index-build --index n` call, so each
        # gets its own timeout and a rerun picks up after the last one built
        # (the enclave skips any already built). The first call's progress
        # line gives the total; none means there's nothing to build. Then
        # the plain call finds them all built, hides them, and writes
        # index_build. Its progress lines repeat the ones already printed,
        # so they're not printed again.
        def build_indexes(transport, run_id, progress)
          total = build_index(transport, run_id, 1, progress)
          (2..total).each { build_index(transport, run_id, it, progress) }
          transport.call("index-build", args: { run: run_id })
          total
        end

        # Prints index number's progress line and returns its total, or 0
        # if there's no such index. It takes the total before it prints, since
        # the transport rescues a failed print, and the rest must still be
        # built.
        def build_index(transport, run_id, number, progress)
          total = 0
          transport.call("index-build", args: { run: run_id, index: number.to_s }) do |message|
            total = message["total"].to_i
            progress.note(building(message))
          end
          total
        end

        # An index-build progress message as its line: which index is starting, and
        # its DDL, which the enclave sends only through
        # CandidateDdlRedaction, when there is one.
        def building(message)
          line = "Building index #{message["index"].to_i}/#{message["total"].to_i}"
          message["ddl"].is_a?(String) ? "#{line}: #{message["ddl"]}" : line
        end
      end

      # DESIGN.md's report, last: once the store holds selection, the
      # report message from report-payload rendered as HTML to out.
      # MeasurementStage has stored selection by the time it runs. It writes
      # nothing, and asks for nothing, when there's no out. Rerunning
      # renders it again.
      module ReportStage
        module_function

        def run(transport:, run_id:, out:, client: nil, progress: Progress::NULL, **) # rubocop:disable Metrics/ParameterLists
          return unless out

          Pipeline.step(progress, "report") do
            payload = CounterexampleStage.message(transport.call("report-payload", args: { run: run_id }), "report")
            Report.write(payload, run_id:, path: out, llm_calls: client ? client.burndown.llm_calls : {})
          end
        end
      end

      STAGES = [IndexStage, RewriteStage, ArenaStage, CounterexampleStage, RewriteIndexStage].freeze

      # The number of steps a run counts in its progress: 17, plus operator-rewrites
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
      def self.step(progress, name, &)
        progress.step(name, SAY.fetch(name), summary: StepSummary::SUMMARY[name],
                                             informative: StepSummary::INFORMATIVE.include?(name), &)
      end

      def self.skip(progress, name) = progress.skip(name, SAY.fetch(name))

      # call, an enclave call that runs under an LLM step's lines, such as
      # its index-test, with a note of its own under the step name first
      # each time, so the LLM's line isn't left open over it.
      def self.noting(progress, name, text, call)
        lambda do |*args, **options|
          progress.step_note(name, text)
          call.call(*args, **options)
        end
      end

      # Progress for rewrite number's sub-steps, under its name, such as
      # "Rewrite Silver Fox" (RewriteNames).
      def self.within(progress, run_id, number) = progress.within(RewriteNames.label(run_id, "rewrite_#{number}"))

      # What each step does, in plain English, for its progress line. The
      # step's ID follows it in parentheses.
      SAY = {
        "index-search" => "Checking the query plan and searching for indexes",
        "llm-index-ideas" => "Asking the LLM for index ideas the mechanical search missed",
        "llm-index-refine" => "Asking the LLM to improve its index ideas",
        "index-rank" => "Ranking the index ideas",
        "rewrite-rules" => "Applying QUAACK's own rewrite rules to the query",
        "llm-rewrites" => "Asking the LLM for rewrites of the query",
        "operator-rewrites" => "Checking your own rewrites",
        "plan-pruning" => "Searching for indexes for each rewrite",
        "rewrite-index-search" => "Checking the query plan and searching for indexes",
        "rewrite-index-rank" => "Ranking the index ideas",
        "rewrite-prune" => "Dropping the rewrite if its plan can't win",
        "arena-setup" => "Setting up the arena, a second database for test rows",
        "rewrite-correctness" => "Testing each rewrite for wrong results",
        "rewrite-tested" => "Testing the rewrite for wrong results",
        "rewrite-test" => "Testing the rewrite on generated rows",
        "counterexamples" => "Asking the LLM for rows that could break the rewrite",
        "rewrite-index-ideas" => "Asking the LLM for index ideas for each rewrite",
        "rewrite-llm-index-ideas" => "Asking the LLM for index ideas the mechanical search missed",
        "rewrite-llm-index-refine" => "Asking the LLM to improve its index ideas",
        "rewrite-index-rerank" => "Ranking the index ideas",
        "index-build" => "Building the candidate indexes",
        "baseline" => "Measuring the original query",
        "index-baseline" => "Measuring the original query with each set of indexes",
        "candidate-runs" => "Measuring each rewrite",
        "minimax" => "Dropping choices that lose to the original on any literal",
        "result-comparison" => "Checking that each rewrite returns the same rows on production data",
        "selection" => "Picking the top three",
        "report" => "Writing the report"
      }.freeze

      # The entries `quaacks status` says the run's store holds.
      def self.status(transport, run_id)
        transport.call("status", args: { run: run_id }).messages.find { it["type"] == "status" }.fetch("entries")
      end

      # Whether entries say rewrite-rules and llm-rewrites ran, and operator-rewrites too if there are
      # rewrites.
      def self.checked?(entries, rewrites) = entries["rewrite_rules_applied"] && llm_checked?(entries, rewrites)

      # Whether entries say llm-rewrites ran, and operator-rewrites too if there are rewrites.
      def self.llm_checked?(entries, rewrites)
        entries["rewrites_generated"] && (rewrites.nil? || rewrites.empty? || entries["operator_rewrites_checked"])
      end

      # setup is nil, or the run-server flags for Setup (an empty Hash for
      # none). Given setup, the run first does setup, unless the
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
