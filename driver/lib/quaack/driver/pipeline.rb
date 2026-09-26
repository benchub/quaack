# frozen_string_literal: true

require_relative "generator_three"
require_relative "refinement_round"
require_relative "rewrite_generation"

module Quaack
  module Driver
    # What `quaack run --run ID` drives: every remaining step of a run, in
    # order, over the transport to the run's jump server.
    #
    #   Pipeline.new(transport:, client:, run_id:).run
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
      # 4. index-rank: 5a-7.
      module IndexStage
        SEARCH = "original"

        module_function

        def run(transport:, client:, run_id:, entries:)
          args = { run: run_id, search: SEARCH }
          transport.call("index-search", args:) unless entries["index_search_#{SEARCH}"]
          llm(transport, client, run_id, SEARCH, generated: entries["index_generated_#{SEARCH}"],
                                                 ranked: entries["index_ranking_#{SEARCH}"])
        end

        # 5a-5 unless generated, 5a-6, and 5a-7 unless ranked, for search.
        def llm(transport, client, run_id, search, generated:, ranked:)
          args = { run: run_id, search: }
          payload = transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" }
          generate(transport, client, run_id, search, payload) unless generated
          refine(transport, client, run_id, search, payload)
          transport.call("index-rank", args:) unless ranked
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

      # README 6a and step 8, after step 5:
      # 1. 6a: RewriteGeneration on rewrite-payload, unless the store says
      #    it ran (rewrites_generated). Its rewrite-check stores the
      #    survivors as rewrite_<n>, and status is asked again for them.
      # 2. Step 8, for each stored rewrite_<n> in order: index-search,
      #    index-rank, and rewrite-prune, each skipped when its output is
      #    stored.
      module RewriteStage
        STEP8 = { "index-search" => "index_search_rewrite_", "index-rank" => "index_ranking_rewrite_",
                  "rewrite-prune" => "rewrite_pruned_" }.freeze

        module_function

        def run(transport:, client:, run_id:, entries:)
          unless entries["rewrites_generated"]
            generate(transport, client, run_id)
            entries = Pipeline.status(transport, run_id)
          end
          (1..).lazy.take_while { entries["rewrite_#{it}"] }.each { step8(transport, run_id, entries, it) }
        end

        def generate(transport, client, run_id)
          payload = transport.call("rewrite-payload", args: { run: run_id }).messages
                             .find { it["type"] == "rewrite_payload" }
          RewriteGeneration.new(client:, rewrite_check: RewriteGeneration.rewrite_check(transport, run_id:))
                           .run(payload)
        end

        def step8(transport, run_id, entries, number)
          STEP8.each do |subcommand, output|
            next if entries["#{output}#{number}"]

            transport.call(subcommand, args: { run: run_id, search: "rewrite_#{number}" })
          end
        end
      end

      # README step 11, after step 8: status is asked again, then IndexStage's
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
                           generated: entries["index_generated_rewrite_#{n}"],
                           ranked: entries["index_llm_ranked_rewrite_#{n}"])
          end
        end
      end

      STAGES = [IndexStage, RewriteStage, RewriteIndexStage].freeze

      # The entries `quaacks status` says the run's store holds.
      def self.status(transport, run_id)
        transport.call("status", args: { run: run_id }).messages.find { it["type"] == "status" }.fetch("entries")
      end

      def initialize(transport:, client:, run_id:)
        @transport = transport
        @client = client
        @run_id = run_id
      end

      def run
        entries = self.class.status(@transport, @run_id)
        STAGES.each { it.run(transport: @transport, client: @client, run_id: @run_id, entries:) }
        nil
      end
    end
  end
end
