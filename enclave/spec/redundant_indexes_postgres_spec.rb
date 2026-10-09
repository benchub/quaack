# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/steps/redundant_indexes"
require "quaack/enclave/store"

# Task 20261009-8: an existing index is suggested for dropping only if a
# label's new index makes it truly redundant under the strict rule
# (RedundantIndexes), read from a real catalog, with its production
# idx_scan. Each negative case differs from a positive one in one fact.
RSpec.describe Quaack::Enclave::Steps::RedundantIndexes do
  let(:conn) { test_database.connection }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }
  let(:table) { Quaack::Enclave::TableName.new(schema: "public", name: "rt") }
  let(:sentinel) { "QSENTINEL_PRED_8842" }

  around do |example|
    Dir.mktmpdir("quaack-redundant") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  before do
    conn.exec(<<~SQL)
      DROP TABLE IF EXISTS rt;
      CREATE TABLE rt (id int PRIMARY KEY, a int, b int, c int, d int, e int, f int, g int, h int, k int, m int,
                       n int, p int, q int, r int, s int, t int, note text, flag boolean, status text, x int, u int, ws varchar);
      INSERT INTO rt SELECT i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, i, 'n' || i, i % 2 = 0, 'open', i, i
        FROM generate_series(1, 200) i;
      CREATE INDEX rt_a_idx ON rt (a);
      CREATE INDEX rt_qr_idx ON rt (q, r);
      CREATE INDEX rt_ts_idx ON rt (t, s);
      CREATE INDEX rt_c_inc_idx ON rt (c) INCLUDE (d);
      CREATE INDEX rt_e_part_idx ON rt (e) WHERE flag;
      CREATE INDEX rt_note_pat_idx ON rt (note text_pattern_ops);
      CREATE INDEX rt_b_idx ON rt (b);
      CREATE INDEX rt_lower_idx ON rt (lower(note));
      CREATE INDEX rt_status_part_idx ON rt (g) WHERE status = 'open';
      CREATE INDEX rt_h_desc_idx ON rt (h DESC);
      CREATE UNIQUE INDEX rt_u_uniq_idx ON rt (u);
      ALTER TABLE rt ADD CONSTRAINT rt_k_key UNIQUE (k);
      ALTER TABLE rt ADD CONSTRAINT rt_x_excl EXCLUDE USING btree (x WITH =);
      CREATE INDEX rt_ws_part_idx ON rt (n) WHERE ws <> 'deleted';
      CREATE INDEX rt_ws_left_idx ON rt (p) WHERE 'deleted' <> ws;
      CREATE INDEX rt_ws_lt_idx ON rt (q) WHERE 'a' < ws;
      CREATE INDEX rt_m_hash ON rt USING hash (m);
      ANALYZE rt;
    SQL
    Quaack::Enclave::PlannerStatistics.run(store:, relations: [table], connection: conn)
  end

  # The names suggested for a label whose one new index is ddl.
  def suggested(*ddls) = drops_for(*ddls).map { it["name"] }

  # The store's index_build holds the built indexes, so a spec writes it
  # and asks about a label that ran with all of them.
  def drops_for(*ddls)
    built = ddls.each_with_index.to_h { |ddl, i| ["quaack_#{i}", { "ddl" => ddl, "size" => 1 }] }
    store.write("index_build", "indexes" => built)
    described_class.new(store).drops("indexes" => built.keys)
  end

  it "suggests an index whose key is a leading prefix of the new one's" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (a, b)")).to eq(["rt_a_idx"])
  end

  it "doesn't suggest an index that's a non-prefix of the new one's key" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (b, a)")).to eq(["rt_b_idx"])
  end

  it "suggests a multicolumn index only when every one of its columns leads the new key, in order" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (q, r, c)")).to eq(["rt_qr_idx"])
    expect(suggested("CREATE INDEX ON public.rt USING btree (q, c)")).to eq([])
    expect(suggested("CREATE INDEX ON public.rt USING btree (s, t, c)")).to eq([])
  end

  it "suggests one whose INCLUDE columns the new index covers, in its key or its INCLUDE list" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (c, d)")).to eq(["rt_c_inc_idx"])
    expect(suggested("CREATE INDEX ON public.rt USING btree (c, b) INCLUDE (d)")).to eq(["rt_c_inc_idx"])
  end

  it "suggests one with the same partial predicate, and one with an exactly matching expression" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (e, b) WHERE flag")).to eq(["rt_e_part_idx"])
    expect(suggested("CREATE INDEX ON public.rt USING btree (lower(note), b)")).to eq(["rt_lower_idx"])
  end

  it "suggests a varchar partial index when the new index has the same predicate" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (n, b) WHERE ws <> 'deleted'")).to eq(["rt_ws_part_idx"])
  end

  it "doesn't suggest a varchar partial index when the new index's literal differs" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (n, b) WHERE ws <> 'archived'")).to eq([])
  end

  it "suggests a varchar partial index whose predicate has the constant on the left" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (p, b) WHERE 'deleted' <> ws")).to eq(["rt_ws_left_idx"])
    expect(suggested("CREATE INDEX ON public.rt USING btree (p, b) WHERE 'archived' <> ws")).to eq([])
  end

  it "doesn't match a predicate with the operands the other way round", :aggregate_failures do
    expect(suggested("CREATE INDEX ON public.rt USING btree (p, b) WHERE ws <> 'deleted'")).to eq([])
    expect(suggested("CREATE INDEX ON public.rt USING btree (q, b) WHERE ws < 'a'")).to eq([])
    expect(suggested("CREATE INDEX ON public.rt USING btree (q, b) WHERE 'a' < ws")).to eq(["rt_ws_lt_idx"])
  end

  it "lists a drop once when two of a label's new indexes cover it" do
    expect(suggested("CREATE INDEX ON public.rt USING btree (a, b)",
                     "CREATE INDEX ON public.rt USING btree (a, c)")).to eq(["rt_a_idx"])
  end

  {
    "an INCLUDE column the new index doesn't cover" => "CREATE INDEX ON public.rt USING btree (c, b)",
    "a different predicate (the existing one is partial, the new one isn't)" =>
      "CREATE INDEX ON public.rt USING btree (e, b)",
    "a different predicate (the new one is partial, the existing one isn't)" =>
      "CREATE INDEX ON public.rt USING btree (a, b) WHERE flag",
    "a different partial predicate" => "CREATE INDEX ON public.rt USING btree (g, b) WHERE status = 'closed'",
    "a different opclass" => "CREATE INDEX ON public.rt USING btree (note, b)",
    "an expression the new index lacks" => "CREATE INDEX ON public.rt USING btree (note, id)",
    "a different direction" => "CREATE INDEX ON public.rt USING btree (h, b)",
    "a unique index" => "CREATE INDEX ON public.rt USING btree (u, b)",
    "a UNIQUE constraint's index" => "CREATE INDEX ON public.rt USING btree (k, b)",
    "the primary key" => "CREATE INDEX ON public.rt USING btree (id, b)",
    "an EXCLUDE constraint's index" => "CREATE INDEX ON public.rt USING btree (x, b)",
    "another access method" => "CREATE INDEX ON public.rt USING btree (m, b)"
  }.each do |what, ddl|
    it "suggests nothing for #{what}" do
      expect(suggested(ddl)).to eq([])
    end
  end

  it "sends each drop as its name, its size, and production's idx_scan, and nothing else" do
    conn.exec("SELECT pg_stat_force_next_flush()")
    conn.exec("SET enable_seqscan = off; SELECT count(*) FROM rt WHERE a = 5; RESET enable_seqscan")
    conn.exec("SELECT pg_stat_force_next_flush()")
    conn.exec("SELECT 1")
    Quaack::Enclave::PlannerStatistics.run(store:, relations: [table], connection: conn)
    sizes = conn.exec("SELECT pg_relation_size('rt_a_idx')").getvalue(0, 0).to_i
    scans = conn.exec("SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname = 'rt_a_idx'").getvalue(0, 0).to_i

    expect(scans).to be_positive
    expect(drops_for("CREATE INDEX ON public.rt USING btree (a, b)"))
      .to eq([{ "name" => "rt_a_idx", "size_bytes" => sizes, "idx_scan" => scans }])
  end

  it "sends no predicate or value, and a sentinel in the new index's predicate matches nothing" do
    planted = "CREATE INDEX ON public.rt USING btree (e, b) WHERE status = '#{sentinel}'"
    real = drops_for("CREATE INDEX ON public.rt USING btree (e, b) WHERE flag")

    expect(suggested(planted)).to eq([])
    expect(real.map { it["name"] }).to eq(["rt_e_part_idx"])
    expect(JSON.generate(real)).not_to include("flag", "WHERE")
    expect(real.first.keys).to eq(%w[name size_bytes idx_scan])
  end

  it "suggests nothing for an entry with no constrained fact, as an older store has" do
    data = store.read("statistics")
    data["tables"].each { |t| t["indexes"].each { it.delete("constrained") } }
    store.write("statistics", data)

    expect(suggested("CREATE INDEX ON public.rt USING btree (a, b)")).to eq([])
  end
end
