# frozen_string_literal: true

require "quaack/protocol/fuzz_result"
require "quaack/protocol/rewrite_budget"

module Quaack
  module Driver
    module Report
      # A rewrite in words: where it came from (DESIGN.md's rewrite-rules) and what
      # became of it, from the one fate the payload gives it (DESIGN.md's report).
      #
      # Only the disproved fates and production_mismatch say a rewrite is
      # wrong. A test that failed, timed out, or never ran compared
      # nothing, and its sentence says so instead.
      module Rewrites # rubocop:disable Metrics/ModuleLength -- report wording, one sentence per entry
        SOURCES = { "llm" => "suggested by the LLM", "operator" => "your own rewrite" }.freeze
        RULES = "made by transform"

        DIFFERENT = "It returned different results from the original query on"
        UNCOMPARED = "ended without comparing results%<why>s, so QUAACK dropped it. That says nothing about " \
                     "whether it's right."
        PASSED = "It passed the tests on made-up data, but"
        DROPPED = "so QUAACK dropped it. That says nothing about whether it's right."

        FATES = {
          "ranked" => "It beat the original query and is ranked below.",
          "same_plans" => "Postgres plans it exactly as it plans the original query, so it can't run any " \
                          "differently. QUAACK didn't test it further.",
          "rewrite_test_disproved" => "#{DIFFERENT} made-up test data%<scenario>s, so it's wrong.",
          "fuzz_disproved" => "#{DIFFERENT} a random small database built around its own values%<fuzz>s, so it's " \
                              "wrong.",
          "enumerate_disproved" => "#{DIFFERENT} a small database QUAACK enumerated from its own values%<fuzz>s, " \
                                   "so it's wrong.",
          "counterexamples_disproved" => "#{DIFFERENT} test data the LLM wrote to break it%<round>s, so it's wrong.",
          "rewrite_test_failed" => "A test on made-up data%<scenario>s #{UNCOMPARED}",
          "counterexamples_failed" => "A test on data the LLM wrote to break it%<round>s #{UNCOMPARED}",
          "rewrite_test_untested" => "QUAACK couldn't make up test data for the original query%<refusal>s, so it " \
                                     "never tested this rewrite and won't recommend it. That says nothing about " \
                                     "whether it's right.",
          Protocol::RewriteBudget::FATE => "QUAACK couldn't test it within #{Protocol::RewriteBudget.minutes} " \
                                           "minutes, so it left it out and won't recommend it. That says nothing " \
                                           "about whether it's right.",
          "production_mismatch" => "#{PASSED} returned different results from the original query on the real " \
                                   "data, so it's wrong.",
          "production_timed_out" => "#{PASSED} timed out when QUAACK compared its results with the original query's " \
                                    "on the real data, #{DROPPED}",
          "production_not_compared" => "#{PASSED} QUAACK couldn't compare its results with the original query's on " \
                                       "the real data%<why>s, #{DROPPED}",
          "below_top_three" => "It passed every test and beat the original query, but three others of its kind " \
                               "did better.",
          "footprint_tie" => "It passed every test and beat the original query, but tied with a candidate " \
                             "whose new indexes take less disk space.",
          "not_better" => nil, # worded by NotBetterFate
          "measurement_timed_out" => "It passed every test, but every measurement run of it timed out."
        }.freeze

        # fuzz_disproved by query_failed: the rewrite failed where the
        # original ran (task 20261012-2).
        FUZZ_FAILED = "It failed on a random small database built around its own values%<fuzz>s, where the " \
                      "original query ran, so it's wrong."
        ENUMERATE_FAILED = "It failed on a small database QUAACK enumerated from its own values%<fuzz>s, where " \
                           "the original query ran, so it's wrong."
        SEARCH_FAILED = { "fuzz_disproved" => FUZZ_FAILED, "enumerate_disproved" => ENUMERATE_FAILED }.freeze

        # The fates of a rewrite a stage after the searches disproved, whose
        # section keeps fuzz's sentence rather than enumerate's.
        LATER_DISPROOFS = %w[rewrite_test_disproved counterexamples_disproved production_mismatch].freeze

        # An unfinished rewrite, by the last stage it finished.
        UNFINISHED = { nil => "QUAACK kept it, but the run ended before testing it.",
                       "rewrite-test" => "It passed the tests on made-up data, and the run ended before going further.",
                       "counterexamples" => "It passed every test, and the run ended before measuring it.",
                       "measurement" => "It was measured, and the run ended before QUAACK judged it." }.freeze

        # A rewrite whose rewrite-test ran out of time and went on (task
        # 20261011-15) never passed the tests on made-up data, so its later
        # fate's opening says what happened instead, by the first of these
        # that matches.
        UNTIMED_SHORT = "Its test on made-up data didn't finish within " \
                        "#{Protocol::RewriteBudget.minutes} minutes".freeze
        UNTIMED_LEAD = "#{UNTIMED_SHORT}, so QUAACK checked it only on test data the LLM wrote to break it and on " \
                       "the real data".freeze
        UNTIMED = [["It passed the tests on made-up data, and the run ended", "#{UNTIMED_SHORT}, and the run ended"],
                   ["It passed every test, and the run ended",
                    "#{UNTIMED_SHORT}, it passed the LLM's test data, and the run ended"],
                   ["It passed the tests on made-up data, but QUAACK", "#{UNTIMED_LEAD}, but QUAACK"],
                   ["It passed the tests on made-up data, but", "#{UNTIMED_LEAD}, and it"],
                   ["It passed every test and beat", "#{UNTIMED_LEAD}, and it beat"],
                   ["It passed every test,", "#{UNTIMED_LEAD},"]].freeze

        # text, reworded by UNTIMED when entry's test ran out of time.
        def untimed(entry, text)
          return text unless entry["out_of_time"] == true

          from, to = UNTIMED.find { text.start_with?(it.first) }
          from ? text.sub(from, to) : text
        end

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
              "wherever #{column(a["references_table"], a["type_column"])} names the type in the original query"
          end
          return if said.empty?

          "It rests on something your data holds today but your schema doesn't enforce: #{said.join("; ")}. " \
            "QUAACK checked it on the real data."
        end

        def column(table, name) = Format.sql_span("#{table}.#{name}")

        # What became of a rewrite, as a sentence.
        def fate(entry)
          return untimed(entry, UNFINISHED.fetch(entry["after"], UNFINISHED[nil])) if entry["fate"] == "unfinished"

          text = untimed(entry, fate_text(entry) || (return "#{Words::MISSING}."))
          format(text, percent: NotBetterFate::PERCENT, **fills(entry), **because(entry))
        end

        # The fate sentences' bracketed details.
        def fills(entry)
          { scenario: bracket(Words::SCENARIOS[entry["scenario"]]), fuzz: bracket(fuzz(entry)),
            round: bracket(entry["round"] && "round #{entry["round"]}") }
        end

        # A fuzz disproof's rows per table and how the results differed,
        # such as "2 rows in orders and 1 in customers; the row count
        # differs", or nil with neither. Sizes that aren't [schema, table,
        # rows] triples, rows a positive count, are left out.
        def fuzz(entry)
          parts = [sizes(entry["sizes"]), Words::MISMATCHES[entry["rule"]]].compact
          parts.join("; ") unless parts.empty?
        end

        def sizes(list)
          return unless list.is_a?(Array) && !list.empty? && list.all? { size?(it) }

          said = list.each_with_index.map { |size, i| size_words(*size, first: i.zero?) }
          said.size < 3 ? said.join(" and ") : "#{said[..-2].join(", ")}, and #{said.last}"
        end

        # "2 rows in orders", or just "2 in sales.customers" after the first;
        # 5, the most a size says, is "5 or more".
        def size_words(schema, table, rows, first:)
          count = first ? Words.count(rows, "row") : Format.number(rows)
          count = count.sub(/\A\d+/, '\0 or more') if rows == Protocol::FuzzResult::MAX_SIZE
          "#{count} in " \
            "#{"#{schema}." unless schema == "public"}#{table}"
        end

        def size?(size)
          size.is_a?(Array) && size.size == 3 && size.take(2).all?(String) && size[2].is_a?(Integer) &&
            size[2].between?(1, Protocol::FuzzResult::MAX_SIZE)
        end

        # How many random small databases fuzz compared the rewrite on, and
        # the bound enumerate finished, in the user's words (2026-10-12),
        # unless either proved it wrong, or nil.
        def fuzz_line(entry)
          trials = entry["trials"]
          return unless trials.is_a?(Integer) && trials.positive? && !SEARCH_FAILED.key?(entry["fate"])

          bound = entry["bound"]
          return "It also survived #{Words.count(trials, "random small database")} built around its own values." \
            unless bound.is_a?(Integer) && bound.between?(1, Protocol::FuzzResult::MAX_BOUND) &&
                   !LATER_DISPROOFS.include?(entry["fate"])

          "Found no difference on #{Words.count(trials, "random dataset")}, or on any dataset of up to " \
            "#{Words.count(bound, "row")} over its value classes."
        end

        def fate_text(entry)
          return not_better_text(entry) if entry["fate"] == "not_better"
          return SEARCH_FAILED[entry["fate"]] if SEARCH_FAILED.key?(entry["fate"]) && entry["rule"] == "query_failed"

          FATES[entry["fate"]]
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

        UNTESTED = "QUAACK's tests never made these conditions from the original query both true and false, " \
                   "and they are in a part the rewrite changed, so they can't show the rewrite handles them the " \
                   "same way:"

        # How a condition stayed unproven, by vacuity-guard's search state
        # (Protocol::UntestedStates::WORDS; the budget is DESIGN.md's).
        HOW = {
          "searched" => "QUAACK also tried 150 small made-up databases for it and found none where it changes " \
                        "the result.",
          "not_searched" => "QUAACK didn't search small made-up databases for it in full: it ran out of search " \
                            "time, or the query has a LIMIT or OFFSET, compares a count with a number, or calls a " \
                            "function whose results change from run to run."
        }.freeze

        # The conditions of the original query that rewrite-test's made-up rows never
        # exercised (vacuity-guard), by their redacted shapes. Anything else
        # the payload holds there, such as an atom's index, isn't one.
        def atoms(entry) = Array(entry["untested_atoms"]).grep(String).uniq

        # What HOW says for the atom, or nil when the entry's untested_states
        # isn't one known word per untested atom (or it's missing, as in a
        # message from before the search).
        def how(entry, atom)
          states = entry["untested_states"]
          list = entry["untested_atoms"]
          return unless states.is_a?(Array) && list.is_a?(Array) && states.size == list.size
          return unless states.all? { HOW.key?(it) }

          HOW[states[list.index(atom)]]
        end

        # Those a counterexample round's rows exercised afterwards.
        def checked_later(entry) = atoms(entry) & Array(entry["covered"]).grep(String)

        # Those the rewrite left unchanged by position (DESIGN.md's
        # unchanged-atoms), as the enclave found. A missing or malformed
        # list counts none. A shape that isn't an untested one takes nothing off.
        def unchanged_atoms(entry)
          list = entry["untested_unchanged"]
          list.is_a?(Array) ? list.grep(String) : []
        end

        # Those no test exercised, in a part the rewrite changed.
        def unchecked_atoms(entry) = atoms(entry) - checked_later(entry) - unchanged_atoms(entry)

        # How many of rewrite-test's scenario groups it left out because
        # their rows would collide on a unique key, or nil for none.
        def dropped_line(entry)
          count = entry["dropped"]
          return unless count.is_a?(Integer) && count.positive?

          "QUAACK left out #{Words.count(count, "test case")}, since their made-up rows would have broken a unique key."
        end

        # DESIGN.md's rewrite-rules: the rule-made rewrites a test disproved.
        def rule_bugs = @payload["rule_bugs"] || []

        def bug(entry)
          how = Words::BUG_STEPS.fetch(entry["step"], "returned different results in a test")
          "#{called(entry)}, #{made_by(entry["rules"])}, #{how}."
        end
      end
    end
  end
end
