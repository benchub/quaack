# frozen_string_literal: true

# The enclave does everything that touches a database, so its specs are the
# main users of the test database harness. This proves the harness works
# from this suite, and that HypoPG does what index-search needs: a hypothetical
# index shows up in a plain EXPLAIN.
RSpec.describe "the test database" do
  it "lets a test create a hypothetical index and see the planner use it" do
    conn = test_database.connection
    conn.exec("CREATE EXTENSION hypopg")
    index = conn.exec("SELECT indexname FROM hypopg_create_index('CREATE INDEX ON orders (total_cents)')")
                .getvalue(0, 0)
    plan = conn.exec("EXPLAIN (FORMAT JSON) SELECT * FROM orders WHERE total_cents = 1234").getvalue(0, 0)

    expect(index).to match(/\A<\d+>btree_orders_total_cents\z/)
    expect(JSON.parse(plan).dig(0, "Plan", "Index Name")).to eq(index)
  end
end
