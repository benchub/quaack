# frozen_string_literal: true

require "json"

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
    # Trust boundary. The prompt carries only the payload, which is shape
    # data, and the LLM's own inserts.
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

        Write each insert as INSERT INTO schema.table (columns) VALUES (...), (...). Always schema-qualify the table and list the columns. Values must be constants, casts, $n, DEFAULT, or immutable function calls on those. To set a GENERATED ALWAYS identity column, write OVERRIDING SYSTEM VALUE before VALUES. Don't use INSERT ... SELECT, WITH, ON CONFLICT, or RETURNING: they get the insert refused. The rows must satisfy every constraint. The enclave adds parent rows for any foreign key you leave dangling, but never bypasses a constraint.

        Answer with JSON: {"inserts": ["INSERT INTO ...", ...]}.
      PROMPT

      def initialize(client:)
        @client = client
      end

      ROUNDS = 3

      Round = Data.define(:inserts, :outcome)
      Result = Data.define(:rounds, :disproved, :covered)

      # DESIGN.md's llm-counterexamples to counterexample-rollback, up to three rounds. compare stands for the
      # enclave's counterexample-compare and counterexample-rollback over the transport: it takes a round's
      # inserts and returns its outcome, a Hash with match, rule, covered
      # (untested atom shapes the round exercised), and refused (each
      # refused insert's index and rule). Every round runs, even a clean
      # one, and each later ask hears how the round before went. A round
      # that finds a mismatch (match false) disproves the candidate, and no
      # more run. A round whose inserts failed to load (load_failed, match
      # nil) disproves nothing, and the rounds go on.
      def run(payload, compare:)
        messages = [payload_message(payload)]
        rounds = []
        ROUNDS.times do |round|
          inserts = ask_with(messages, round.zero? ? FIRST : AGAIN)
          rounds << Round.new(inserts:, outcome: compare.call(inserts))
          break if rounds.last.outcome["match"] == false

          messages += follow_up(rounds.last)
        end
        result(rounds)
      end

      def ask(payload) = ask_with([payload_message(payload)])

      private

      def result(rounds)
        Result.new(rounds:, disproved: rounds.any? { it.outcome["match"] == false },
                   covered: rounds.flat_map { it.outcome["covered"] }.uniq)
      end

      def follow_up(round)
        [{ role: :assistant, content: JSON.generate("inserts" => round.inserts) },
         { role: :user, content: feedback(round.outcome) }]
      end

      def payload_message(payload)
        { role: :user, content: "The payload:\n\n```json\n#{JSON.generate(payload)}\n```" }
      end

      def ask_with(messages, purpose = FIRST)
        @client.ask(step: STEP, system: SYSTEM, messages:, max_tokens: MAX_TOKENS, schema: SCHEMA, purpose:)
               .fetch("inserts")
      end

      def result_line(outcome)
        return "The accepted inserts failed to load (#{outcome["rule"]})." if outcome["load_failed"]

        "The accepted inserts gave both queries the same results."
      end

      def feedback(outcome)
        refused = outcome["refused"].map { |r| "insert #{r["index"] + 1} was refused (#{r["rule"]})" }
        lines = refused + [result_line(outcome)]
        lines << "They exercised: #{outcome["covered"].join(", ")}." unless outcome["covered"].empty?
        "#{lines.join("\n")}\n\nWrite a new set of inserts that tries something different. " \
          "Answer with JSON: {\"inserts\": [...]}."
      end
    end
  end
end
