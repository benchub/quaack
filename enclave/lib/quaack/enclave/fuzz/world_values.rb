# frozen_string_literal: true

require "date"
require "json"
require "pg"
require_relative "typical"

module Quaack
  module Enclave
    module Fuzz
      # Values from world knowledge (task 20261012-13): the classes of value
      # that tell rewrites apart and that no query constant is near, per
      # column type, built from the queries' Facts.
      #
      #   world = WorldValues.new(conn, facts)
      #   world.values("text", "code")  # => ["", "   ", " ABC", "ABC ", "abc", "ſam", ...]
      #   world.copies                  # => [4, 5, 6, 19, 20, 21]
      #
      # - Text: the queries' strings (and the column's typical values)
      #   padded with spaces, tabs and newlines, in other cases, with
      #   case-fold oddities (the long s, the Kelvin sign, dotted and dotless
      #   i) and decomposed (NFD); the empty and an all-spaces string; a
      #   multibyte character, and runs of one as long as an integer
      #   constant; and each separator a split_part or LIKE pattern uses,
      #   twice in one string, inside each LIKE pattern too.
      # - Numbers: NaN and both infinities, .5 values either side of 0, a
      #   negative and 0 for a column a query divides by, and the values just
      #   past int4's (or int2's) range when a query casts to it.
      # - Dates and times: the ISO-week and year-end dates, Dec 29 to Jan 3,
      #   around each year the queries name (2024 if none); a Sunday; each
      #   date constant a year either side; both infinities; the first
      #   instants past int4's epoch seconds when a query casts to int; and
      #   DST: the switch hours and summer and winter times, in the zones
      #   the queries name, else FALLBACK_ZONES.
      # - JSON: for each key a query reads, each JSON type: a number, the
      #   same number as a string, 10 against 10.0, JSON null, the key
      #   missing, a bare string against an array holding it, and a number
      #   inside an array.
      # - Arrays: one holding NULL, and the queries' elements repeated and
      #   in another order.
      #
      # copies are how many rows a world may give a table that share a
      # group or a key: each integer constant from 1 to COPIES_MAX, one
      # either side.
      #
      # Values are raw text; Domains casts each to its column's type and
      # keeps the ones it reads. Trust boundary: these are functions of the
      # queries' constants, so they stay in the enclave.
      class WorldValues # rubocop:disable Metrics/ClassLength -- one pool per type, kept together
        FALLBACK_ZONES = %w[America/New_York Europe/London Australia/Sydney].freeze
        COPIES_MAX = 100
        DEFAULT_YEAR = 2024
        YEARS = 3
        STRINGS = 6
        KEYS = 4
        PADS = [" %s", "%s ", "\t%s", "%s\n", " %s "].freeze
        ODDITIES = [[/s/i, "\u017F"], [/k/i, "\u212A"], %w[i ı], %w[I İ]].freeze
        MULTIBYTE = ["é", "日本", "\u{1F600}"].freeze
        HALVES = %w[0.5 -0.5 1.5 -1.5 2.5 -2.5].freeze
        SPECIAL_NUMBERS = %w[NaN Infinity -Infinity].freeze
        EPOCH_PAST = { 32 => ["2038-01-19 03:14:08+00", "1901-12-13 20:45:51+00"] }.freeze

        DST_SQL = <<~SQL
          WITH hours AS (
            SELECT t FROM pg_catalog.generate_series(pg_catalog.make_timestamptz($2::int, 1, 1, 0, 0, 0, 'UTC'),
                                                     pg_catalog.make_timestamptz($2::int, 12, 31, 0, 0, 0, 'UTC'),
                                                     interval '1 hour') AS t
          ), instants AS (
            SELECT h.t OPERATOR(pg_catalog.+) d AS t
            FROM hours h, (VALUES (interval '-1 hour'), (interval '-30 minutes'), (interval '0'),
                                  (interval '30 minutes'), (interval '1 hour')) AS ds (d)
            WHERE pg_catalog.timezone($1::pg_catalog.text, h.t) OPERATOR(pg_catalog.-)
                  pg_catalog.timezone($1::pg_catalog.text, h.t OPERATOR(pg_catalog.-) interval '1 hour')
                  OPERATOR(pg_catalog.<>) interval '1 hour'
            UNION
            SELECT pg_catalog.timezone($1::pg_catalog.text, pg_catalog.make_timestamp($2::int, m, 15, hh, mm, 0))
            FROM (VALUES (1), (7)) AS ms (m), (VALUES (0, 30), (12, 0), (23, 30)) AS times (hh, mm)
          )
          SELECT pg_catalog.to_char(pg_catalog.timezone('UTC', t), 'YYYY-MM-DD HH24:MI:SS') OPERATOR(pg_catalog.||) '+00',
                 pg_catalog.to_char(pg_catalog.timezone($1::pg_catalog.text, t), 'YYYY-MM-DD HH24:MI:SS')
          FROM instants
        SQL

        ZONES_SQL = <<~SQL
          SELECT name FROM pg_catalog.pg_timezone_names
          WHERE name OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[])
            AND (pg_catalog.make_timestamptz($2::int, 7, 1, 12, 0, 0, name) OPERATOR(pg_catalog.-)
                 pg_catalog.make_timestamptz($2::int, 1, 1, 12, 0, 0, name)) OPERATOR(pg_catalog.<>)
                (pg_catalog.make_timestamptz($2::int, 7, 1, 12, 0, 0, 'UTC') OPERATOR(pg_catalog.-)
                 pg_catalog.make_timestamptz($2::int, 1, 1, 12, 0, 0, 'UTC'))
        SQL

        def initialize(conn, facts)
          @conn = conn
          @facts = facts
          @memo = {}
        end

        def copies
          @facts.integers.grep(1..COPIES_MAX).flat_map { [it - 1, it, it + 1] }
                .select(&:positive?).uniq.sort
        end

        def grouped?(name) = @facts.grouped.include?(name)

        # The values for a column of type (format_type's name) named name,
        # with typical its typical values.
        def values(type, name, typical = []) # rubocop:disable Metrics -- one branch per type
          type = type.delete_prefix("pg_catalog.")
          return array(type) if type.end_with?("]")

          case type
          when Typical::TEXT then text(typical)
          when /\A(numeric|double|real)/ then numbers(name) + SPECIAL_NUMBERS + HALVES
          when /\A(smallint|integer|bigint)/ then numbers(name)
          when /\Adate/ then dates
          when /\Atimestamp with time zone/ then dates + epoch_past + dst.fetch(:instants)
          when /\Atimestamp/ then dates + epoch_past + dst.fetch(:walls)
          when /\Ajsonb?\z/ then json
          else []
          end.uniq
        end

        private

        def memo(key) = @memo.fetch(key) { @memo[key] = yield }

        def strings = @facts.strings.first(STRINGS)

        def text(typical)
          memo([:text, typical]) do
            base = (strings + typical).uniq
            ["", "   ", *MULTIBYTE, *base.flat_map { variants(it) }, *runs, *separated]
          end
        end

        def variants(text)
          pads = PADS.map { format(it, text) }
          cases = [text.upcase, text.downcase, text.capitalize, text.swapcase]
          odd = ODDITIES.map { |pattern, with| text.gsub(pattern, with) }
          [*pads, *cases, *odd, text.unicode_normalize(:nfd)] - [text]
        end

        # A multibyte character repeated as many times as each count.
        def runs = copies.map { "é" * it }

        def separated
          @facts.separators.flat_map do |separator|
            ["a#{separator}b#{separator}c", *@facts.like_patterns.map { it.gsub("%", "x#{separator}y").tr("_", "z") }]
          end
        end

        def numbers(name)
          divided = @facts.divided.include?(name) ? %w[-1 0 -2] : []
          past = @facts.int_casts.flat_map { [(2**(it - 1)).to_s, (-(2**(it - 1)) - 1).to_s] }
          divided + past
        end

        def years
          from_dates = @facts.strings.filter_map { it[/\A(\d{4})-\d\d-\d\d/, 1]&.to_i }
          named = (@facts.integers.grep(1900..2200) + from_dates).uniq.first(YEARS)
          named.empty? ? [DEFAULT_YEAR] : named
        end

        def dates
          memo(:dates) do
            year_ends = years.flat_map { |y| [y - 1, y].flat_map { year_end(it) } }
            ["infinity", "-infinity", *year_ends, *sundays, *shifted]
          end
        end

        def year_end(year)
          [*(29..31).map { Date.new(year, 12, it) }, *(1..3).map { Date.new(year + 1, 1, it) }].map(&:iso8601)
        end

        def date_constants
          @facts.strings.filter_map { date(it[0, 10]) if it.match?(/\A\d{4}-\d\d-\d\d/) }
        end

        def date(text)
          Date.iso8601(text)
        rescue Date::Error
          nil
        end

        def sundays
          [Date.new(DEFAULT_YEAR, 3, 3), *date_constants.map { it + ((7 - it.wday) % 7) }].map(&:iso8601)
        end

        def shifted = date_constants.flat_map { [it.prev_year, it.next_year] }.map(&:iso8601)

        def epoch_past = @facts.int_casts.include?(32) ? EPOCH_PAST.fetch(32) : []

        # DST, in each zone: the hours around each switch in the default
        # year, and the start, middle and end of a day in each half of it,
        # as UTC instants and as the zone's wall-clock times.
        def dst
          memo(:dst) do
            rows = zones.flat_map { @conn.exec_params(DST_SQL, [it, DEFAULT_YEAR]).values }
            instants = rows.map(&:first).uniq
            { instants:, walls: (rows.map(&:last) + instants.map { it.delete_suffix("+00") }).uniq }
          end
        end

        # The zones the queries name that keep DST, else FALLBACK_ZONES.
        def zones
          named = @conn.exec_params(ZONES_SQL, [PG::TextEncoder::Array.new.encode(@facts.strings), DEFAULT_YEAR])
                       .column_values(0)
          named.empty? ? FALLBACK_ZONES : named
        end

        def json
          memo(:json) do
            keys = @facts.json_keys.first(KEYS)
            keys.flat_map { |key| [{ key => nil }, *scalars.flat_map { json_forms(key, it) }] }
                .map { JSON.generate(it) } + ["{}"]
          end
        end

        # The numbers and strings a JSON key may hold: the queries' number
        # constants, one either side of each integer, their strings, and
        # the JSON constants' leaves, and the keys too, since ? matches a
        # string in an array as well as a key.
        def scalars = json_numbers.first(9) + json_texts.first(STRINGS)

        def json_numbers
          from_text = @facts.strings.filter_map { Integer(it, exception: false) }
          ((@facts.integers + from_text).flat_map { [it - 1, it, it + 1] } + @facts.json_leaves.grep(Numeric)).uniq
        end

        def json_texts
          (@facts.json_leaves.grep(String) + @facts.json_keys + strings.reject { it.start_with?("{", "[") }).uniq
        end

        def json_forms(key, value)
          return [{ key => value }, { key => [value] }] if value.is_a?(String)

          forms = [{ key => value }, { key => value.to_s }, { key => [value] }, { key => [value.to_s] }]
          value.is_a?(Integer) ? forms + [{ key => value.to_f }] : forms
        end

        def array(_type)
          elements = (strings + @facts.integers.map(&:to_s)).first(3)
          first, second = elements
          lists = [[nil], [], [first, nil], [nil, first], [first], [first, first]]
          lists += [[first, second], [second, first], [first, first, second], [first, second, second]] if second
          lists.uniq.map { PG::TextEncoder::Array.new.encode(it) }
        end
      end
    end
  end
end
