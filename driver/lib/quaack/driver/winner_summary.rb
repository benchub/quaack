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
      # The prompt asks for under 700, since it now asks for what changed,
      # why, and the pattern to look for (20261010-28). Real answers landed
      # at or just under the ask when it asked for 500 or 600, so the cap
      # leaves room for a longer plan.
      MAX_CHARS = 1000

      # Postgres's plan node types, as EXPLAIN names them. A summary may name
      # one only if a plan in the input has it. One of several words is read
      # in any case, with a space or a hyphen between words; a one-word type
      # only as EXPLAIN capitalizes it, so the SQL keyword LIMIT or the word
      # sort isn't read as a step. Longer names are tried first, so an Index
      # Only Scan isn't read as an Index Scan.
      NODE_TYPES = [
        "Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan", "Tid Scan",
        "Tid Range Scan", "Subquery Scan", "Function Scan", "Table Function Scan", "Values Scan", "CTE Scan",
        "Named Tuplestore Scan", "WorkTable Scan", "Foreign Scan", "Custom Scan", "Sample Scan", "Nested Loop",
        "Hash Join", "Merge Join", "Hash", "Sort", "Incremental Sort", "Aggregate", "HashAggregate",
        "GroupAggregate", "MixedAggregate", "Group", "Unique", "Limit", "Append", "Merge Append", "Materialize",
        "Memoize", "Gather", "Gather Merge", "SetOp", "HashSetOp", "Recursive Union", "BitmapAnd", "BitmapOr",
        "Result", "ProjectSet", "LockRows", "WindowAgg", "ModifyTable"
      ].freeze
      NODE_ALIASES = { "sequential scan" => "seq scan" }.freeze
      NODE_PATTERN = Regexp.union(
        (NODE_TYPES + NODE_ALIASES.keys).sort_by { -it.size }.map do |name|
          words = name.split.map { Regexp.escape(it) }
          words.size == 1 ? /\b#{words.first}\b/ : /\b#{words.join("[\\s-]+")}\b/i
        end
      )

      # outcome is used, or why the report goes without: no_winner,
      # failed (the ask failed, with rule), empty, or rejected. entry is the
      # name of the entry that answered, when one did.
      Result = Data.define(:text, :outcome, :entry, :rule) do
        def initialize(outcome:, text: nil, entry: nil, rule: nil) = super
      end

      SYSTEM = <<~PROMPT
        You're explaining to a database engineer why one version of a PostgreSQL query reads fewer blocks than the original. You have no database connection. The payload holds what QUAACK measured and planned, and nothing else: the original query, the winning candidate, the plans of both, and the blocks each read on each set of values.

        The winner is either a rewrite of the original query, or the original query run with new indexes, or a rewrite run with new indexes. Compare the winner only with the original query as it runs now, on the indexes the database already has. Don't compare it with any other candidate.

        The engineer wants to know why the winner wins, as a lesson they can apply to their own queries, not a list of plan steps. Write four or five plain sentences, each short and making one point, in this order. The whole summary must stay under 700 characters.

        First, say what changed in the query's structure. Compare the original SQL with the winner's SQL and say what was moved, merged, pulled out, split, removed, or replaced, in terms of the query's own clauses, such as an OR, an IN or NOT IN subquery, an EXISTS, a UNION, a join, or a repeated table. When there is a rewrite, name the rule that made it; each rule's purpose is in rule_purposes, so describe the change in the terms that purpose uses. When the winner is the original query with new indexes, say the query is unchanged and what the new index holds.

        Second, say why that change let the planner do less work. Ground it in a difference between the two plans: a scan or join type that changed, a step that disappeared or appeared, an index the winner's plan uses, or a smaller row or block count at a named step. You may say the change let the planner do something, or that it did so because of the change, only when a difference between the two plans in the payload backs it. Then say how many blocks each read on the slow values, which are the values from the engineer's slow plan, and whether the winner held up on the other sets of values.

        Last, in one sentence, name the pattern a developer could look for in their own queries to spot the same chance, stated in general terms about query structure, without this query's table or column names.

        Say only what the SQL, plans, and numbers in the payload show. Quote a plan step's own numbers, and never carry one step's row count to another step: a step that reads rows from the step below it doesn't have that step's count. Name a plan step by a node type that appears in one of the two plans, never one that doesn't. Don't guess at a cause you can't see in them: a plan can't tell you about caching, table bloat, statistics, or data distribution, so leave those out unless a number in the payload says so. When a plan has no block counts, say so rather than inferring them. If the winner's plan is only an estimate, treat it as one. If the plans don't show why the winner reads fewer blocks, say that instead of giving a reason.

        Call a rewrite by the name in the payload's rewrite name, if it has one. Refer to an index by its definition, never by a name you make up. Don't mention any other rewrite or index.

        Write plain text in one paragraph. No markdown, no lists, no headings, no code fences, no HTML, no links, and no URLs. Answer with only the summary.
      PROMPT

      # What no answer may hold: an HTML tag or an entity (a bare < or > is
      # fine, since a condition has them), a URL or domain, Markdown (a link,
      # a fence, bold, a heading, a quote, or a list), and a label
      # the report never shows (a rewrite's number, a candidate's label, a
      # built index's name), plus javascript: and data: as text, an @
      # address, and a format character (zero-width, bidi override).
      #
      # javascript: and vbscript: are refused with any space or none before the
      # colon. The plain schemes (data, mailto, file, ftp, about) are refused
      # only when a non-space follows the colon, so prose such as "reads data:
      # 935 blocks" stays. A bare IPv4 or IPv6 literal is refused too: it's
      # inert text, but a block-count summary never needs one, and it looks
      # like a host. A time or ratio such as 3:2 isn't an IPv6 literal.
      IP_LITERAL = Regexp.union(
        /(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?![\w.])/,
        /(?<![\w:])(?:\h{1,4}:){3,7}\h{1,4}(?![\w:])/,
        /(?<![\w:])(?:\h{1,4}:){0,6}\h{1,4}::(?:\h{1,4}(?![\w:])|(?!\w))/,
        /(?<![\w:])::\h{1,4}(?![\w:])/
      )
      REFUSED = [
        %r{<\s*[A-Za-z/!?]}, /&#?\w+;/, /https?:|www\.|\w+\.(?:com|org|net|io|dev)\b/i,
        /\b(?:javascript|vbscript)\s*:/i, /\b(?:data|mailto|file|ftp|about)\s*:(?=\S)/i, /\w@\w/,
        IP_LITERAL,
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
        text.scan(REWRITE_NAME).all? { it == winner } && named_steps_planned?(text, input)
      end

      # Whether every plan node type text names is a step of the original's
      # plan or the winner's.
      def named_steps_planned?(text, input)
        planned = [input.dig("original", "plan"), input.dig("winner", "plan")].flat_map { Array(it) }
                                                                              .filter_map { it["step"]&.downcase }
        text.scan(NODE_PATTERN).all? do |name|
          step = name.downcase.gsub(/[\s-]+/, " ")
          planned.include?(NODE_ALIASES.fetch(step, step))
        end
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
