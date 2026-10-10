# frozen_string_literal: true

require "json"
require_relative "llm/error"
require_relative "winner_summary/input"

module Quaack
  module Driver
    # The report's one LLM-written part: a few sentences that open "Why the
    # winner reads fewer blocks" (DESIGN.md, report, and "Several LLM
    # providers"). The driver asks for it, on the laptop, after the enclave
    # has sent the report payload, and the report prints it under a label
    # that says an LLM wrote it. The measurements below it stay the facts.
    #
    #   WinnerSummary.new(client:).run(payload)  # => Result
    #
    # payload is the report payload with each rewrite named (Report.named).
    # client is the LLM::Router. The ask is one unit of one, routed as the
    # step winner-summary (llm_routing.steps.winner-summary may pin it).
    #
    # Trust boundary. The prompt carries only what Input builds from the
    # payload by allowlist: shapes with $n placeholders, rule names, the
    # new indexes' definitions, plan steps, and block counts. No literal
    # and no value, and no provider's name or model.
    #
    # It never fails the report. A run that has no winner, or whose ask
    # fails, or whose answer the guard refuses, gets a Result with no text,
    # and the report reads as it did before the summary. The Result says
    # which, for the provenance record.
    class WinnerSummary
      STEP = "winner-summary"
      MAX_TOKENS = 1500
      # The prompt asks for under 500. Real answers ran 434 to 451 with that
      # wording (598 to 602 when it asked for 600), so they land at or just
      # under the ask. The cap leaves room for a longer plan.
      MAX_CHARS = 800

      # outcome is used, or why the report goes without: no_winner,
      # failed (the ask failed, with rule), empty, or rejected. entry is the
      # name of the entry that answered, when one did.
      Result = Data.define(:text, :outcome, :entry, :rule) do
        def initialize(outcome:, text: nil, entry: nil, rule: nil) = super
      end

      SYSTEM = <<~PROMPT
        You're explaining to a database engineer why one version of a PostgreSQL query reads fewer blocks than the original. You have no database connection. The payload holds what QUAACK measured and planned, and nothing else: the original query, the winning candidate, the plans of both, and the blocks each read on each set of values.

        The winner is either a rewrite of the original query, or the original query run with new indexes, or a rewrite run with new indexes. Compare the winner only with the original query as it runs now, on the indexes the database already has. Don't compare it with any other candidate.

        Write three or four plain sentences, each short and making one point. The whole summary must stay under 500 characters, so pick the two or three points that matter most. Say what the winner does differently from the original, using the plans' steps, tables, and indexes, the rewrite's rules and SQL when there is a rewrite, and the new indexes' definitions when there are any. Say how many blocks each read on the slow values, which are the values from the engineer's slow plan, and say whether the winner held up on the other sets of values.

        Say only what the plans and numbers in the payload show. Quote a plan step's own numbers, and never carry one step's row count to another step: a step that reads rows from the step below it doesn't have that step's count. Don't guess at a cause you can't see in them: a plan can't tell you about caching, table bloat, statistics, or data distribution, so leave those out unless a number in the payload says so. When a plan has no block counts, say so rather than inferring them. If the winner's plan is only an estimate, treat it as one. If the plans don't show why the winner reads fewer blocks, say that.

        Call a rewrite by the name in the payload's rewrite name, if it has one. Refer to an index by its definition, never by a name you make up. Don't mention any other rewrite or index.

        Write plain text in one paragraph. No markdown, no lists, no headings, no code fences, no HTML, no links, and no URLs. Answer with only the summary.
      PROMPT

      # What no answer may hold: an HTML tag or an entity (a bare < or > is
      # fine, since a condition has them), a URL or domain, Markdown (a link,
      # a fence, bold, a heading, a quote, or a list), and a label
      # the report never shows (a rewrite's number, a candidate's label, a
      # built index's name), plus javascript: and data: as text, an @
      # address, and a format character (zero-width, bidi override).
      REFUSED = [
        %r{<\s*[A-Za-z/!?]}, /&#?\w+;/, /https?:|www\.|\w+\.(?:com|org|net|io|dev)\b/i,
        /\b(?:javascript|data|vbscript|mailto|file|ftp|about)\s*:/i, /\w@\w/,
        /\p{Cf}|[\u2028\u2029\u3164\u2800\uFE0F]/, /\]\(|```|\*\*|__/,
        /\A\s*(?:[#>*]|-\s|\d+[.)]\s)/, /\n\s*(?:[#>*]|-\s|\d+[.)]\s)/, /\b(?:rewrite_\d|original:|quaack_)/i
      ].freeze
      # A dotted token that could be a host: it ends in a word of two or more
      # letters. A table, schema, or alias name looks the same, so a token the
      # input holds (public.orders, o.status) is fine, and any other is not.
      WORD = /[\p{L}\p{N}_]/
      DOTTED = /(?<!#{WORD})#{WORD}+(?:\.#{WORD}+)*\.\p{L}{2,}(?!#{WORD})/
      REWRITE_NAME = /\bRewrite [A-Z][a-z]+ [A-Z][a-z]+\b/

      def initialize(client:)
        @client = client
      end

      # The summary for payload's winner: asks the LLM and checks the
      # answer. Never raises an LLM error.
      def run(payload)
        input = Input.build(payload) or return Result.new(outcome: "no_winner")
        session = @client.session
        begin
          answer = ask(session, input)
        rescue LLM::Error => e
          return Result.new(outcome: "failed", entry: session.provider, rule: e.rule)
        end
        verdict(answer, input, session.provider)
      end

      private

      def ask(session, input)
        content = "The payload:\n\n```json\n#{JSON.generate(input)}\n```"
        session.ask(step: STEP, system: SYSTEM, messages: [{ role: :user, content: }], max_tokens: MAX_TOKENS,
                    purpose: "Asking the LLM for a summary of why the winner reads fewer blocks")
      end

      def verdict(answer, input, entry)
        text = answer.to_s.strip
        return Result.new(outcome: "empty", entry:) if text.empty?
        return Result.new(outcome: "rejected", entry:) unless acceptable?(text, input)

        Result.new(outcome: "used", text: text.gsub(/\s+/, " "), entry:)
      end

      # Whether text is a few plain sentences that name no rewrite but the
      # winner's: not too long, no markup, link, address, or control or format character, no host-looking
      # name the input doesn't hold, no
      # internal label, and no rewrite name but the winner's.
      def acceptable?(text, input)
        return false if text.size > MAX_CHARS || text.match?(/[\p{Cntrl}&&[^\n\t]]/) || REFUSED.any? { text.match?(it) }

        sent = JSON.generate(input)
        return false if text.scan(DOTTED).any? { !in_input?(it, sent) }

        winner = input.dig("winner", "rewrite", "name")
        text.scan(REWRITE_NAME).all? { it == winner }
      end

      # Whether a dotted token is one the input holds as whole words: either
      # verbatim, or with every part present as a word of its own, which
      # takes public.orders.status when the input has public.orders and
      # status, and orders.id when the query aliases orders. Any part the
      # input lacks refuses it.
      def in_input?(token, sent)
        whole = ->(part) { sent.match?(/(?<!#{WORD})#{Regexp.escape(part)}(?!#{WORD})/) }
        whole.call(token) || token.split(".").all?(&whole)
      end
    end
  end
end
