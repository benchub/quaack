# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The fate of a rewrite that passed every test but wasn't ranked
      # (not_better), worded by which way minimax's verdicts say it fell
      # short: under a 5% gain on the slow values, or over 5% more blocks on
      # some set. The two are told apart by the labels' verdicts in the
      # payload; with none to read, or a mix, one sentence covers both.
      module NotBetterFate
        # The enclave's Minimax::PERCENT. The driver can't load the enclave
        # gem, and protocol doesn't carry it.
        PERCENT = 5
        LEAD = "It passed every test, but on the real data it"
        TAIL = "so QUAACK didn't rank it."
        SMALL_GAIN = "#{LEAD} was less than a %<percent>d%% improvement, #{TAIL}".freeze
        REGRESSED = "#{LEAD} read over %<percent>d%% more blocks on some values, #{TAIL}".freeze
        EITHER = "#{LEAD} was either less than a %<percent>d%% improvement on the slow values or over " \
                 "%<percent>d%% more blocks on some others, #{TAIL}".freeze

        # The sentence for a not_better rewrite, as a format string.
        def not_better_text(entry)
          verdicts = not_better_verdicts(entry["rewrite"])
          return EITHER if verdicts.empty?

          { [true] => REGRESSED, [false] => SMALL_GAIN }.fetch(verdicts.map { it.value?("worse") }.uniq, EITHER)
        end

        # The verdicts of each of a rewrite's not_better labels, or none if
        # any label's are missing.
        def not_better_verdicts(rewrite)
          labels = excluded.select { |label, why| why == "not_better" && label.split(":").first == rewrite }.keys
          found = labels.map { measured(it)&.fetch("verdicts", nil) }
          found.all? ? found : []
        end
      end
    end
  end
end
