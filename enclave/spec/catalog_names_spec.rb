# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "support/catalog_names"

# Task 20260930-14: the enclave's SQL names every catalog relation,
# function, operator, and type with its schema, so nothing planted ahead of
# pg_catalog on the search_path can change what it reads. CatalogNames
# says how the SQL is found and what's flagged.
RSpec.describe "catalog names in the enclave's SQL" do
  root = File.join(GEM_ROOT, "lib")

  # The files whose SQL isn't qualified yet, arena reads and some racetrack
  # reads, for task
  # 20261007-9. The list may only shrink: a file on it with nothing left
  # to qualify fails, as does a file off it with something to qualify, or
  # a file that CatalogNames::NOT_YET_QUALIFIED_AT_START, its first form,
  # doesn't have.
  not_yet_qualified = %w[
    quaack/enclave/arena.rb
    quaack/enclave/arena_runner/deferred.rb
    quaack/enclave/arena_runner/pipeline.rb
    quaack/enclave/arena_runner/sequences.rb
    quaack/enclave/arena_schema.rb
    quaack/enclave/arena_schema/domain_checks.rb
    quaack/enclave/arena_schema/unique_indexes.rb
    quaack/enclave/clock_defaults.rb
    quaack/enclave/counterexamples/evaluated.rb
    quaack/enclave/denormalized_fixture.rb
    quaack/enclave/insert_check.rb
    quaack/enclave/insert_clock_words.rb
    quaack/enclave/insert_values.rb
    quaack/enclave/rewrite_rules/existence_in_flip.rb
    quaack/enclave/scenarios/ties.rb
    quaack/enclave/scenarios/types.rb
    quaack/enclave/scenarios/values.rb
    quaack/enclave/value_pools.rb
  ].freeze

  # The source scan, and every loaded constant's SQL, which finds SQL a
  # constant builds from others.
  let(:found) do
    Dir.glob("**/*.rb", base: root).sort.each { require File.join(root, it) }
    CatalogNames.scan(root).merge(CatalogNames.loaded(Quaack::Enclave, root)) { |_, a, b| a + b }
  end

  it "finds no unqualified catalog name in a file that's off the list" do
    expect(found.except(*not_yet_qualified)).to eq({})
  end

  it "finds one in every file on the list, so a qualified file comes off it" do
    expect(not_yet_qualified - found.keys).to eq([])
  end

  it "keeps the list within the files it started with, so it never grows" do
    expect(CatalogNames.added(not_yet_qualified)).to eq([])
  end

  it "names a file the list gains that it didn't start with, and none it already had" do
    grown = [*not_yet_qualified.drop(1), "quaack/enclave/run_server_check.rb", not_yet_qualified.first]

    expect(CatalogNames.added(grown)).to eq(["quaack/enclave/run_server_check.rb"])
  end

  it "finds the enclave's SQL, and every SKIP entry still matches a string" do
    sites = CatalogNames::Source.sites(root).values.flatten
    expect(sites.size).to be > 150
    skipped = sites.reject(&:parse).map { |site| CatalogNames::SKIP.keys.find { |file, start| site.file == file && site.text.start_with?(start) } }
    expect(skipped.uniq).to match_array(CatalogNames::SKIP.keys)
  end

  describe "the scan itself" do
    let(:dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(dir) }

    def scan(source)
      File.write(File.join(dir, "x.rb"), source)
      CatalogNames.scan(dir).fetch("x.rb", [])
    end

    {
      "a pg_ relation" => ["SELECT 1 FROM pg_class", "relation pg_class"],
      "a function" => ["SELECT count(*) FROM pg_catalog.pg_class", "function count"],
      "an operator" => ["SELECT 1 WHERE 1 = 2", "operator ="],
      "IN" => ["SELECT 1 WHERE 1 IN (2)", "operator ="],
      "LIKE" => ["SELECT 1 WHERE 'a' LIKE 'b'", "operator ~~"],
      "IS DISTINCT FROM" => ["SELECT 1 IS DISTINCT FROM 2", "operator ="],
      "NULLIF" => ["SELECT NULLIF(1, 2)", "operator ="],
      "an IN sublink" => ["SELECT 1 WHERE 1 IN (SELECT 2)", "operator ="],
      "ORDER BY USING" => ["SELECT 1 ORDER BY 1 USING <", "operator <"],
      "a simple CASE" => ["SELECT CASE 1 WHEN 2 THEN 3 END", "simple case"],
      "a cast" => ["SELECT 'a'::text", "type text"]
    }.each do |what, (sql, flagged)|
      it "flags #{what} with no schema, and not with one" do
        qualified = sql.sub("pg_class", "pg_catalog.pg_class").sub("count(", "pg_catalog.count(")
                       .sub(/ (=|~~|<) /, ' OPERATOR(pg_catalog.\1) ').sub("::text", "::pg_catalog.text")
        expect(scan(%(A = "#{sql}"\n))).to eq(["line 1: #{flagged}"])
        expect(scan(%(A = "#{qualified}"\n))).to eq([]) unless what.match?(/IN|LIKE|DISTINCT|NULLIF|USING|CASE/)
      end
    end

    it "reads heredocs, inlines a constant's string, and tries stand-ins for other interpolations" do
      source = <<~RUBY
        WHERE_SQL = "pg_catalog.pg_class c WHERE c.oid = 1"
        A = <<~SQL
          EXPLAIN (FORMAT JSON) \#{sql}
        SQL
        B = "SELECT 1 FROM \#{WHERE_SQL}"
      RUBY
      expect(scan(source)).to eq(["line 5: operator ="])
    end

    it "flags a loaded constant built from others, which the source scan sees only in pieces" do
      File.write(File.join(dir, "built.rb"), <<~RUBY)
        module QuaackCatalogNamesBuilt
          BASE = "SELECT 1 FROM pg_catalog.pg_class c ORDER BY 1"
          BUILT = BASE.sub("ORDER BY", "WHERE c.oid = 1 ORDER BY")
          def self.constants(*) = raise("a module's own constants method isn't called")
        end
      RUBY
      require File.join(dir, "built.rb")

      expect(CatalogNames.loaded(QuaackCatalogNamesBuilt, dir)).to eq("built.rb" => ["BUILT, line 3: operator ="])
    end

    it "refuses SQL that parses with no stand-in and isn't on SKIP" do
      expect { scan(%(A = "SELECT \#{a} \#{b} FROM FROM"\n)) }.to raise_error(/isn't on SKIP/)
    end
  end
end
