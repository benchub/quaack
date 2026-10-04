# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A rewrite in words: where it came from (DESIGN.md 6c) and what
      # became of it, from the one fate the payload gives it (DESIGN.md 15).
      #
      # Only the disproved fates and production_mismatch say a rewrite is
      # wrong. A test that failed, timed out, or never ran compared
      # nothing, and its sentence says so instead.
      module Rewrites
        SOURCES = { "llm" => "suggested by the LLM", "operator" => "your own rewrite" }.freeze
        RULES = "made by QUAACK's own rewrite"

        DIFFERENT = "It returned different results from your query on"
        UNCOMPARED = "ended without comparing results%<why>s, so QUAACK dropped it. That says nothing about " \
                     "whether it's right."
        PASSED = "It passed the tests on made-up data, but"
        DROPPED = "so QUAACK dropped it. That says nothing about whether it's right."

        FATES = {
          "ranked" => "It beat your query and is ranked below.",
          "same_plans" => "Postgres plans it exactly as it plans your query, so it can't run any differently. " \
                          "QUAACK didn't test it further.",
          "step9_disproved" => "#{DIFFERENT} made-up test data%<scenario>s, so it's wrong.",
          "step10_disproved" => "#{DIFFERENT} test data the LLM wrote to break it%<round>s, so it's wrong.",
          "step9_failed" => "A test on made-up data%<scenario>s #{UNCOMPARED}",
          "step10_failed" => "A test on data the LLM wrote to break it%<round>s #{UNCOMPARED}",
          "step9_untested" => "QUAACK couldn't make up test data for your query%<refusal>s, so it never tested " \
                              "this rewrite and won't recommend it. That says nothing about whether it's right.",
          "production_mismatch" => "#{PASSED} returned different results from your query on the real data, so " \
                                   "it's wrong.",
          "production_timed_out" => "#{PASSED} timed out when QUAACK compared its results with your query's on " \
                                    "the real data, #{DROPPED}",
          "production_not_compared" => "#{PASSED} QUAACK couldn't compare its results with your query's on the " \
                                       "real data%<why>s, #{DROPPED}",
          "below_top_three" => "It passed every test and beat your query, but three other candidates did better.",
          "footprint_tie" => "It passed every test and beat your query, but tied with a candidate whose new " \
                             "indexes take less disk space.",
          "not_better" => "It passed every test, but didn't read enough fewer blocks than your query. To count, " \
                          "a candidate must read more than 5%% fewer blocks on the slow values, and no more than " \
                          "5%% more on any others.",
          "measurement_timed_out" => "It passed every test, but every measurement run of it timed out."
        }.freeze

        # An unfinished rewrite, by the last stage it finished.
        UNFINISHED = { nil => "QUAACK kept it, but the run ended before testing it.",
                       "step9" => "It passed the tests on made-up data, and the run ended before going further.",
                       "step10" => "It passed every test, and the run ended before measuring it.",
                       "measurement" => "It was measured, and the run ended before QUAACK judged it." }.freeze

        # Where a rewrite came from, or nil if the payload doesn't say.
        def source(entry) = entry["source"] == "rule" ? made_by(entry["rules"]) : SOURCES[entry["source"]]

        def made_by(rules)
          rules = Array(rules)
          return "#{RULES} rules" if rules.empty?

          "#{RULES} #{rules.size == 1 ? "rule" : "rules"} #{rules.join(", then ")}"
        end

        # What a rule-made rewrite rests on that the data holds and the
        # schema doesn't enforce (DESIGN.md 6b's denormalized_equal), as a
        # sentence, or nil if nothing.
        def empirical(entry)
          said = Array(entry["empirical"]).grep(Hash).map do |a|
            "#{a["table"]}.#{a["column"]} equals #{a["references_table"]}.#{a["id_column"]} wherever " \
              "#{a["references_table"]}.#{a["type_column"]} names the type in your query"
          end
          return if said.empty?

          "It rests on something your data holds today but your schema doesn't enforce: #{said.join("; ")}. " \
            "QUAACK checked it on the real data."
        end

        # What became of a rewrite, as a sentence.
        def fate(entry)
          return UNFINISHED.fetch(entry["after"], UNFINISHED[nil]) if entry["fate"] == "unfinished"

          text = FATES[entry["fate"]] or return "#{Words::MISSING}."
          format(text, scenario: bracket(Words::SCENARIOS[entry["scenario"]]),
                       round: bracket(entry["round"] && "round #{entry["round"]}"), **because(entry))
        end

        # An fk_cycle refusal's tables, in the order their foreign keys
        # point, or nil.
        def cycle(entry)
          tables = entry["cycle"]
          return unless entry["rule"] == "fk_cycle" && tables.is_a?(Array) && !tables.empty? && tables.all?(String)

          tables.join(" -> ")
        end

        # A fate's rule, read as a failure or as step 9's refusal: its
        # sentence uses whichever it names. A refusal names an fk_cycle's
        # tables too.
        def because(entry)
          rule = entry["rule"]
          { why: why(rule), refusal: refusal(rule) + bracket(cycle(entry)) }
        end

        def bracket(text) = text ? " (#{text})" : ""

        def why(rule) = rule ? ", because #{Words::FAILURES.fetch(rule, Words::FAILED)}" : ""

        # Why step 9 couldn't make up test data, by its rule.
        def refusal(rule) = rule ? ", because #{Words::REFUSALS.fetch(rule) { Words.plain(rule) }}" : ""

        # A rewrite's name, source, and fate on one line, for the negative
        # result's list.
        def fate_line(entry)
          "#{Words.rewrite(entry["rewrite"])} (#{source(entry) || "source #{Words::MISSING}"}): #{fate(entry)}"
        end

        # The conditions step 9's test data never exercised.
        def atoms(entry) = Array(entry["untested_atoms"]).map { it.is_a?(Hash) ? it.values.join(" ") : it }

        # Whether step 10 exercised them, which only a rewrite that survived
        # step 10 says.
        def atoms_note(entry)
          return "No later test exercised them either." if entry["evidence"] == false

          "The LLM-written test data exercised them afterwards." if entry["evidence"] == true
        end

        # DESIGN.md 6c: the rule-made rewrites a test disproved.
        def rule_bugs = @payload["rule_bugs"] || []

        def bug(entry)
          where = Words::BUG_STEPS.fetch(entry["step"], "in a test")
          "#{Words.rewrite(entry["rewrite"])}, #{made_by(entry["rules"])}, returned different results #{where}."
        end
      end
    end
  end
end
