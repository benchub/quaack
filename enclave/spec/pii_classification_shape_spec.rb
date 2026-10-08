# frozen_string_literal: true

require "quaack/enclave/pii_classification"

# DESIGN.md's classify checks the shape of every statistic it lets out, so a
# value the catalog read got wrong, or that a function or type planted on
# the search_path wrote, is refused rather than sent. A pg_stats row's
# null_frac and MCV frequencies are numbers in 0..1, its n_distinct a
# number, and its correlation a number in -1..1. Each may be null, as for
# a column with no pg_stats row. A statistics
# object's MCV frequencies are numbers in 0..1, its MCV null flags
# booleans, its kinds some of d, f, m, and e, and its n_distinct and
# dependencies Postgres's own text for them: numbers keyed by column
# numbers. Anything else fails classify with statistics_bad_shape, and
# the error names only the table and the field, never the value.
RSpec.describe Quaack::Enclave::PiiClassification do
  let(:sentinel) { "sentinel#{SecureRandom.hex(6)}" }
  let(:columns) do
    [["status", false, true], ["kind", false, true]].map do |name, pii, low|
      { "schema" => "public", "table" => "t", "column" => name, "pii" => pii, "low_cardinality" => low }
    end
  end
  let(:row) do
    { "n_distinct" => 3.0, "null_frac" => 0.0, "correlation" => 0.5, "most_common_vals" => %w[a b],
      "most_common_freqs" => [0.5, 0.4] }
  end
  let(:object) do
    { "schema" => "public", "name" => "s", "definition" => "CREATE STATISTICS public.s ON status, kind FROM public.t",
      "kinds" => %w[d f m], "n_distinct" => '{"1, 2": 6, "1, -1": 15}', "dependencies" => '{"1 => 2": 1.000000}',
      "most_common_vals" => [%w[a b]], "most_common_val_nulls" => [[false, false]], "most_common_freqs" => [0.5],
      "most_common_base_freqs" => [0.25] }
  end

  def outbound(row: self.row, index_row: self.row, object: self.object)
    table = { "schema" => "public", "name" => "t", "column_names" => %w[status kind],
              "columns" => { "status" => row, "kind" => self.row },
              "indexes" => [{ "name" => "i", "definition" => "CREATE INDEX i ON public.t (lower(status))",
                              "columns" => { "lower" => index_row } }],
              "extended_statistics" => [object] }
    described_class.outbound({ "tables" => [table] }, columns)["tables"].first
  end

  def error_of
    yield
    raise "expected an error"
  rescue Quaack::Enclave::PiiClassification::Error => e
    e
  end

  it "lets well-shaped statistics out, as the baseline" do
    table = outbound
    expect(table["columns"].first).to include("null_frac" => 0.0, "most_common_freqs" => [0.5, 0.4])
    expect(table["extended_statistics"].first).to include("n_distinct" => object["n_distinct"],
                                                          "most_common_base_freqs" => [0.25])
  end

  it "lets nulls out where Postgres has none" do
    blank = row.merge("correlation" => nil, "most_common_freqs" => nil, "most_common_vals" => nil)
    none = object.merge(%w[n_distinct dependencies most_common_vals most_common_val_nulls most_common_freqs
                           most_common_base_freqs].to_h { [it, nil] })

    expect(outbound(row: blank, object: none)["extended_statistics"].first["most_common_freqs"]).to be_nil
  end

  {
    "a string in most_common_freqs" => -> { { "most_common_freqs" => [0.5, sentinel] } },
    "a frequency over 1" => -> { { "most_common_freqs" => [1.5] } },
    "a negative frequency" => -> { { "most_common_freqs" => [-0.1] } },
    "a nested array in most_common_freqs" => -> { { "most_common_freqs" => [[0.5]] } },
    "a string for most_common_freqs" => -> { { "most_common_freqs" => sentinel } },
    "a string null_frac" => -> { { "null_frac" => sentinel } },
    "a null_frac over 1" => -> { { "null_frac" => 2.0 } },
    "a string n_distinct" => -> { { "n_distinct" => sentinel } },
    "a string correlation" => -> { { "correlation" => sentinel } },
    "a correlation over 1" => -> { { "correlation" => 1.5 } }
  }.each do |name, change|
    it "refuses a pg_stats row with #{name}, in a column or an index" do
      bad = row.merge(instance_exec(&change))

      [outbound_error(row: bad), outbound_error(index_row: bad)].each do |error|
        expect(error.rule).to eq("statistics_bad_shape")
        expect(error.message).not_to include(sentinel)
      end
    end
  end

  {
    "a string in most_common_freqs" => -> { { "most_common_freqs" => [sentinel] } },
    "a string in most_common_base_freqs" => -> { { "most_common_base_freqs" => [0.1, sentinel] } },
    "a frequency over 1" => -> { { "most_common_base_freqs" => [1.5] } },
    "an object for most_common_freqs" => -> { { "most_common_freqs" => { sentinel => 1 } } },
    "a string in most_common_val_nulls" => -> { { "most_common_val_nulls" => [[sentinel, false]] } },
    "a flat most_common_val_nulls" => -> { { "most_common_val_nulls" => [false] } },
    "more null-flag lists than MCV items" => lambda {
      { "most_common_vals" => [[sentinel, "b"]], "most_common_val_nulls" => [[false, false], [false, false]] }
    },
    "fewer null-flag lists than MCV items" => lambda {
      { "most_common_vals" => [[sentinel, "b"], %w[c d]], "most_common_val_nulls" => [[false, false]] }
    },
    "null-flag lists but no MCV items" => -> { { "most_common_vals" => nil } },
    "an unknown kind" => -> { { "kinds" => [sentinel] } },
    "kinds that aren't a list" => -> { { "kinds" => sentinel } },
    "n_distinct that isn't Postgres's text" => -> { { "n_distinct" => "{#{sentinel}}" } },
    "n_distinct keyed by a name" => -> { { "n_distinct" => "{\"#{sentinel}, 2\": 6}" } },
    "n_distinct with a string count" => -> { { "n_distinct" => "{\"1, 2\": \"#{sentinel}\"}" } },
    "a number for n_distinct" => -> { { "n_distinct" => 6 } },
    "n_distinct keyed by a five-digit column number" => -> { { "n_distinct" => '{"12345, 2": 6}' } },
    "n_distinct with an 11-digit count" => -> { { "n_distinct" => '{"1, 2": 12345678901}' } },
    "dependencies on a five-digit column number" => -> { { "dependencies" => '{"1 => -12345": 1.000000}' } },
    "dependencies with an 11-digit degree" => -> { { "dependencies" => '{"1 => 2": 12345678901.0}' } },
    "dependencies with an 11-digit fraction" => -> { { "dependencies" => '{"1 => 2": 0.12345678901}' } },
    "dependencies that aren't Postgres's text" => -> { { "dependencies" => sentinel } },
    "dependencies keyed by a name" => -> { { "dependencies" => "{\"1 => #{sentinel}\": 1.000000}" } }
  }.each do |name, change|
    it "refuses a statistics object with #{name}" do
      error = outbound_error(object: object.merge(instance_exec(&change)))

      expect(error.rule).to eq("statistics_bad_shape")
      expect(error.message).not_to include(sentinel)
    end
  end

  it "lets one null-flag list per MCV item out" do
    nulls = [[false, true], [true, false]]
    two = object.merge("most_common_vals" => [%w[a b], %w[c d]], "most_common_val_nulls" => nulls,
                       "most_common_freqs" => [0.5, 0.25], "most_common_base_freqs" => [0.25, 0.1])

    expect(outbound(object: two)["extended_statistics"].first["most_common_val_nulls"]).to eq(nulls)
  end

  # Column numbers run to 1600, and Postgres writes a count as an int: four
  # digits and ten.
  it "lets the widest column numbers and counts out" do
    wide = object.merge("n_distinct" => '{"1600, -8": 2147483647}', "dependencies" => '{"1600, -8 => 1599": 1.000000}')

    expect(outbound(object: wide)["extended_statistics"].first)
      .to include("n_distinct" => wide["n_distinct"], "dependencies" => wide["dependencies"])
  end

  def outbound_error(**) = error_of { outbound(**) }
end
