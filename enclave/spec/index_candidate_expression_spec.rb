# frozen_string_literal: true

require "pp"
require "quaack/enclave/index_candidate"

# Expression keys, operator classes, and collations (20260922-33). llm-index-ideas
# asks the LLM for them, and existing indexes use them, so the shape holds
# them and index-dedupe can compare them.
RSpec.describe Quaack::Enclave::IndexCandidate, "expression keys, opclasses, and collations" do
  let(:key_column) { Quaack::Enclave::IndexCandidate::KeyColumn }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:sentinel) { "SENTINEL-e4b1d0" }

  def candidate(**overrides)
    described_class.new(table: orders, key: ["customer_id"], sources: [:llm], **overrides)
  end

  def from_ddl(sql) = described_class.from_ddl(sql, sources: [:existing])

  def message_of
    yield
    raise "expected an error"
  rescue ArgumentError => e
    e.full_message(highlight: false)
  end

  describe "KeyColumn" do
    it "takes an expression in place of a name, stored as pg_query deparses it" do
      k = key_column.new(expression: "LOWER( email )")

      expect([k.name, k.expression]).to eq([nil, "lower(email)"])
      expect(k).to eq(key_column.new(expression: "(lower(email))"))
      expect(k).not_to eq(key_column.new(expression: "upper(email)"))
    end

    it "turns an expression that's just a column into that column" do
      expect(key_column.new(expression: "(email)")).to eq(key_column.new(name: "email"))
      expect(key_column.new(expression: %("Email"))).to eq(key_column.new(name: "Email"))
    end

    it "needs exactly one of a name and an expression" do
      expect { key_column.new }.to raise_error(ArgumentError, /name or an expression/)
      expect do
        key_column.new(name: "a", expression: "lower(a)")
      end.to raise_error(ArgumentError, /name or an expression/)
    end

    it "refuses an expression that isn't one expression, or that Postgres never allows in an index" do
      ["a, b", "lower(a) FROM t", "a + $1", "(SELECT 1)", "count(*)", "", 5, :lower].each do |bad|
        expect { key_column.new(expression: bad) }.to raise_error(ArgumentError, /expression/), bad.inspect
      end
    end

    it "takes an opclass and a collation, dropping a pg_catalog prefix" do
      k = key_column.new(name: "email", opclass: %w[pg_catalog text_pattern_ops], collation: "C")

      expect([k.opclass, k.collation]).to eq([["text_pattern_ops"], ["C"]])
      expect(k).to eq(key_column.new(name: "email", opclass: "text_pattern_ops", collation: %w[pg_catalog C]))
      expect(key_column.new(name: "email", collation: "en_US.utf8").collation).to eq(["en_US.utf8"])
      expect(key_column.new(name: "email", opclass: %w[public my_ops]).opclass).to eq(%w[public my_ops])
      expect(k).not_to eq(key_column.new(name: "email"))
      expect([k.opclass, k.collation, k.opclass.first]).to all(be_frozen)
    end

    it "refuses an opclass or collation that isn't a name" do
      [[:opclass, ""], [:opclass, 5], [:collation, []], [:collation, ["a", ""]]].each do |what, bad|
        expect { key_column.new(name: "a", what => bad) }.to raise_error(ArgumentError, /#{what}/), bad.inspect
      end
    end

    it "keeps its SQL helpers private" do
      expect { Quaack::Enclave::IndexKeySql }.to raise_error(NameError, /private constant/)
      expect(key_column.new(name: "a")).not_to respond_to(:column_or_expression)
    end

    it "keeps a reversed key's expression, opclass, and collation" do
      k = key_column.new(expression: "lower(email)", opclass: "text_pattern_ops", collation: "C", direction: :desc)

      expect(k.with(direction: :asc, nulls: :last))
        .to eq(key_column.new(expression: "lower(email)", opclass: "text_pattern_ops", collation: "C"))
    end
  end

  describe "to_ddl and from_ddl" do
    it "renders an expression key with its opclass, collation, and direction" do
      c = candidate(key: [key_column.new(expression: "lower(email)", collation: "C", opclass: "text_pattern_ops",
                                         direction: :desc), "id"], include: ["total"])

      expect(c.to_ddl).to eq(
        %(CREATE INDEX ON public.orders USING btree (lower(email) COLLATE "C" text_pattern_ops DESC, id) ) +
        "INCLUDE (total)"
      )
    end

    it "wraps an expression that isn't a function call in parentheses" do
      expect(candidate(key: [key_column.new(expression: "a + 1")]).to_ddl)
        .to eq("CREATE INDEX ON public.orders USING btree ((a + 1))")
    end

    it "reads what Postgres 18's pg_get_indexdef prints for expressions, opclasses, and collations" do
      {
        "CREATE INDEX i ON public.orders USING btree (lower(email))" =>
          candidate(key: [key_column.new(expression: "lower(email)")]),
        "CREATE INDEX i ON public.orders USING btree (email text_pattern_ops)" =>
          candidate(key: [key_column.new(name: "email", opclass: "text_pattern_ops")]),
        %(CREATE INDEX i ON public.orders USING btree (email COLLATE "C")) =>
          candidate(key: [key_column.new(name: "email", collation: "C")]),
        "CREATE INDEX i ON public.orders USING gin (name gin_trgm_ops)" =>
          candidate(key: [key_column.new(name: "name", opclass: "gin_trgm_ops")], access_method: :gin),
        "CREATE INDEX i ON public.orders USING btree (((total + 1)) DESC)" =>
          candidate(key: [key_column.new(expression: "total + 1", direction: :desc)])
      }.each do |ddl, expected|
        read = from_ddl(ddl)
        expect(read).to eq(expected), ddl
        expect(read.sources).to eq(Set[:existing])
      end
    end

    it "round-trips what to_ddl renders" do
      [
        candidate(key: [key_column.new(expression: "lower(email)", opclass: "text_pattern_ops")]),
        candidate(key: [key_column.new(expression: "(a)::text", collation: %w[public mine]), "b"]),
        candidate(key: [key_column.new(name: "name", opclass: %w[public gin_trgm_ops])], access_method: :gin)
      ].each do |c|
        expect(from_ddl(c.to_ddl)).to eq(c), c.to_ddl
      end
    end

    it "reads DDL written the way the LLM might write it: a parenthesized column and pg_catalog names" do
      expect(from_ddl("CREATE INDEX ON public.orders ((email) pg_catalog.text_pattern_ops)"))
        .to eq(candidate(key: [key_column.new(name: "email", opclass: "text_pattern_ops")]))
      expect(from_ddl('CREATE INDEX ON public.orders (lower(email) COLLATE pg_catalog."C")'))
        .to eq(candidate(key: [key_column.new(expression: "lower(email)", collation: "C")]))
    end

    it "returns nil for an opclass with parameters, which the shape doesn't hold" do
      expect(from_ddl("CREATE INDEX i ON public.orders USING gist (name gist_trgm_ops (siglen='32'))")).to be_nil
    end
  end

  # An expression key can hold a literal, as a predicate can, so it's
  # redacted everywhere a predicate is.
  describe "keeping expression literals out of messages" do
    let(:expr) { "coalesce(note, '#{sentinel}')" }

    it "plants the sentinel where the checks below look for it" do
      c = candidate(key: [key_column.new(expression: expr)])

      expect(c.key.first.expression).to include(sentinel)
      expect(c.to_ddl).to include(sentinel)
    end

    it "redacts the expression in inspect, to_s, and pp, for the key column and the candidate" do
      k = key_column.new(expression: expr, opclass: "text_pattern_ops")
      c = candidate(key: [k])

      [k.inspect, k.to_s, PP.pp(k, +""), c.inspect, c.to_s, PP.pp(c, +"")].each do |shown|
        expect(shown).not_to include(sentinel)
        expect(shown).to include("expression=<redacted>", "text_pattern_ops")
      end
      expect(key_column.new(name: "a").inspect).to include("expression=nil", "name=\"a\"")
    end

    it "hides the expression from pattern matching" do
      c = candidate(key: [key_column.new(expression: expr)])

      expect(c.key.first.deconstruct_keys(nil)).not_to have_key(:expression)
      expect(c.key.first).not_to respond_to(:deconstruct)
      expect((c in { key: [{ expression: String }] })).to be(false)
      expect((c in { key: [{ name: nil, direction: :asc }] })).to be(true)
      begin
        c => { key: [{ name: "x" }] }
      rescue NoMatchingPatternError => e
        expect(e.full_message(highlight: false)).not_to include(sentinel)
      end
    end

    it "leaves it out of construction errors" do
      ["coalesce(note, '#{sentinel}') + $1", "'#{sentinel}' AND AND", "(SELECT '#{sentinel}')"].each do |bad|
        expect(message_of { key_column.new(expression: bad) }).not_to include(sentinel)
      end
      expect(message_of { key_column.new(name: "a", expression: expr) }).not_to include(sentinel)
    end
  end
end
