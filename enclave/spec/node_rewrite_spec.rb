# frozen_string_literal: true

require "quaack/enclave/node_rewrite"

RSpec.describe Quaack::Enclave::NodeRewrite do
  def tree(sql) = PgQuery.parse(sql).tree

  def column(name) = PgQuery.parse("SELECT #{name}").tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val

  def column_name(node) = node.column_ref && node.column_ref.fields.last.string.sval

  def column_names(tree)
    names = []
    described_class.each(tree) do |node|
      names << column_name(node) if node.column_ref
      nil
    end
    names
  end

  it "yields every node, in field order, through lists, messages, and single fields" do
    sql = "WITH w AS (SELECT a FROM t) SELECT b, f(c) FROM w WHERE d = (SELECT e) ORDER BY g"
    # SelectStmt's with_clause is its last field, so the CTE comes last.
    expect(column_names(tree(sql))).to eq(%w[b c d e g a])
  end

  it "puts what the block returns in the node's place, in a list and in a single field" do
    t = tree("SELECT a, b FROM t WHERE a = 1")
    described_class.each(t) { |node| column("z") if column_name(node) == "a" }
    expect(PgQuery.deparse(t)).to eq("SELECT z, b FROM t WHERE z = 1")
  end

  it "doesn't walk into a node it swapped, or into the new one" do
    t = tree("SELECT f(a)")
    seen = []
    described_class.each(t) do |node|
      seen << node.node
      column("g(a)") if node.func_call && node.func_call.funcname.last.string.sval == "f"
    end
    expect(seen).to eq(%i[select_stmt res_target func_call])
    expect(PgQuery.deparse(t)).to eq("SELECT g(a)")
  end
end
