# frozen_string_literal: true

require "json"
require_relative "llm/router"

module Quaack
  module Driver
    # The driver's half of DESIGN.md's llm-counterexamples: asks the LLM for inserts that should
    # make one candidate and the original return different results.
    #
    #   Counterexamples.new(client:).ask(payload)  # => ["INSERT INTO ...", ...]
    #
    # payload is the shape-only payload the enclave sent: original (the
    # redacted query), candidate (its SQL, transformation, and
    # assumptions), placeholders (each $n's shape), schema (the subset
    # schema), constraints, and untested_atoms (vacuity-guard's shapes). It goes to
    # the LLM as it is. The LLM writes $n where it wants one of the query's
    # literals, and the enclave binds the real value and fills any
    # foreign-key gaps (Enclave::Counterexamples).
    #
    # client is the LLM::Router. One rewrite's rounds are one unit, so they
    # go to one provider, in one session. When a later round's ask fails
    # with a rule that fails over, the remaining rounds start fresh, as a
    # new unit on another provider, off every provider this rewrite's rounds
    # failed on (DESIGN.md, "Several LLM providers": Routing). Its first ask
    # is one user message: the payload, then each earlier round's inserts
    # and feedback, in the words already sent, under "Earlier rounds, run
    # by another model." None of it is the new model's own turns. The
    # rounds count on, so no rewrite gets more than three. label, such as
    # "Rewrite Silver Fox", names the rewrite in the progress line.
    #
    # Trust boundary. The prompt carries only the payload, which is shape
    # data, the LLM's own inserts, and the driver's feedback on them. A
    # fresh start sends nothing else, and no provider's name or model.
    class Counterexamples
      STEP = "llm-counterexamples"
      MAX_TOKENS = 4000
      # What progress hears each round's ask is for.
      FIRST = "Asking the LLM for rows that could break the rewrite"
      AGAIN = "Asking the LLM again, for different rows"

      SCHEMA = {
        type: :object,
        properties: { inserts: { type: :array, items: { type: :string } } },
        required: [:inserts],
        additionalProperties: false
      }.freeze

      SYSTEM = <<~PROMPT
        You're checking whether a rewrite of a PostgreSQL query returns the same results as the original. You have no database connection. The payload holds only shapes: the original query and the candidate rewrite, with $n placeholders for the original's literals, each placeholder's shape, the candidate's stated transformation and assumptions, the schema, and its constraints.

        Write rows that make the two queries return different results, if you can. Aim at the candidate's assumptions and at the edges its transformation might get wrong: NULLs, duplicates, empty groups, ties, case, and boundary values. untested_atoms lists predicates that fixtures so far never exercised, so make sure your rows exercise each of them, both passing and failing it.

        Write $1, $2, and so on wherever you want the query's own literal: the enclave puts the real value there. You may wrap one in an immutable function, such as upper($1).

        Write each insert as INSERT INTO schema.table (columns) VALUES (...), (...). Always schema-qualify the table and list the columns. Values must be constants, casts, $n, DEFAULT, or immutable function calls on those. To set a GENERATED ALWAYS identity column, write OVERRIDING SYSTEM VALUE before VALUES. Don't read the clock: now(), CURRENT_DATE, CURRENT_TIMESTAMP, and a string such as 'now', 'today', 'tomorrow', or 'yesterday' read as a date or time get the insert refused, so write fixed dates and times, such as '2024-01-15 10:00:00+00'. Don't use INSERT ... SELECT, WITH, ON CONFLICT, or RETURNING: they get the insert refused. The rows must satisfy every constraint. The enclave adds parent rows for any foreign key you leave dangling, but never bypasses a constraint.

        Answer with JSON: {"inserts": ["INSERT INTO ...", ...]}.
      PROMPT

      def initialize(client:, label: nil)
        @client = client
        @label = label
      end

      ROUNDS = 3

      ANSWER = 'Answer with JSON: {"inserts": [...]}.'
      ANOTHER = "Write a new set of inserts that tries something different. #{ANSWER}".freeze
      EARLIER = "Earlier rounds, run by another model."
      DIFFERENT = "Write a new set of inserts that tries something different from all of them. #{ANSWER}".freeze

      # provider is the entry that wrote the inserts, and after, for a fresh
      # start's first round, the rule that ended the unit before it.
      Round = Data.define(:inserts, :outcome, :provider, :after) do
        def initialize(inserts:, outcome:, provider: nil, after: nil) = super
      end
      Result = Data.define(:rounds, :disproved, :covered, :units) do
        def initialize(rounds:, disproved:, covered:, units: []) = super
      end

      # DESIGN.md's llm-counterexamples to counterexample-rollback, up to three rounds. compare stands for the
      # enclave's counterexample-compare and counterexample-rollback over the transport: it takes a round's
      # inserts and returns its outcome, a Hash with match, rule, covered
      # (untested atom shapes the round exercised), and refused (each
      # refused insert's index and rule). Every round runs, even a clean
      # one, and each later ask hears how the round before went. A round
      # that finds a mismatch (match false) disproves the candidate, and no
      # more run. A round whose inserts failed to load (load_failed, match
      # nil) disproves nothing, and the rounds go on.
      #
      # The result's units say, for the provenance record, which entry ran
      # each unit, in order, how many rounds it asked, and, for a fresh
      # start, after, the rule that ended the unit before it.
      def run(payload, compare:)
        rounds = []
        failed = {}
        unit = [@client.session, [payload_message(payload)]]
        until over?(rounds)
          unit = turn(unit, rounds, compare) { |error, session| fresh(error, session, failed, payload, rounds) }
        end
        result(rounds)
      end

      def ask(payload) = ask_with([payload_message(payload)])

      private

      def over?(rounds) = rounds.size == ROUNDS || rounds.last&.outcome&.fetch("match") == false

      # One round on unit, a session, the messages it asks with, and, for a
      # fresh start's first round, the rule that ended the unit before: asks
      # for the round's inserts, has compare load them, and adds the round,
      # with its provider and that rule, to rounds. Returns the unit for the
      # next round, or, when the ask failed with a LaterError, the block's,
      # given the error and the session.
      def turn((session, messages, after), rounds, compare)
        inserts = ask_with(messages, rounds.empty? ? FIRST : AGAIN, session)
        rounds << Round.new(inserts:, outcome: compare.call(inserts), provider: session.provider, after:)
        [session, messages + follow_up(rounds.last)]
      rescue LLM::Router::LaterError => e
        yield e, session
      end

      # The unit that starts the remaining rounds fresh after error, off
      # every provider this rewrite's rounds failed on, which failed
      # collects, session's among them.
      def fresh(error, session, failed, payload, rounds)
        [@client.fresh(error, skip: failed.merge!(session.failures), label: @label), [fresh_message(payload, rounds)],
         error.rule]
      end

      def result(rounds)
        units = rounds.slice_before(&:after).map do |unit|
          { "entry" => unit.first.provider, "rounds" => unit.size, "after" => unit.first.after }.compact
        end
        Result.new(rounds:, disproved: rounds.any? { it.outcome["match"] == false },
                   covered: rounds.flat_map { it.outcome["covered"] }.uniq, units:)
      end

      def follow_up(round)
        [{ role: :assistant, content: JSON.generate("inserts" => round.inserts) },
         { role: :user, content: "#{feedback_lines(round.outcome)}\n\n#{ANOTHER}" }]
      end

      # A fresh start's one user message: the payload as the first round
      # sent it, then each earlier round's inserts, as its follow-up sent
      # them, and its feedback.
      def fresh_message(payload, rounds)
        earlier = rounds.each_with_index.map do |round, i|
          "Round #{i + 1}'s inserts:\n\n```json\n#{JSON.generate("inserts" => round.inserts)}\n```\n\n" \
            "#{feedback_lines(round.outcome)}"
        end
        { role: :user, content: "#{payload_message(payload)[:content]}\n\n#{EARLIER}\n\n" \
                                "#{earlier.join("\n\n")}\n\n#{DIFFERENT}" }
      end

      def payload_message(payload)
        { role: :user, content: "The payload:\n\n```json\n#{JSON.generate(payload)}\n```" }
      end

      def ask_with(messages, purpose = FIRST, session = @client)
        session.ask(step: STEP, system: SYSTEM, messages:, max_tokens: MAX_TOKENS, schema: SCHEMA, purpose:)
               .fetch("inserts")
      end

      def result_line(outcome)
        return "The accepted inserts failed to load (#{outcome["rule"]})." if outcome["load_failed"]

        "The accepted inserts gave both queries the same results."
      end

      # What the driver tells the LLM about a round: which inserts were
      # refused and by which rule, whether the accepted ones loaded, and
      # which untested atoms they exercised.
      def feedback_lines(outcome)
        refused = outcome["refused"].map { |r| "insert #{r["index"] + 1} was refused (#{r["rule"]})" }
        lines = refused + [result_line(outcome)]
        lines << "They exercised: #{outcome["covered"].join(", ")}." unless outcome["covered"].empty?
        lines.join("\n")
      end
    end
  end
end
