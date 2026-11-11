# frozen_string_literal: true

require "quaack/enclave/redaction"
require "quaack/enclave/constant_value"
require "quaack/enclave/fuzz/tree"
require "quaack/enclave/fuzz/facts"
require "quaack/enclave/fuzz/reach"
require "quaack/enclave/result_comparison"
require "quaack/enclave/result_comparison/pick_checks"

# Task 20261110-12: each analysis that reads constants from a parse tree
# answers the same on the $n form, with its Binding, as on the literal
# form, and the same as before on literal SQL.
RSpec.describe Quaack::Enclave::ConstantValue do
  # The literal form and the $n form of one query, each $n typed as
  # Redaction::Literal.of types its literal.
  def forms(literal, placeholders, values)
    map = values.each_with_index.to_h do |(value, type), i|
      ["$#{i + 1}", { "value" => value, "type" => type }]
    end
    [literal, placeholders, Quaack::Enclave::Redaction.binding(placeholders, map)]
  end

  def tree(sql) = PgQuery.parse(sql).tree.to_h

  let(:pair) do
    forms("SELECT o.note FROM public.orders o WHERE o.total * 1.5 > 3 AND o.note LIKE 'a@%' " \
          "AND split_part(o.note, '-', 2) = 'x' AND o.flag = true AND o.bits = B'101' AND o.big = 9000000000 " \
          "AND o.data ->> 'k' = '{\"j\": 1}' AND o.gone IS DISTINCT FROM NULL",
          "SELECT o.note FROM public.orders o WHERE o.total * $1 > $2 AND o.note LIKE $3 " \
          "AND split_part(o.note, $4, $5) = $6 AND o.flag = $7 AND o.bits = $8 AND o.big = $9 " \
          "AND o.data ->> $10 = $11 AND o.gone IS DISTINCT FROM $12",
          [%w[1.5 numeric], %w[3 integer], %w[a@% unknown], %w[- unknown], %w[2 integer], %w[x unknown],
           %w[true boolean], ["b101", "bit varying"], %w[9000000000 bigint], %w[k unknown], ['{"j": 1}', "unknown"],
           [nil, "unknown"]])
  end

  describe "Fuzz::Tree.constants" do
    it "finds the same constants on the $n form" do
      literal, placeholders, binding = pair
      found = Quaack::Enclave::Fuzz::Tree.constants(tree(placeholders), binding:)

      expect(found).to eq(Quaack::Enclave::Fuzz::Tree.constants(tree(literal)))
      expect(found).to include("1.5", "3", "a@%", "9000000000")
    end
  end

  describe "Fuzz::Facts" do
    let(:fields) { %i[strings integers numbers separators like_patterns json_keys json_leaves combinations] }

    def facts(trees, **) = Quaack::Enclave::Fuzz::Facts.new(trees, **)

    it "reads the same facts on the $n form" do
      literal, placeholders, binding = pair
      on_literal = facts([tree(literal)])
      on_placeholders = facts([tree(placeholders)], binding:)

      expect(fields.to_h { [it, on_placeholders.send(it)] }).to eq(fields.to_h { [it, on_literal.send(it)] })
      expect(on_placeholders.combinations.map { [it.column, it.constant, it.compared] }).to eq([%w[total 1.5 3]])
      expect(on_placeholders.separators).to include("@", "-")
      expect(on_placeholders.json_keys).to include("k", "j")
    end
  end

  describe "Fuzz::Reach.threshold_bound?" do
    it "sees a $n compared with an aggregate as a threshold" do
      literal, placeholders, binding = forms("SELECT o.note FROM public.orders o GROUP BY o.note HAVING count(*) > 200",
                                             "SELECT o.note FROM public.orders o GROUP BY o.note HAVING count(*) > $1",
                                             [%w[200 integer]])

      expect(Quaack::Enclave::Fuzz::Reach.worst_case?(literal)).to be(true)
      expect(Quaack::Enclave::Fuzz::Reach.worst_case?(placeholders, binding)).to be(true)
    end

    it "sees a $n compared with a column fed by an aggregate" do
      sql = "SELECT t.k FROM (SELECT count(*) AS k FROM public.orders) t WHERE t.k > %s"
      _, placeholders, binding = forms(format(sql, "2"), format(sql, "$1"), [%w[2 integer]])

      expect(Quaack::Enclave::Fuzz::Reach.worst_case?(placeholders, binding)).to be(true)
    end
  end

  describe "ResultComparison.offset_value" do
    def offset(sql) = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.limit_offset

    it "reads a $n's OFFSET as its integer" do
      literal, placeholders, binding = forms("SELECT 1 LIMIT 2 OFFSET 3", "SELECT 1 LIMIT $1 OFFSET $2",
                                             [%w[2 integer], %w[3 integer]])

      expect(Quaack::Enclave::ResultComparison.offset_value(offset(literal))).to eq(3)
      expect(Quaack::Enclave::ResultComparison.offset_value(offset(placeholders), binding)).to eq(3)
    end

    it "reads a NULL $n as 0 and an untyped one as not an integer" do
      _, placeholders, binding = forms("SELECT 1 OFFSET NULL", "SELECT 1 OFFSET $1", [[nil, "unknown"]])
      _, text, text_binding = forms("SELECT 1 OFFSET '3'", "SELECT 1 OFFSET $1", [%w[3 unknown]])

      expect(Quaack::Enclave::ResultComparison.offset_value(offset(placeholders), binding)).to eq(0)
      expect(Quaack::Enclave::ResultComparison.offset_value(offset(text), text_binding)).to be_nil
    end

    it "still reads a $n with no binding as not a constant" do
      expect(Quaack::Enclave::ResultComparison.offset_value(offset("SELECT 1 OFFSET $1"))).to be_nil
    end
  end

  describe "ResultComparison::PickChecks.resolved" do
    def select(sql) = tree(sql)[:stmts].first[:stmt][:select_stmt]

    it "resolves an ORDER BY position written as a $n to the same output column" do
      literal, placeholders, binding = forms("SELECT o.note, o.total FROM public.orders o ORDER BY 2",
                                             "SELECT o.note, o.total FROM public.orders o ORDER BY $1",
                                             [%w[2 integer]])
      checks = Quaack::Enclave::ResultComparison::PickChecks
      resolved = lambda { |sql, *rest|
        checks.resolved(select(sql), select(sql)[:sort_clause].first[:sort_by][:node], *rest)
      }

      expect(resolved.call(placeholders, binding)).to eq(resolved.call(literal))
      expect(resolved.call(literal).dig(:column_ref, :fields).last.dig(:string, :sval)).to eq("total")
    end
  end

  # 20261110-12's review: a negative number, and a $n past the binding's end.
  describe "edge values" do
    it "reads a negative integer and a negative numeric as the literals do" do
      literal, placeholders, binding = forms("SELECT 1 FROM public.orders o WHERE o.total * -1.5 > -3",
                                             "SELECT 1 FROM public.orders o WHERE o.total * $1 > $2",
                                             [%w[-1.5 numeric], %w[-3 integer]])
      facts = ->(sql, **opts) { Quaack::Enclave::Fuzz::Facts.new([tree(sql)], **opts) }

      expect(Quaack::Enclave::Fuzz::Tree.constants(tree(placeholders), binding:)).to eq(%w[1 -1.5 -3])
      expect(facts.call(placeholders, binding:).combinations).to eq(facts.call(literal).combinations)
      expect(facts.call(placeholders, binding:).integers).to eq([1, -3])
    end

    it "reads a $n past the binding's end as no constant" do
      binding = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT 1", types: ["integer"], values: ["7"])
      node = ->(sql) { PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.limit_offset }

      expect(described_class.from_hash(tree("SELECT 1 OFFSET $2")[:stmts].first[:stmt][:select_stmt][:limit_offset],
                                       binding)).to be_nil
      expect(described_class.from_node(node.call("SELECT 1 OFFSET $2"), binding)).to be_nil
      expect(described_class.from_node(node.call("SELECT 1 OFFSET $1"), binding).ival.ival).to eq(7)
    end
  end
end
