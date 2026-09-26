# frozen_string_literal: true

require_relative "generator_three"
require_relative "refinement_round"

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
          payload = transport.call("index-payload", args:).messages.find { it["type"] == "index_payload" }
          generate(transport, client, run_id, payload) unless entries["index_generated_#{SEARCH}"]
          refine(transport, client, run_id, payload)
          transport.call("index-rank", args:) unless entries["index_ranking_#{SEARCH}"]
        end

        def generate(transport, client, run_id, payload)
          index_test = GeneratorThree.index_test(transport, run_id:, search: SEARCH)
          result = GeneratorThree.new(client:, index_test:).run(payload)
          index_test.call([]) if result.rounds.empty?
        end

        def refine(transport, client, run_id, payload)
          index_feedback = RefinementRound.index_feedback(transport, run_id:, search: SEARCH)
          index_test = RefinementRound.index_test(transport, run_id:, search: SEARCH)
          RefinementRound.new(client:, index_feedback:, index_test:).run(payload)
        end
      end

      STAGES = [IndexStage].freeze

      def initialize(transport:, client:, run_id:)
        @transport = transport
        @client = client
        @run_id = run_id
      end

      def run
        entries = @transport.call("status", args: { run: @run_id }).messages
                            .find { it["type"] == "status" }.fetch("entries")
        STAGES.each { it.run(transport: @transport, client: @client, run_id: @run_id, entries:) }
        nil
      end
    end
  end
end
