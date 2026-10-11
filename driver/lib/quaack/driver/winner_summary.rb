# frozen_string_literal: true

require "json"
require_relative "llm/error"
require_relative "winner_summary/repeats"
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

      # A join or parallel qualifier on a node type: Hash Anti Join, a semi
      # join, a Parallel Seq Scan. The payload's plan nodes carry only the
      # bare node type, not EXPLAIN's Join Type or Parallel Aware, so no
      # summary can back one, and the check refuses it outright
      # (20261010-37).
      QUALIFIED = Regexp.union(/\b(?:anti|semi)(?:[\s-]+|-?)join\b/i,
                               /\b(?:hash|merge|nested[\s-]+loop)[\s-]+(?:anti|semi)\b/i,
                               /\bparallel[\s-]+(?:#{NODE_PATTERN.source})/i)

      # outcome is used, or why the report goes without: no_winner,
      # failed (the ask failed, with rule), empty, or rejected. entry is the
      # name of the entry that answered, when one did.
      Result = Data.define(:text, :outcome, :entry, :rule) do
        def initialize(outcome:, text: nil, entry: nil, rule: nil) = super
      end

      SYSTEM = <<~PROMPT
        You're explaining to a database engineer why one version of a PostgreSQL query reads fewer blocks than the original. You have no database connection. The payload holds what QUAACK measured and planned, and nothing else: the original query, the winning candidate, the plans of both, and the blocks each read on each set of values.

        The winner is either a rewrite of the original query, or the original query run with new indexes, or a rewrite run with new indexes. Compare the winner only with the original query as it runs now, on the indexes the database already has. Don't compare it with any other candidate.

        The engineer wants a lesson about when this kind of change pays off, so they could have written the query well from the start. The lesson is conditional: it holds because this query, or the data and schema it runs on, has a particular feature. A takeaway that reads as a rule for every query, such as one telling the reader to use a UNION instead of an OR, is wrong and harmful, so never give one. Don't write always, never, all queries, or every query, and don't say to prefer one form over another without the condition under which it helps.

        Let the length follow the situation. Keep the whole summary under 700 characters, and shorter when the case is simple.

        When the winner is the original query with new indexes, the query is unchanged and there is no transformation to name. In one or two sentences, and no more, say what feature of the query or its data made the new index useful, grounded in the plans, such as a filter on a column the original read with a scan that touched many more blocks than the rows it returned, say that the new index, by its definition, serves that filter, that no rewrite was needed, and how many blocks each read on the slow values.

        When the winner is a rewrite, write three to five short sentences in this order. First, the precondition: the feature of the original query, or the fact about the schema or data, that made the rewrite possible and useful. Each rule's rule_preconditions says what must hold for it to apply, and since the rule did apply, that held for this query; state it in those terms. The payload's repeated_conditions lists each condition shape that the original repeats across the arms of one OR or the branches of one UNION, with how many times the shape appears in the original and in the winner. A shape writes $ for any placeholder, and QUAACK gives each value its own placeholder, so two copies of a shape may compare against different values: call it the same condition repeated, never the same value. When it lists a shape the winner holds fewer times than the original, name that condition, say the original repeated it in each arm or branch, as part of the precondition, and say the winner states it fewer times, which is part of what the rewrite changed. Don't say a condition was duplicated unless repeated_conditions lists it. Second, name the transformation that precondition allowed, by the rule's name and in the terms its rule_purposes uses. Third, say why it helps in this situation, grounded in a difference between the two plans, saying what the original's form kept the planner from doing and what the winner's form let it do: a scan or join type that changed, a step that disappeared or appeared, an index the winner's plan uses, or a smaller row or block count at a named step, and give the blocks each read on the slow values, which are the values from the engineer's slow plan, and whether the winner held up on the other sets of values. Last, say in general terms, without this query's table or column names, the condition under which the same change would help, and when it would not, so the reader knows it isn't a rule for every query.

        You may say a change let the planner do something, or that it did so because of the change, only when a difference between the two plans in the payload backs it. Say only what the SQL, plans, and numbers in the payload show. Quote a plan step's own numbers, and never carry one step's row count to another step: a step that reads rows from the step below it doesn't have that step's count. Name a plan step by a node type that appears in one of the two plans, never one that doesn't, and without a join type or parallel qualifier such as anti, semi, or parallel, since the plans in the payload don't show those. Don't guess at a cause you can't see in them: a plan can't tell you about caching, table bloat, statistics, or data distribution, so leave those out unless a number in the payload says so. When a plan has no block counts, say so rather than inferring them. If the winner's plan is only an estimate, treat it as one. If the plans don't show why the winner reads fewer blocks, say that instead of giving a reason.

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
        /(?<![\w.])\d{1,3}(?:\.\d{1,3}){3}(?!\w|\.\w)/,
        /(?<![\w:])(?:\h{1,4}:){3,7}\h{1,4}(?![\w:])/,
        /(?<![\w:])(?:\h{1,4}:){0,6}\h{1,4}::(?:\h{1,4}(?![\w:])|(?!\w))/,
        /(?<![\w:])::(?:\h{1,4}:){0,6}\h{1,4}(?![\w:])/
      )
      # Advice stated for every query, which the lesson must never be: it
      # holds only under its precondition (20261010-37).
      # A plain always or never about this plan, as in the winner never
      # scans a table, is fine: only advice phrasings are refused.
      UNIVERSAL = /\b(?:always|never)\s+(?:use|write|split|prefer|avoid|add|put|rewrite|replace|turn|create|do)\b|
                   \b(?:should|must|you)\s+(?:always|never)\b|(?:\A|[.;!]\s+)(?:always|never)\b|
                   \b(?:all|every)\s+quer(?:y|ies)\b/ix
      REFUSED = [
        %r{<\s*[A-Za-z/!?]}, /&#?\w+;/, /https?:|www\.|\w+\.(?:com|org|net|io|dev)\b/i,
        /\b(?:javascript|vbscript)\s*:/i, /\b(?:data|mailto|file|ftp|about)\s*:(?=\S)/i, /\w@\w/,
        IP_LITERAL,
        /\p{Cf}|[\u2028\u2029\u3164\u2800\uFE0F]/, /\]\(|```|\*\*|__/,
        UNIVERSAL, /\A\s*(?:[#>*]|-\s|\d+[.)]\s)/, /\n\s*(?:[#>*]|-\s|\d+[.)]\s)/, /\b(?:rewrite_\d|original:|quaack_)/i
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
      # plan or the winner's, with no join or parallel qualifier.
      def named_steps_planned?(text, input)
        planned = [input.dig("original", "plan"), input.dig("winner", "plan")].flat_map { Array(it) }
                                                                              .filter_map { it["step"]&.downcase }
        return false if text.match?(QUALIFIED)

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
