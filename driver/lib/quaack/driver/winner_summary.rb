# frozen_string_literal: true

require "json"
require_relative "llm/error"
require_relative "winner_summary/repeats"
require_relative "winner_summary/input"
require_relative "winner_summary/plan_steps"

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

      # outcome is used, or why the report goes without: no_winner,
      # failed (the ask failed, with rule), empty, or rejected. entry is the
      # name of the entry that answered, when one did.
      Result = Data.define(:text, :outcome, :entry, :rule) do
        def initialize(outcome:, text: nil, entry: nil, rule: nil) = super
      end

      SYSTEM = <<~PROMPT
        You're writing for a developer who writes SQL but may not know it well. QUAACK found a version of their PostgreSQL query that reads fewer blocks than the original, and the developer wants to learn when to write a query more like the winner, so they could have written it well from the start. You have no database connection. The payload holds what QUAACK measured and planned, and nothing else: the original query, the winning candidate, the plans of both, and the blocks each read on each set of values.

        The winner is either a rewrite of the original query, or the original query run with new indices, or a rewrite run with new indices. Compare the winner only with the original query as it runs now, on the indices the database already has. Don't compare it with any other candidate.

        Your job is advice, not a retelling of the plans. Use the plans to work out why the winner won, then turn that into what the developer should take away. The report prints both plans in full below your summary, so don't walk through them: don't list plan steps, their row counts, or what each one does. Say what the database had to do in everyday words, such as reading a whole table, going straight to the matching rows through an index, reading the same table twice, or checking a list again for every row. Name a plan step's type at most once or twice, and only where the advice needs it.

        Work out which of these questions the payload lets you answer, and answer those. Was the original query more general than it needed to be, given the constraints the schema provides? A rule applies only when its rule_preconditions hold, such as a column that can't be null or a key that's unique, so when the winner relies on one, the original was guarding against a case the schema already rules out, and that kept the database from a cheaper way to run it. Did the data make some feature of the query a poor fit? The plans' estimated and actual rows show how many rows a condition matched, and how far off Postgres's guess was, so you can say a condition matched few rows out of many, or far more than Postgres expected, when that's why another shape fit better. What should the developer look for next time? Give a heuristic: a sign they can spot in their own query, schema, or data without reading a plan, and the condition under which it holds.

        The lesson is conditional: it holds because this query, or the data and schema it runs on, has a particular feature. A takeaway that reads as a rule for every query, such as one telling the reader to use a UNION instead of an OR, is wrong and harmful, so never give one. Don't write always, never, all queries, or every query, and don't say to prefer one form over another without the condition under which it helps.

        Let the length follow the situation. Keep the whole summary under 700 characters, and shorter when the case is simple.

        When the winner is the original query with new indices, the query is unchanged and there is no transformation to name. In one or two sentences, and no more, say what about the query or its data made the new index worth having, such as a filter that picks a few rows out of many that the original found only by reading far more, say that the new index, by its definition, serves it, that no rewrite was needed, how many blocks each read on the slow values, and what to look for in other queries.

        When the winner is a rewrite, write three to five short sentences in this order. First, what about the original query, its schema, or its data made its shape a poor fit, answering the questions above; a rule's rule_preconditions held for this query, since the rule applied, so say what they mean for it in plain words. The payload's repeated_conditions lists each condition shape that the original repeats across the arms of one OR or the branches of one UNION, with how many times the shape appears in the original and in the winner. A shape writes $ for any placeholder, and QUAACK gives each value its own placeholder, so two copies of a shape may compare against different values: call it the same condition repeated, never the same value. When it lists a shape the winner holds fewer times than the original, name that condition, say the original repeated it in each arm or branch, and say the winner states it fewer times, which is part of what the rewrite changed. Don't say a condition was duplicated unless repeated_conditions lists it. Second, what the winner does differently, in plain words, as its rule_purposes describes it; a rule's own name is QUAACK's label, so don't use it. Third, why that paid off here, in a phrase rather than a walk through the plans, grounded in a difference between them, with the blocks each read on the slow values, which are the values from the developer's slow plan, and whether the winner held up on the other sets of values. Last, the heuristic: in general terms, without this query's table or column names, the sign to look for, and when the same change would help, and when it would not, so the reader knows it isn't a rule for every query.

        You may say a change let the database do something, or that it did so because of the change, only when a difference between the two plans in the payload backs it. Say only what the SQL, plans, and numbers in the payload show. Quote a plan step's own numbers, and never carry one step's row count to another step: a step that reads rows from the step below it doesn't have that step's count. Name a plan step by a node type that appears in one of the two plans, never one that doesn't, and without a join type or parallel qualifier such as anti, semi, or parallel, since the plans in the payload don't show those. Don't guess at a cause you can't see in them: a plan can't tell you about caching, table bloat, or statistics, and it shows the data only through its row counts, so say nothing about the data that those counts don't show. When a plan has no block counts, say so rather than inferring them. If the winner's plan is only an estimate, treat it as one. If the plans don't show why the winner reads fewer blocks, say that instead of giving a reason.

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
        text.scan(REWRITE_NAME).all? { it == winner } && PlanSteps.planned?(text, input)
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
