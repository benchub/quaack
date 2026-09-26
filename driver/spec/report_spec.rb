# frozen_string_literal: true

require "quaack/driver/report"

RSpec.describe Quaack::Driver::Report do
  def m(blocks, hit, stable: true)
    { "total_blocks" => blocks, "hit" => hit, "read" => blocks - hit, "stable" => stable, "timed_out" => false }
  end

  let(:payload) do
    { "type" => "report",
      "top" => [{ "label" => "rewrite_1:none", "slow_blocks" => 300, "total_blocks_sum" => 400, "footprint" => 0 },
                { "label" => "original:top:1", "slow_blocks" => 400, "total_blocks_sum" => 590,
                  "footprint" => 8192 }],
      "excluded" => { "rewrite_1:top:1" => "worse" }, "infinite_sets" => [],
      "verdicts" => { "rewrite_1:none" => { "slow" => "better", "typical" => "better" },
                      "original:top:1" => { "slow" => "better", "typical" => "no_worse" } },
      "measurements" => { "original" => { "slow" => m(1000, 100), "typical" => m(200, 150) },
                          "rewrite_1:none" => { "slow" => m(300, 30, stable: false), "typical" => m(100, 100) },
                          "original:top:1" => { "slow" => m(400, 300), "typical" => m(190, 190) } },
      "candidates" => [
        { "label" => "rewrite_1:none", "sql" => "SELECT id FROM t WHERE a < $1", "indexes" => [],
          "plan" => [{ "node" => "Index Scan", "relation" => "public.t", "index" => "t_a_idx", "est_rows" => 5,
                       "actual_rows" => 5, "selectivity" => 0.005 }],
          "untested_atoms" => [{ "shape" => "a < $n" }], "evidence" => false },
        { "label" => "original:top:1", "sql" => "SELECT id FROM t WHERE created_at > now() - $1",
          "indexes" => ["quaack_a"], "plan" => nil }
      ],
      "indexes" => { "quaack_a" => { "ddl" => "CREATE INDEX ON public.t USING btree (created_at)", "size" => 8192,
                                     "covered_by" => "t_created_at_id_idx", "makes_redundant" => [] },
                     "quaack_b" => { "ddl" => "CREATE INDEX ON public.t USING btree (a, b)", "size" => 16_384,
                                     "covered_by" => nil, "makes_redundant" => ["t_a_idx"] } },
      "original_plan" => [{ "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 50,
                            "actual_rows" => 50, "selectivity" => 0.05 }],
      "timed_out_count" => 2 }
  end

  let(:html) { described_class.render(payload, run_id: "RUN-1") }

  it "ranks the candidates overall, winner first" do
    expect(html.scan(%r{<tr class="rank"><td>(\d)</td><td>([^<]+)<})).to eq([%w[1 rewrite_1:none],
                                                                             %w[2 original:top:1]])
  end

  it "shows per-literal blocks with hit/read, verdicts, and unstable flags" do
    expect(html).to include("<td>slow</td><td>300</td><td>30</td><td>270</td><td>better</td><td>unstable</td>")
    expect(html).to include("<td>typical</td><td>190</td><td>190</td><td>0</td><td>no_worse</td><td></td>")
  end

  it "explains the winner from blocks, plan nodes, and selectivities" do
    expect(html).to include("rewrite_1:none reads 300 blocks on the slow literal set, against 1000 for the " \
                            "original (70% fewer)")
    expect(html).to include("Index Scan on public.t using t_a_idx (5 rows, selectivity 0.5%)")
    expect(html).to include("Seq Scan on public.t (50 rows, selectivity 5.0%)")
  end

  it "shows each query escaped, with the clock functions as the application wrote them" do
    expect(html).to include("SELECT id FROM t WHERE a &lt; $1")
    expect(html).to include("created_at &gt; now() - $1")
  end

  it "lists untested atoms and whether step 10 covered them" do
    expect(html).to include("a &lt; $n")
    expect(html).to include("no counterexample round loaded its inserts")
  end

  it "gives each index its size, prefix coverage, and redundancy" do
    expect(html).to include("<td>CREATE INDEX ON public.t USING btree (created_at)</td><td>8 kB</td>" \
                            "<td>t_created_at_id_idx</td><td></td>")
    expect(html).to include("<td>16 kB</td><td></td><td>t_a_idx</td>")
  end

  it "leaves sections for the negative result and the burndown" do
    expect(html).to include(%(<section id="negative-result">)).and include(%(<section id="burndown">))
  end
end
