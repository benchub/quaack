# frozen_string_literal: true

require "json"
require "pg_query"
require_relative "rewrite_generation"

module Quaack
  module Driver
    # DESIGN.md's operator-rewrites: an operator's own rewrites, from a file on the laptop
    # (`--rewrites <file>`), written with the redact placeholders in place of
    # literals, one per ;-terminated statement.
    #
    #   sqls = OperatorCandidates.from_file(path)
    #   OperatorCandidates.new(client:, rewrite_check:).run(payload, sqls)
    #   # => Result(rewrites: [{ "sql", "transformation", "assumptions" }, ...], outcomes: [...])
    #
    # The LLM compares them with the redacted original (payload is what
    # `quaacks rewrite-payload` sent) and infers each one's transformation
    # and assumptions, in RewriteGeneration's vocabulary. The operator's SQL
    # goes to the enclave as written, never the LLM's, through the same
    # `quaacks rewrite-check`, with "inferred": true, so an unmet assumption
    # only adds a warning.
    class OperatorCandidates
      class Error < StandardError; end

      STEP = "operator-rewrites"
      MAX_TOKENS = 8000

      INFERRED = {
        type: :object,
        properties: { transformation: { type: :string },
                      assumptions: { type: :array, items: RewriteGeneration::ASSUMPTION } },
        required: %i[transformation assumptions], additionalProperties: false
      }.freeze

      SCHEMA = {
        type: :object,
        properties: { rewrites: { type: :array, items: INFERRED } },
        required: [:rewrites], additionalProperties: false
      }.freeze

      SYSTEM = <<~PROMPT
        An operator has written rewrites of one slow PostgreSQL query. You have no database connection. You get the payload for the original query, which holds only shapes: the query with $n placeholders for its literals, each placeholder's shape, the plan, the schema, and per-column statistics. You also get the operator's rewrites, which use the same placeholders.

        For each rewrite, in order, compare it with the original and infer the transformation it applies, and every assumption it seems to rely on to return the same rows. Only these kinds of assumption are allowed:
        - not_null: a column is NOT NULL.
        - unique: a set of columns is unique.
        - foreign_key: columns reference another table's columns.
        - check: a CHECK constraint with exactly this expression.
        Tables are always schema-qualified, such as public.orders.

        Answer with JSON, one entry per rewrite in the same order: {"rewrites": [{"transformation": "...", "assumptions": [...]}]}.
      PROMPT

      # provider is the entry that inferred the transformations and
      # assumptions, or nil when nothing was asked.
      Result = Data.define(:rewrites, :outcomes, :provider) do
        def initialize(rewrites:, outcomes:, provider: nil) = super
      end

      def self.from_file(path) = statements(File.read(path))

      # Each ;-terminated statement's text, trimmed. It raises Error if the
      # text doesn't parse, or ends with a statement that has no ;.
      def self.statements(text)
        PgQuery.parse(text).tree.stmts.map do |stmt|
          start = stmt.stmt_location
          if stmt.stmt_len.zero? || text.byteslice(start + stmt.stmt_len) != ";"
            raise Error,
                  "every rewrite must end with ;"
          end

          text.byteslice(start, stmt.stmt_len).strip
        end
      rescue PgQuery::ParseError
        raise Error, "the rewrites file doesn't parse", cause: nil
      end

      # The rewrite_check callable for a run's operator rewrites, over transport.
      def self.rewrite_check(transport, run_id:)
        lambda do |rewrites|
          transport.call("rewrite-check", args: { run: run_id }, input: { "rewrites" => rewrites, "inferred" => true })
                   .messages.select { it["type"] == "rewrite_outcome" }
        end
      end

      def initialize(client:, rewrite_check:)
        @client = client
        @rewrite_check = rewrite_check
      end

      def run(payload, sqls)
        return Result.new(rewrites: [], outcomes: []) if sqls.empty?

        session = @client.session
        inferred = infer(session, payload, sqls)
        raise Error, "the LLM inferred #{inferred.size} rewrites, not #{sqls.size}" unless inferred.size == sqls.size

        rewrites = sqls.zip(inferred).map { |sql, found| { "sql" => sql }.merge(found) }
        Result.new(rewrites:, outcomes: @rewrite_check.call(rewrites), provider: session.provider)
      end

      private

      def infer(session, payload, sqls)
        body = JSON.generate("payload" => payload, "rewrites" => sqls)
        messages = [{ role: :user, content: "The original and the rewrites:\n\n```json\n#{body}\n```" }]
        session.ask(step: STEP, system: SYSTEM, messages:, max_tokens: MAX_TOKENS, schema: SCHEMA).fetch("rewrites")
      end
    end
  end
end
