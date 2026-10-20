# frozen_string_literal: true

require_relative "../cli/refused"
require_relative "../rewrite_redaction"

module Quaack
  module Enclave
    module Steps
      # `quaacks redact-rewrite --run <run ID>` (DESIGN.md's redact-rewrite): an
      # operator's rewrite, written with real literals, with each literal
      # replaced by the run's placeholder in the same comparison (see
      # RewriteRedaction).
      #
      # stdin is one JSON object, {"sql": "<one SQL statement>"}, which the
      # driver sends over ssh. Any other shape is refused as bad_input. It
      # reads the run's redacted_query, and its placeholder map only to break
      # a tie by value (RewriteRedaction.tied). It writes nothing to the
      # store and connects to no database.
      #
      # It sends one redacted_rewrite with the SQL, which holds only
      # placeholders. A literal with no match, or more than one, is refused
      # as usage (Refused), with its rule and position and never its value,
      # and for more than one, the candidates' $n numbers.
      module RedactRewrite
        # RewriteRedaction::Refusal as the CLI's usage refusal, so it exits as
        # the other usage errors do. ErrorFilter sends its position.
        class Refused < CLI::Refused
          attr_reader :position, :candidates

          def initialize(rule, position, candidates)
            @position = position
            @candidates = candidates
            super(rule)
          end
        end

        module_function

        def call(store:, input:, **)
          sql = input["sql"] if input.keys == ["sql"]
          raise CLI::Refused, "bad_input" unless sql.is_a?(String)

          [{ type: :redacted_rewrite, sql: RewriteRedaction.redact(sql, store.read("redacted_query"),
                                                                   Redaction.placeholder_map(store)) }]
        rescue RewriteRedaction::Refusal => e
          raise Refused.new(e.rule, e.position, e.candidates), cause: nil
        end
      end
    end
  end
end
