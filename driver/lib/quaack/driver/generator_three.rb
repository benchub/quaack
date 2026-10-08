# frozen_string_literal: true

require "json"
require_relative "llm/router"

module Quaack
  module Driver
    # The driver's half of DESIGN.md's llm-index-ideas: it asks the LLM for index
    # candidates, has the enclave filter and test them, and runs the one
    # replacement round.
    #
    #   GeneratorThree.new(client:, index_test:).run(payload)
    #   # => Result(rounds: [Round(ddls: [...], outcomes: [...]), ...])
    #
    # payload is the shape-only payload the enclave sent (`quaacks
    # index-payload`), for the original query or for one rewrite: query,
    # placeholders, plan, schema, mechanical_results, and stats. It goes to
    # the LLM as it is.
    #
    # index_test stands for `quaacks index-test` over the transport. It's
    # called with each round's DDL, an Array of Strings in the LLM's order,
    # and returns the enclave's index_outcome messages for them, one per
    # DDL, each with its 1-based index, outcome (accepted, set_aside, or
    # dropped), rule, covered_by, and partial_constant_only.
    #
    # If any candidate is dropped, the LLM hears which ones and why, and is
    # asked for as many replacements, once. Whatever survives either round
    # goes on. A round with no DDL isn't sent to the enclave.
    #
    # client is the LLM::Router. The first ask and its replacement round
    # are one unit, so both go to one provider, in one session. A
    # replacement ask that fails with a rule that fails over is skipped, and
    # the first round's ideas go on alone.
    #
    # A fan-out step (DESIGN.md, "Several LLM providers": Routing, Limits)
    # runs that unit once per healthy provider, one after another: each
    # round's union goes to index-test in one call, interleaved, with exact
    # repeats of the DDL dropped, so the cap of five per call holds, and
    # each branch asks for replacements for its own dropped ideas.
    #
    # Trust boundary. The prompts carry only the payload, which is shape
    # data, the LLM's own DDL, and the enclave's shape-only outcomes.
    class GeneratorThree
      STEP = "llm-index-ideas"
      # The step its asks count under when it searches for a rewrite.
      REWRITE_STEP = "rewrite-llm-index-ideas"
      MAX_TOKENS = 4000

      SCHEMA = {
        type: :object,
        properties: { indexes: { type: :array, items: { type: :string } } },
        required: [:indexes],
        additionalProperties: false
      }.freeze

      SYSTEM = <<~PROMPT
        You're tuning indexes for one slow PostgreSQL query. You have no database connection. The payload holds only shapes: the query with $n placeholders for its literals, each placeholder's type and shape with estimated and actual row counts, the plan, the schema with its existing indexes, per-column statistics, and mechanical_results.

        mechanical_results are the indexes two mechanical generators already proposed, each tested with HypoPG: whether the planner used it, its cost for each literal, its estimated size, and its plan. Those and the existing indexes are already covered, so propose only indexes on neither list. The mechanical generators handle the obvious btree keys well. Your job is to find what they miss. Use mechanical_results to see what the planner used, how much each index helped, and what's still expensive.

        Propose up to five indexes, of these kinds:
        - Partial indexes. Only write a predicate on a low-cardinality column, one whose statistics list its values in low_card_values. Any other predicate gets the candidate refused.
        - Expression indexes that match an expression in the query exactly.
        - BRIN indexes, where a column's correlation is close to 1 or -1.
        - Operator class choices, such as text_pattern_ops for a prefix LIKE, or trigram GIN (gin_trgm_ops) for an infix LIKE.

        Write each one as a single CREATE INDEX statement. Always schema-qualify the table name, such as public.orders: an unqualified table name gets the candidate refused, and it counts against you. Don't use CONCURRENTLY, UNIQUE, NULLS NOT DISTINCT, TABLESPACE, ON ONLY, or WITH (...) storage options, and don't use $n parameters in an index. Each of those gets the candidate refused too.

        Answer with JSON: {"indexes": ["CREATE INDEX ...", ...]}.
      PROMPT

      # What each drop rule means, for the replacement ask. A rule not
      # listed here is named as it is.
      REASONS = {
        "unqualified_table" => "its table name isn't schema-qualified",
        "unknown_relation" => "its table isn't one the query uses",
        "duplicate" => "it repeats a candidate already proposed, such as one in mechanical_results",
        "partial_not_low_cardinality" => "its predicate uses a column that isn't low-cardinality, " \
                                         "or a constant not compared directly with one",
        "unrepresentable" => "QUAACK can't represent it, such as an operator class with parameters",
        "storage_options" => "it uses WITH (...) storage options"
      }.freeze

      # round is "first" or "replacement", and entries the entry that wrote
      # each statement, by position, for the provenance record.
      Round = Data.define(:ddls, :outcomes, :round, :entries) do
        def initialize(ddls:, outcomes:, round: "first", entries: []) = super
      end
      # providers is each entry that answered a branch, in order, and
      # skipped each entry whose replacement round was skipped, with the
      # rule, for the provenance record.
      Result = Data.define(:rounds, :providers, :skipped) do
        def initialize(rounds:, providers: [], skipped: {}) = super
      end

      # The index_test callable for run's search, over transport: it sends
      # `quaacks index-test --run RUN --search SEARCH` with {"ddls": [...]}
      # on stdin, and returns the index_outcome messages.
      def self.index_test(transport, run_id:, search: "original")
        lambda do |ddls|
          transport.call("index-test", args: { run: run_id, search: }, input: { "ddls" => ddls })
                   .messages.select { it["type"] == "index_outcome" }
        end
      end

      # step is the LLM step its asks count under: STEP for the original
      # query, REWRITE_STEP for a rewrite.
      def initialize(client:, index_test:, step: STEP)
        @client = client
        @index_test = index_test
        @step = step
      end

      # Each branch (one, unless the step fans out) asks for ideas; their
      # union is tested in one call; each branch with dropped ideas asks for
      # its own replacements, in its own conversation; and the replacements'
      # union is tested in one more call.
      def run(payload)
        messages = [{ role: :user, content: "The payload:\n\n```json\n#{JSON.generate(payload)}\n```" }]
        branches = @client.branches(**ask(messages, "Asking the LLM for index ideas"))
                          .map { |session, reply| [session, reply.fetch("indexes")] }
        rounds, union = test([], branches, "first")
        lists, skipped = replacements(branches, messages, rounds.last, union)
        Result.new(rounds: test(rounds, lists, "replacement").first, providers: branches.map { it.first.provider },
                   skipped:)
      end

      private

      # Each branch's replacement DDL, as [session, ddls], for the branches
      # whose ideas round dropped, and each entry whose replacement round was
      # skipped, with the rule.
      def replacements(branches, messages, round, union)
        skipped = {}
        lists = branches.filter_map do |session, first|
          dropped = dropped(round, union, session)
          next if dropped.empty?

          [session, replace(session, messages + [{ role: :assistant, content: JSON.generate("indexes" => first) },
                                                 { role: :user, content: replacement_ask(dropped) }], skipped)]
        end
        [lists, skipped]
      end

      # The replacement round's DDL, or none when its ask failed with a rule
      # that fails over, adding the entry and rule to skipped: the branch
      # keeps its first round's ideas and goes on (DESIGN.md, "Several LLM
      # providers": Routing).
      def replace(session, messages, skipped)
        session.ask(**ask(messages, "Asking the LLM again, for replacements for the dropped ideas")).fetch("indexes")
      rescue LLM::Router::LaterError => e
        @client.going_on(e, "going on without replacement ideas")
        skipped[e.provider] = e.rule
        []
      end

      # purpose is what progress hears the ask is for.
      def ask(messages, purpose)
        { step: @step, system: SYSTEM, messages:, max_tokens: MAX_TOKENS, schema: SCHEMA, purpose: }
      end

      # rounds with lists' union, each [session, ddls], tested as round, and
      # the union, as [[session, ddl], ...]. A round with no DDL isn't sent.
      def test(rounds, lists, round)
        union = LLM::FanOut.union(lists, &:itself)
        return [rounds, union] if union.empty?

        ddls = union.map(&:last)
        [rounds + [Round.new(ddls:, outcomes: @index_test.call(ddls), round:,
                             entries: union.map { it.first.provider })], union]
      end

      # The DDL and outcome of each candidate session wrote that round
      # dropped, except those past the first five, which the enclave never
      # checked. So at most five replacements are asked for in all.
      def dropped(round, union, session)
        replaceable = round ? round.outcomes.select { it["outcome"] == "dropped" && it["rule"] != "too_many" } : []
        replaceable.filter_map do |outcome|
          from, ddl = union.fetch(outcome["index"] - 1)
          [ddl, outcome] if from.equal?(session)
        end
      end

      def replacement_ask(dropped)
        lines = dropped.each_with_index.map { |(ddl, outcome), i| "#{i + 1}. `#{ddl}`: #{reason(outcome)}" }
        "These candidates were dropped:\n\n#{lines.join("\n")}\n\n" \
          "Propose up to #{dropped.size} replacements, following the same rules. " \
          "Answer with JSON: {\"indexes\": [...]}."
      end

      def reason(outcome)
        return "already covered by `#{outcome["covered_by"]}`" if outcome["rule"] == "covered_by_existing"

        REASONS.fetch(outcome["rule"]) { "refused (#{outcome["rule"]})" }
      end
    end
  end
end
