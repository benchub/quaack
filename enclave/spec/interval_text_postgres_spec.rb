# frozen_string_literal: true

require "quaack/enclave/result_comparator"

# Postgres is the oracle: for every IntervalStyle, IntervalText must read
# each value Postgres prints as the value interval's own equality compares,
# months * 30 + days, in days, times a day's microseconds, plus the time.
# extract gives each field exactly, as numeric.
RSpec.describe Quaack::Enclave::ResultComparator::IntervalText do
  let(:conn) { test_database.connection }

  let(:styles) { %w[postgres postgres_verbose sql_standard iso_8601] }

  # Mixed signs, fractions, big hours, zero, and the infinities, plus a
  # spread of random sums of fields. Each value's text is written in the
  # postgres style, which reads each field's sign on its own.
  def values
    fixed = ["0", "1 day", "24 hours", "-1 day", "1 mon", "30 days", "1 year 2 mons 3 days 04:05:06.789",
             "-1 year -2 mons +3 days -04:05:06.789", "1 day -1 hour", "-1 day +1 hour", "100 hours 0.000001 sec",
             "-0.5 sec", "-1 min -1.5 sec", "2 mons -1 sec", "-1 mon +1 sec", "178000000 years", "2562047788 hours",
             "-2147483648 days", "2147483647 mons", "infinity", "-infinity", "1 year -1 day", "-1 year 1 hour"]
    random = Random.new(20_261_006)
    fixed + Array.new(200) do
      fields = [[-30, 30, "mons"], [-60, 60, "days"], [-100, 100, "hours"]]
      date_and_hours = fields.map { |low, high, unit| "#{random.rand(low..high)} #{unit}" }
      [*date_and_hours, "#{random.rand(-5000..5000)}.#{random.rand(0..999_999)} secs"].join(" ")
    end
  end

  let(:span_sql) do
    <<~SQL
      ((extract(year FROM i) * 12 + extract(month FROM i)) * 30 + extract(day FROM i)) * 86400000000
        + extract(hour FROM i) * 3600000000 + extract(minute FROM i) * 60000000 + extract(microseconds FROM i)
    SQL
  end

  def printed(style, texts)
    conn.transaction do
      conn.exec("SET LOCAL IntervalStyle = #{style}")
      conn.exec_params("SELECT unnest($1::interval[])::text", [PG::TextEncoder::Array.new.encode(texts)]).values.flatten
    end
  end

  it "reads each style's text as the value interval's equality compares" do
    texts = printed("postgres", values)
    finite = texts.reject { it.end_with?("infinity") }
    expected = conn.exec_params("SELECT (#{span_sql.strip})::text FROM unnest($1::interval[]) AS i",
                                [PG::TextEncoder::Array.new.encode(finite)]).values.flatten.map { Integer(it) }

    styles.each do |style|
      read = printed(style, finite).map { described_class.span(it) }

      expect([style, read]).to eq([style, expected])
    end
  end

  it "says two values are equal exactly when Postgres's = does, in every style" do
    texts = printed("postgres", values).sample(80, random: Random.new(7)) + ["1 day", "24:00:00", "1 mon", "30 days"]
    equal = conn.exec_params("SELECT a.i = b.i FROM unnest($1::interval[]) WITH ORDINALITY a(i, n), " \
                             "unnest($1::interval[]) WITH ORDINALITY b(i, m) ORDER BY n, m",
                             [PG::TextEncoder::Array.new.encode(texts)]).values.flatten.map { it == "t" }
    expect(equal.count(true)).to be > texts.size

    styles.each do |style|
      read = printed(style, texts).map { described_class.span(it) }

      expect([style, read.product(read).map { |a, b| a == b }]).to eq([style, equal])
    end
  end
end
