# frozen_string_literal: true

require "date"
require "securerandom"

module LeakCheck
  # One set of made-up production values, one for each position a real value
  # can take. Every token is "sentinel" and 12 random hex digits, so it can't
  # show up by chance, and a grep for "sentinel" finds it. No two sets, in
  # one spec process, share a needle.
  #
  #   text         "sentinel1a2b3c4d5e6f-text", for a text literal or a text column.
  #   word         "sentinel0f9e8d7c6b5a", lowercase letters and digits only, so it's
  #                a valid identifier unquoted, and has no LIKE wildcard.
  #   number       a nine-digit Integer, which fits a Postgres integer.
  #   date         a Date before 1900, far from any date QUAACK writes itself.
  #   json         a JSON object's text, {"note": "sentinel...-json"}, written the
  #                way Postgres writes jsonb back.
  #   like         a LIKE pattern, "sentinel...%". like_prefix is the part a
  #                matching value starts with.
  #
  # needles maps each name to the text the scanner looks for: the token in
  # it, or the value itself. extra: adds fixed values under their own names,
  # such as literals baked into a fixture file.
  class Sentinels
    # Shorter fixed values could turn up in output by chance.
    MIN_EXTRA = 9
    # The needles every set has, in order.
    KINDS = %i[text word number date json like].freeze
    # How many days a date sentinel is drawn from.
    DAYS = 290_000

    @used = Set.new
    class << self
      # A needle no set in this process has used yet.
      def claim
        needle = yield until needle && @used.add?(needle)
        needle
      end

      # The nth day a date sentinel can be, for index in 0...DAYS. It counts in
      # the Gregorian calendar all the way back, as Postgres does. Ruby's
      # default switches to the Julian calendar before 1582, which has leap
      # days, such as 1100-02-29, that Postgres refuses.
      def day(index) = Date.new(1100, 1, 1, Date::GREGORIAN) + index
    end

    attr_reader :number, :date, :needles

    def initialize(extra: {})
      @tokens = %i[text word json like].to_h { [it, token] }
      @number = Sentinels.claim { SecureRandom.random_number(100_000_000..999_999_999) }
      @date = Sentinels.claim { Sentinels.day(SecureRandom.random_number(DAYS)) }
      @needles = { **@tokens, number: number.to_s, date: date.iso8601 }.slice(*KINDS).merge(fixed(extra)).freeze
    end

    def text = "#{@tokens[:text]}-text"
    def word = @tokens[:word]
    def json = %({"note": "#{@tokens[:json]}-json"})
    def like_prefix = @tokens[:like]
    def like = "#{like_prefix}%"

    private

    def token = self.class.claim { "sentinel#{SecureRandom.hex(6)}" }

    def fixed(extra)
      extra.to_h do |name, value|
        value = value.to_s
        if value.size < MIN_EXTRA
          raise ArgumentError, "the fixed sentinel #{name} is too short, under #{MIN_EXTRA} characters"
        end

        [name.to_sym, value]
      end
    end
  end
end
