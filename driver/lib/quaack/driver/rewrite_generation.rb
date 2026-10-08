# frozen_string_literal: true

require "json"

module Quaack
  module Driver
    # The driver's half of DESIGN.md's llm-rewrites: it asks the LLM for rewrites of the
    # redacted query and has the enclave check them.
    #
    #   RewriteGeneration.new(client:, rewrite_check:).run(payload)
    #   # => Result(rewrites: [{ "sql", "transformation", "assumptions" }, ...],
    #   #           outcomes: [rewrite_outcome, ...])
    #
    # payload is what `quaacks rewrite-payload` sent: query, placeholders,
    # plan, schema, rule_rewrites (the rule-made rewrites' SQL and rule
    # names), and stats, all shape data. It goes to the LLM as it is, and the
    # prompt says not to repeat rule_rewrites.
    #
    # rewrite_check stands for `quaacks rewrite-check` over the transport.
    # It's called with the LLM's rewrites, in its order, and returns the
    # enclave's rewrite_outcome messages, one per rewrite. It's called even
    # with none, so the enclave records that llm-rewrites ran.
    class RewriteGeneration
      STEP = "llm-rewrites"
      MAX_TOKENS = 8000
      MAX = 5

      TABLE = { type: :string, description: "schema-qualified, such as public.orders" }.freeze
      COLUMNS = { type: :array, items: { type: :string } }.freeze

      def self.assumption(kind, **fields)
        { type: :object, properties: { kind: { type: :string, enum: [kind] }, **fields },
          required: [:kind, *fields.keys], additionalProperties: false }
      end

      ASSUMPTION = {
        anyOf: [
          assumption("not_null", table: TABLE, column: { type: :string }),
          assumption("unique", table: TABLE, columns: COLUMNS),
          assumption("foreign_key", table: TABLE, columns: COLUMNS, references_table: TABLE,
                                    references_columns: COLUMNS),
          assumption("check", table: TABLE, expression: { type: :string })
        ]
      }.freeze

      REWRITE = {
        type: :object,
        properties: { sql: { type: :string }, transformation: { type: :string },
                      assumptions: { type: :array, items: ASSUMPTION } },
        required: %i[sql transformation assumptions], additionalProperties: false
      }.freeze

      SCHEMA = {
        type: :object,
        properties: { rewrites: { type: :array, items: REWRITE, maxItems: MAX } },
        required: [:rewrites], additionalProperties: false
      }.freeze

      SYSTEM = <<~PROMPT
        You're rewriting one slow PostgreSQL query so it runs faster and returns exactly the same rows. You have no database connection. The payload holds only shapes: the query with $n placeholders for its literals, each placeholder's type and shape with estimated and actual row counts, the plan, the schema, per-column statistics, and rule_rewrites.

        rule_rewrites are the rewrites QUAACK's own rules already made, each with its SQL and the names of the rules applied. They're already covered, so don't repeat them. Propose only rewrites that aren't on that list.

        Propose up to five rewrites. Each must be one SELECT that returns the same columns, of the same types, in the same order, for every possible data set the schema allows. Use the original's $n placeholders where it uses literals, never a new $n. Only use tables the original uses, schema-qualified, never views. Don't call volatile functions.

        For each rewrite, state the transformation you applied, and every assumption it relies on. Only these kinds of assumption are allowed, and a rewrite relying on anything else will be rejected:
        - not_null: a column is NOT NULL.
        - unique: a set of columns is unique.
        - foreign_key: columns reference another table's columns.
        - check: a CHECK constraint with exactly this expression.
        Each assumption is checked against the catalog, and a rewrite with an unmet one is rejected.

        Answer with JSON: {"rewrites": [{"sql": "...", "transformation": "...", "assumptions": [...]}]}.
      PROMPT

      # provider is the entry that wrote the rewrites, for the provenance
      # record.
      Result = Data.define(:rewrites, :outcomes, :provider) do
        def initialize(rewrites:, outcomes:, provider: nil) = super
      end

      # The rewrite_check callable for a run, over transport.
      def self.rewrite_check(transport, run_id:)
        lambda do |rewrites|
          transport.call("rewrite-check", args: { run: run_id }, input: { "rewrites" => rewrites })
                   .messages.select { it["type"] == "rewrite_outcome" }
        end
      end

      def initialize(client:, rewrite_check:)
        @client = client
        @rewrite_check = rewrite_check
      end

      def run(payload)
        messages = [{ role: :user, content: "The payload:\n\n```json\n#{JSON.generate(payload)}\n```" }]
        session = @client.session
        rewrites = session.ask(step: STEP, system: SYSTEM, messages:, max_tokens: MAX_TOKENS, schema: SCHEMA)
                          .fetch("rewrites")
        Result.new(rewrites:, outcomes: @rewrite_check.call(rewrites), provider: session.provider)
      end
    end
  end
end
