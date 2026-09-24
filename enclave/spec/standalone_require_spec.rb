# frozen_string_literal: true

# Each file under lib/ must work when it's the only one a caller requires, so
# a missing require can't hide behind whatever another file or spec happened
# to load first. Each check runs in a fresh Ruby process.
RSpec.describe "requiring one enclave file on its own" do
  let(:lib) { File.join(GEM_ROOT, "lib") }

  # Ruby that uses what the file defines, for the files other code builds on.
  # A file that isn't listed only has to load.
  let(:uses) do
    table = 'Quaack::Enclave::TableName.new(schema: "public", name: "orders")'
    candidate = "Quaack::Enclave::IndexCandidate.new(table: #{table}, key: ['a'], include: ['b'], " \
                "predicate: 'a > 0', unique: true, sources: [:parse])"
    {
      "quaack/enclave/table_name" => "puts #{table}",
      "quaack/enclave/egress" => 'print Quaack::Enclave::Egress.serialize(type: :error, step: "3f")',
      "quaack/enclave/store" =>
        'base = File.join(ENV.fetch("TMPDIR", "/tmp"), "quaack-standalone-" + Process.pid.to_s); ' \
        "s = Quaack::Enclave::Store.create(base:); s.write(:inputs, [1]); print s.read(:inputs); " \
        "s.teardown; Dir.rmdir(base)",
      "quaack/enclave/index_candidate" =>
        "puts #{candidate}.to_ddl; " \
        "puts Quaack::Enclave::IndexCandidate.from_ddl('CREATE INDEX i ON public.o USING btree (a)', sources: [:x])",
      "quaack/enclave/statistics" =>
        "puts Quaack::Enclave::Statistics.new(tables: [Quaack::Enclave::TableStatistics.new(name: #{table}, " \
        "reltuples: 1, column_names: ['a', 'b'], indexes: { 'i' => #{candidate} }, " \
        "columns: { 'a' => Quaack::Enclave::ColumnStatistics.new(n_distinct: 1, null_frac: 0, correlation: nil) })])" \
        ".table(#{table}).distinct_count('a')"
    }
  end

  let(:features) do
    Dir.glob("**/*.rb", base: lib).map { |f| f.delete_suffix(".rb") }.sort
  end

  it "covers every file, including the ones other code builds on" do
    expect(features).to include(*uses.keys)
  end

  it "loads each file, and each listed file works, with nothing else required first" do
    features.each do |feature|
      out, err, status = run_ruby("-I", lib, "-e", "require #{feature.inspect}; #{uses.fetch(feature, "")}")

      expect(status).to be_success, "#{feature} failed on its own:\n#{err}"
      expect(out).not_to be_empty, "#{feature} printed nothing" if uses.key?(feature)
    end
  end
end
