# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A rewrite in words: where it came from (DESIGN.md's rewrite-rules) and what
      # became of it, from the one fate the payload gives it (DESIGN.md's report).
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
          "rewrite_test_disproved" => "#{DIFFERENT} made-up test data%<scenario>s, so it's wrong.",
          "counterexamples_disproved" => "#{DIFFERENT} test data the LLM wrote to break it%<round>s, so it's wrong.",
          "rewrite_test_failed" => "A test on made-up data%<scenario>s #{UNCOMPARED}",
          "counterexamples_failed" => "A test on data the LLM wrote to break it%<round>s #{UNCOMPARED}",
          "rewrite_test_untested" => "QUAACK couldn't make up test data for your query%<refusal>s, so it never " \
                                     "tested this rewrite and won't recommend it. That says nothing about " \
                                     "whether it's right.",
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
                       "rewrite-test" => "It passed the tests on made-up data, and the run ended before going further.",
                       "counterexamples" => "It passed every test, and the run ended before measuring it.",
                       "measurement" => "It was measured, and the run ended before QUAACK judged it." }.freeze

        # A rewrite or rule_bugs entry as "Rewrite" and the name Report.named
        # gave it, or by its number without one.
        def called(entry) = entry["name"] ? "Rewrite #{entry["name"]}" : Words.numbered(entry["rewrite"])

        # Where a rewrite came from, or nil if the payload doesn't say.
        def source(entry) = entry["source"] == "rule" ? made_by(entry["rules"]) : SOURCES[entry["source"]]

        def made_by(rules)
          rules = Array(rules)
          return "#{RULES} rules" if rules.empty?

          "#{RULES} #{rules.size == 1 ? "rule" : "rules"} #{rules.join(", then ")}"
        end

        # What a rule-made rewrite rests on that the data holds and the
        # schema doesn't enforce (DESIGN.md's assumption-check's denormalized_equal), as a
        # sentence, or nil if nothing.
        def empirical(entry)
          said = Array(entry["empirical"]).grep(Hash).map do |a|
            "#{column(a["table"], a["column"])} equals #{column(a["references_table"], a["id_column"])} " \
              "wherever #{column(a["references_table"], a["type_column"])} names the type in your query"
          end
          return if said.empty?

          "It rests on something your data holds today but your schema doesn't enforce: #{said.join("; ")}. " \
            "QUAACK checked it on the real data."
        end

        def column(table, name) = Format.sql_span("#{table}.#{name}")

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

          tables.map { Format.sql_span(it) }.join(" -> ")
        end

        # A fate's rule, read as a failure or as rewrite-test's refusal: its
        # sentence uses whichever it names. A refusal names an fk_cycle's
        # tables too.
        def because(entry)
          rule = entry["rule"]
          { why: why(rule), refusal: refusal(rule) + bracket(cycle(entry)) }
        end

        def bracket(text) = text ? " (#{text})" : ""

        def why(rule) = rule ? ", because #{Words::FAILURES.fetch(rule, Words::FAILED)}" : ""

        # Why rewrite-test couldn't make up test data, by its rule.
        def refusal(rule) = rule ? ", because #{Words::REFUSALS.fetch(rule) { Words.plain(rule) }}" : ""

        # A rewrite's name, source, and fate on one line, for the negative
        # result's list.
        def fate_line(entry)
          "#{called(entry)} (#{source(entry) || "source #{Words::MISSING}"}): #{fate(entry)}"
        end

        UNTESTED = "QUAACK tests a rewrite on rows it makes up, to check that it returns what your query returns. " \
                   "Those rows never made the conditions below, from your query's WHERE and JOIN clauses, both " \
                   "true and false, so a rewrite that changed one of them could still have passed."
        LATER = "The test data the LLM wrote afterwards to break the rewrite"
        CHECKED_LATER = "checked later"

        # The conditions of your query that rewrite-test's made-up rows never
        # exercised (vacuity-guard), by their redacted shapes. Anything else
        # the payload holds there, such as an atom's index, isn't one.
        def atoms(entry) = Array(entry["untested_atoms"]).grep(String).uniq

        # Those a counterexample round's rows exercised afterwards.
        def checked_later(entry) = atoms(entry) & Array(entry["covered"]).grep(String)

        # Those no test exercised.
        def unchecked_atoms(entry) = atoms(entry) - checked_later(entry)

        # Whether a counterexample round exercised them. covered is nil
        # when no round ran.
        def atoms_note(entry)
          return "No later test checked them." unless entry["covered"].is_a?(Array)
          return "#{LATER} didn't check them either." if checked_later(entry).empty?
          return "#{LATER} checked all of them, so none is left unchecked." if unchecked_atoms(entry).empty?

          "#{LATER} checked the ones marked “#{CHECKED_LATER}”, but not the others."
        end

        # A hint for a rewrite's summary line, so a collapsed section still
        # shows that it holds a warning: what the rewrite rests on in the
        # data, or conditions no test exercised, even later. nil if neither.
        def warning(entry)
          said = []
          said << "it relies on what your data holds today." if empirical(entry)
          test_data = said.empty? ? "the test data" : "The test data also"
          said << "#{test_data} left some of its conditions untested." if unchecked_atoms(entry).any?
          "Read it with care: #{said.join(" ")}" unless said.empty?
        end

        # DESIGN.md's rewrite-rules: the rule-made rewrites a test disproved.
        def rule_bugs = @payload["rule_bugs"] || []

        def bug(entry)
          where = Words::BUG_STEPS.fetch(entry["step"], "in a test")
          "#{called(entry)}, #{made_by(entry["rules"])}, returned different results #{where}."
        end
      end
    end
  end
end
