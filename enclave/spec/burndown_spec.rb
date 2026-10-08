# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/enclave/burndown"
require "quaack/enclave/dedupe"
require "quaack/enclave/egress"
require "quaack/enclave/single_candidate_test"

# Stands in for a real production value. It must never get into the
# burndown, and never show up in an error from it.
BURNDOWN_SENTINEL = "sentinel_5f2b_orders_email"

RSpec.describe Quaack::Enclave::Burndown do
  around do |example|
    Dir.mktmpdir("quaack-burndown-spec") do |tmp|
      @base = File.join(tmp, "runs")
      example.run
    end
  end

  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  def reopened = Quaack::Enclave::Store.open(store.run_id, base: @base)

  def record(stage = "index-dedupe", search = :original, **counts)
    described_class.record(store, stage, search, **counts)
  end

  def expect_refused(pattern = nil, &)
    expect(&).to raise_error(described_class::Error) do |error|
      expect(error.message).to match(pattern) if pattern
      expect(error.message).not_to include(BURNDOWN_SENTINEL)
      expect(error.cause).to be_nil
    end
  end

  def stored_file = File.join(store.path, "burndown.json")

  it "is loaded by quaack/enclave" do
    code = 'require "quaack/enclave"; print Quaack::Enclave::Burndown::ENTRY'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq("burndown")
  end

  describe ".read" do
    it "gives an empty burndown for a run that hasn't recorded anything" do
      expect(described_class.read(store)).to eq("stages" => {}, "totals" => {})
      expect(store.entry?("burndown")).to be(false)
    end
  end

  describe ".record_once" do
    def search(number) = :"rewrite_#{number}"

    let(:first) { search(1) }
    let(:records) { [["rewrite-test", first, { in: 1, out: 1 }], ["counterexamples", first, { in: 1, out: 1 }]] }

    it "records the stages and totals in one write, and nothing when the first stage and search are already there" do
      described_class.record_once(store, records, totals: { fixture_loads: 2 })
      described_class.record_once(reopened, records, totals: { fixture_loads: 2 })

      burndown = described_class.read(reopened)
      expect(burndown["stages"].transform_values(&:keys))
        .to eq("rewrite-test" => ["rewrite_1"], "counterexamples" => ["rewrite_1"])
      expect(burndown["stages"]["rewrite-test"]["rewrite_1"]).to include("in" => 1, "out" => 1)
      expect(burndown["totals"]).to eq("fixture_loads" => 2)
    end

    it "records a stage under another search, though the stage is there" do
      described_class.record_once(store, records)

      described_class.record_once(reopened, [["rewrite-test", search(2), { in: 1, out: 0, dropped: { s1: 1 } }]])
      expect(described_class.read(reopened)["stages"]["rewrite-test"].keys).to eq(%w[rewrite_1 rewrite_2])
    end
  end

  describe ".record_latest" do
    def search(number) = :"rewrite_#{number}"

    let(:records) { [["rewrite-test", search(1), { in: 1, out: 0, dropped: { s1: 1 } }]] }

    it "replaces the search's records with the latest call's, but adds the totals only the first time" do
      described_class.record_latest(store, records, totals: { fixture_loads: 2 })
      record("rewrite-test", search(2), in: 1, out: 1)

      described_class.record_latest(reopened, [["rewrite-test", search(1), { in: 1, out: 1 }]],
                                    totals: { fixture_loads: 3 })

      burndown = described_class.read(reopened)
      expect(burndown["stages"]["rewrite-test"].transform_values { it.slice("dropped", "out") })
        .to eq("rewrite_1" => { "dropped" => {}, "out" => 1 }, "rewrite_2" => { "dropped" => {}, "out" => 1 })
      expect(burndown["totals"]).to eq("fixture_loads" => 2)
    end
  end

  describe ".record_replacing" do
    it "replaces each stage's record for its search, keeping other searches, and adds the totals" do
      record("index-rank", :original, in: 5, dropped: { below_top_three: 2 }, out: 3)
      record("index-rank", :rewrite, in: 1, out: 1)
      described_class.add_totals(store, hypothetical_explains: 4)

      described_class.record_replacing(
        reopened, [["index-rank", :original, { in: 2, out: 2 }],
                   ["llm-index-refine", :original, { in: 0, out: 0, extra: { nothing_fell_short: 1 } }]],
        totals: { hypothetical_explains: 3 }
      )

      burndown = described_class.read(reopened)
      expect(burndown["stages"]["index-rank"]).to eq(
        "original" => { "in" => 2, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 2, "extra" => {} },
        "rewrite" => { "in" => 1, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 1, "extra" => {} }
      )
      expect(burndown["stages"]["llm-index-refine"]["original"]["extra"]).to eq("nothing_fell_short" => 1)
      expect(burndown["totals"]).to eq("hypothetical_explains" => 7)
    end

    it "checks each record as record does, storing nothing when one is refused" do
      record("index-rank", :original, in: 1, out: 1)

      expect_refused(/index-rank/) do
        described_class.record_replacing(store, [["index-rank", :original, { in: 2, out: 1 }]])
      end
      expect(described_class.read(store)["stages"]["index-rank"]["original"]["in"]).to eq(1)
    end
  end

  describe ".record" do
    it "stores a stage's counts under its stage and search, filling in what the stage didn't give" do
      record(in: 10, dropped: { duplicate: 2, covered_by_existing: 1 }, set_aside: 1, out: 6,
             extra: { gist_candidates: 1 })

      expect(JSON.parse(File.read(stored_file))).to eq(
        "stages" => {
          "index-dedupe" => {
            "original" => { "in" => 10, "added" => {}, "dropped" => { "duplicate" => 2, "covered_by_existing" => 1 },
                            "set_aside" => 1, "out" => 6, "extra" => { "gist_candidates" => 1 } }
          }
        },
        "totals" => {}
      )
    end

    it "keeps each stage and each search apart" do
      record("index-from-query", :original, in: 0, added: { generator_one: 4 }, out: 4)
      record("index-dedupe", :original, in: 4, out: 4)
      record("index-dedupe", :rewrite2, in: 3, dropped: { duplicate: 1 }, out: 2)

      stages = described_class.read(store)["stages"]
      expect(stages.keys).to eq(%w[index-from-query index-dedupe])
      expect(stages["index-dedupe"].keys).to eq(%w[original rewrite2])
      expect(stages.dig("index-from-query", "original", "added")).to eq("generator_one" => 4)
      expect(stages.dig("index-dedupe", "rewrite2", "out")).to eq(2)
    end

    describe ".record_all" do
      it "stores several stages' records in one write, as record stores each" do
        described_class.record_all(store, [["rewrite-rules", :rewrites, { in: 0, added: { some_rule: 2 }, out: 2 }],
                                           ["plan-pruning", :rewrites,
                                            { in: 2, dropped: { failed_to_plan: 1 }, out: 1 }]])

        expect(described_class.read(reopened)["stages"]).to eq(
          "rewrite-rules" => { "rewrites" => { "in" => 0, "added" => { "some_rule" => 2 }, "dropped" => {},
                                               "set_aside" => 0, "out" => 2, "extra" => {} } },
          "plan-pruning" => { "rewrites" => { "in" => 2, "added" => {}, "dropped" => { "failed_to_plan" => 1 },
                                              "set_aside" => 0, "out" => 1, "extra" => {} } }
        )
      end

      it "stores none of them when one is refused" do
        expect_refused(/the plan-pruning record's in/) do
          described_class.record_all(store, [["rewrite-rules", :rewrites, { in: 0, added: { some_rule: 2 }, out: 2 }],
                                             ["plan-pruning", :rewrites, { in: 2, out: 1 }]])
        end
        expect(store.entry?("burndown")).to be(false)
      end
    end

    describe "across calls to the enclave script" do
      it "adds each call's counts to what earlier calls stored, never losing one" do
        record(in: 5, added: { generator_one: 1 }, dropped: { duplicate: 2 }, out: 4, extra: { retries: 1 })
        described_class.record(reopened, "index-dedupe", :original, in: 3, added: { generator_two: 2 },
                                                                    dropped: { duplicate: 1, covered_by_existing: 1 },
                                                                    set_aside: 1, out: 2, extra: { masks: 3 })
        described_class.record(reopened, "index-test", :original, in: 6, dropped: { never_used: 2 }, out: 4)

        expect(described_class.read(reopened)["stages"]).to eq(
          "index-dedupe" => {
            "original" => { "in" => 8, "added" => { "generator_one" => 1, "generator_two" => 2 },
                            "dropped" => { "duplicate" => 3, "covered_by_existing" => 1 }, "set_aside" => 1,
                            "out" => 6, "extra" => { "retries" => 1, "masks" => 3 } }
          },
          "index-test" => {
            "original" => { "in" => 6, "added" => {}, "dropped" => { "never_used" => 2 }, "set_aside" => 0,
                            "out" => 4, "extra" => {} }
          }
        )
      end

      it "adds work totals the same way" do
        described_class.add_totals(store, hypothetical_explains: 3, fixture_loads: 1)
        described_class.add_totals(reopened, hypothetical_explains: 4, indexes_built: 2)

        expect(described_class.read(reopened)["totals"])
          .to eq("hypothetical_explains" => 7, "fixture_loads" => 1, "indexes_built" => 2)
      end

      it "keeps the stages when it adds totals, and the totals when it records a stage" do
        record(in: 1, out: 1)
        described_class.add_totals(reopened, measurement_runs: 2)
        described_class.record(reopened, "index-test", :original, in: 1, out: 1)

        burndown = described_class.read(reopened)
        expect(burndown["stages"].keys).to eq(%w[index-dedupe index-test])
        expect(burndown["totals"]).to eq("measurement_runs" => 2)
      end
    end

    describe "the consistency check" do
      it "refuses a record where in plus added, less dropped and set aside, isn't out, storing nothing" do
        expect_refused(/index-dedupe.*in \+ added - dropped - set_aside must equal out/) do
          record(in: 10, added: { generator_one: 2 }, dropped: { duplicate: 3 }, set_aside: 1, out: 9)
        end
        expect(store.entry?("burndown")).to be(false)
      end

      it "checks each count that goes into the sum" do
        expect_refused { record(in: 1, out: 2) }
        expect_refused { record(in: 1, added: { generator_one: 1 }, out: 1) }
        expect_refused { record(in: 1, dropped: { duplicate: 1 }, out: 1) }
        expect_refused { record(in: 1, set_aside: 1, out: 1) }
        expect(record(in: 1, added: { generator_one: 2 }, dropped: { duplicate: 1 }, set_aside: 1, out: 1)).to be_nil
      end

      it "leaves extra out of the sum" do
        record(in: 2, out: 2, extra: { untested_atoms: 5 })

        expect(described_class.read(store).dig("stages", "index-dedupe", "original",
                                               "extra")).to eq("untested_atoms" => 5)
      end

      it "leaves an earlier record alone when a later one is refused" do
        record(in: 2, out: 2)
        expect_refused { record(in: 2, out: 1) }

        expect(described_class.read(reopened).dig("stages", "index-dedupe", "original", "in")).to eq(2)
      end
    end

    describe "type checks" do
      it "refuses a stage that isn't one of DESIGN.md's burndown stages, without quoting it" do
        expect_refused(/stage/) { record(BURNDOWN_SENTINEL, in: 0, out: 0) }
        expect_refused(/stage/) { record(:"index-dedupe", in: 0, out: 0) }
        expect_refused(/stage/) { record("index-dedupe\n", in: 0, out: 0) }
      end

      it "stores a stage given as a String subclass as the protocol's own String" do
        record(Class.new(String).new("index-dedupe"), in: 1, out: 1)

        expect(described_class.read(store)["stages"].keys).to eq(["index-dedupe"])
      end

      it "refuses a search that isn't a Symbol naming a lowercase word, without quoting it" do
        expect_refused(/search/) { record("index-dedupe", "original", in: 0, out: 0) }
        expect_refused(/search/) { record("index-dedupe", :"#{BURNDOWN_SENTINEL}@x.com", in: 0, out: 0) }
        expect_refused(/search/) { record("index-dedupe", :"SENTINEL-5f2b", in: 0, out: 0) }
      end

      it "refuses a reason, source, or extra key that isn't a Symbol naming a lowercase word, without quoting it" do
        %i[added dropped extra].each do |field|
          [BURNDOWN_SENTINEL, :"#{BURNDOWN_SENTINEL}@x.com", :Sentinel, 7].each do |key|
            counts = { in: 1, out: 1 }.merge(field => { key => 0 })
            expect_refused(/#{field}/) { record(**counts) }
          end
        end
        expect(store.entry?("burndown")).to be(false)
      end

      it "refuses a count that isn't a non-negative Integer, without quoting it" do
        bad = [BURNDOWN_SENTINEL, 1.0, nil, -1, [1], { a: 1 }, (2**64) + 0.5]
        bad.each do |value|
          expect_refused(/in/) { record(in: value, out: 0) }
          expect_refused(/out/) { record(in: 0, out: value) }
          expect_refused(/set_aside/) { record(in: 0, set_aside: value, out: 0) }
          expect_refused(/dropped/) { record(in: 0, dropped: { duplicate: value }, out: 0) }
          expect_refused(/added/) { record(in: 0, added: { generator_one: value }, out: 0) }
          expect_refused(/extra/) { record(in: 0, out: 0, extra: { retries: value }) }
        end
        expect(store.entry?("burndown")).to be(false)
      end

      it "refuses added, dropped, or extra when it isn't a Hash" do
        %i[added dropped extra].each do |field|
          [BURNDOWN_SENTINEL, [[:duplicate, 0]]].each do |value|
            expect_refused(/#{field}/) { record(in: 0, out: 0, field => value) }
          end
        end
      end

      it "refuses an unknown field, or a record with no in or out, without quoting it" do
        expect_refused(/field/) { record(in: 0, out: 0, rows: BURNDOWN_SENTINEL) }
        expect_refused(/field/) { record(in: 0, out: 0, "note" => BURNDOWN_SENTINEL) }
        expect_refused(/field/) { record("in" => 0, out: 0) }
        expect_refused(/in/) { record(out: 0) }
        expect_refused(/out/) { record(in: 0) }
      end

      it "refuses a work total that isn't a Symbol naming a lowercase word with a non-negative Integer" do
        expect_refused { described_class.add_totals(store, BURNDOWN_SENTINEL.upcase.to_sym => 1) }
        expect_refused { described_class.add_totals(store, "fixture_loads" => 1) }
        expect_refused { described_class.add_totals(store, fixture_loads: BURNDOWN_SENTINEL) }
        expect_refused { described_class.add_totals(store, fixture_loads: -1) }
        expect(store.entry?("burndown")).to be(false)
      end

      it "the sentinel check itself sees a sentinel that's a lowercase word, which a name can't tell from a value" do
        record("index-dedupe", :original, in: 1, dropped: { BURNDOWN_SENTINEL.to_sym => 1 }, out: 0)

        expect(File.read(stored_file)).to include(BURNDOWN_SENTINEL)
      end
    end
  end

  describe "a stored burndown that isn't one" do
    def plant(data) = store.write("burndown", data)

    let(:good_record) { { "in" => 1, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 1, "extra" => {} } }

    [
      ["a value in place of a count", ->(r) { r.merge("in" => BURNDOWN_SENTINEL) }],
      ["a value as a reason", ->(r) { r.merge("dropped" => { "#{BURNDOWN_SENTINEL}@x" => 0 }) }],
      ["an extra field", ->(r) { r.merge("rows" => [BURNDOWN_SENTINEL]) }],
      ["a missing field", ->(r) { r.except("extra") }],
      ["a negative count", ->(r) { r.merge("in" => 2, "dropped" => { "duplicate" => -1 }, "out" => 3) }],
      ["counts that don't add up", ->(r) { r.merge("out" => 2) }]
    ].each do |what, change|
      it "refuses to read one with #{what}, without quoting it" do
        plant("stages" => { "index-dedupe" => { "original" => change[good_record] } }, "totals" => {})

        expect_refused(/burndown entry in run #{store.run_id}/) { described_class.read(store) }
        expect_refused { described_class.record(store, "index-dedupe", :original, in: 0, out: 0) }
      end
    end

    it "refuses one with an unknown stage, search, or total, or a top level that isn't stages and totals" do
      [
        { "stages" => { "SENTINEL" => {} }, "totals" => {} },
        { "stages" => { "index-dedupe" => { "Sentinel@x" => good_record } }, "totals" => {} },
        { "stages" => {}, "totals" => { "fixture_loads" => BURNDOWN_SENTINEL } },
        { "stages" => {}, "totals" => {}, "rows" => [BURNDOWN_SENTINEL] },
        { "stages" => {} },
        [BURNDOWN_SENTINEL]
      ].each do |data|
        plant(data)
        expect_refused(/burndown entry/) { described_class.read(store) }
      end
    end

    it "reads one that is, as a check on the plants above" do
      plant("stages" => { "index-dedupe" => { "original" => good_record } }, "totals" => { "fixture_loads" => 2 })

      expect(described_class.read(store)["totals"]).to eq("fixture_loads" => 2)
    end
  end

  describe ".record_dedupe" do
    let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
    let(:dedupe) do
      table = Quaack::Enclave::TableStatistics.new(
        name: orders, reltuples: 1000, columns: {}, column_names: %w[id customer_id status note],
        indexes: { "orders_customer_id_idx" => candidate(["customer_id"], sources: [:existing]) }
      )
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]),
                                  low_cardinality: [[orders, "status"]])
    end

    def candidate(key, sources: [:parse], **) = Quaack::Enclave::IndexCandidate.new(table: orders, key:, sources:, **)

    # Seven candidates: one covered, one duplicate, one partial on a column
    # that isn't low-cardinality, one GIN set aside, and three survivors.
    def mechanical
      dedupe.filter([candidate(["customer_id"]), candidate(["status"]), candidate(["status"], sources: [:plan]),
                     candidate(["note"], predicate: "note = '#{BURNDOWN_SENTINEL}'"),
                     candidate(["note"], access_method: :gin), candidate(["id"]), candidate(%w[status id])])
    end

    it "records a search's drops by reason, what it set aside, and what went on to index-test" do
      mechanical
      described_class.record_dedupe(store, dedupe, search: :original)

      expect(described_class.read(store).dig("stages", "index-dedupe", "original")).to eq(
        "in" => 7, "added" => {},
        "dropped" => { "covered_by_existing" => 1, "duplicate" => 1, "partial_not_low_cardinality" => 1 },
        "set_aside" => 1, "out" => 3, "extra" => {}
      )
      expect(File.read(stored_file)).not_to include(BURNDOWN_SENTINEL)
    end

    it "takes in from what the search was given, so a search that lost a candidate doesn't add up" do
      mechanical
      lossy = Struct.new(:considered, :drops, :set_aside, :proposals)
                    .new(dedupe.considered, dedupe.drops, dedupe.set_aside, dedupe.proposals.drop(1))

      expect_refused(/index-dedupe/) { described_class.record_dedupe(store, lossy, search: :original) }
      expect(store.entry?("burndown")).to be(false)
    end

    it "records only index-dedupe, so it takes no stage and no since" do
      mechanical
      expect { described_class.record_dedupe(store, dedupe, search: :original, stage: "llm-index-ideas") }
        .to raise_error(ArgumentError, /unknown keyword: :stage/)
      expect { described_class.record_dedupe(store, dedupe, search: :original, since: {}) }
        .to raise_error(ArgumentError, /unknown keyword: :since/)
      expect(store.entry?("burndown")).to be(false)
    end

    it "returns the counts it recorded, for a later LLM round's since" do
      mechanical

      expect(described_class.record_dedupe(store, dedupe, search: :original)).to eq(
        in: 7, dropped: { covered_by_existing: 1, duplicate: 1, partial_not_low_cardinality: 1 }, set_aside: 1, out: 3
      )
    end
  end

  # Task 20260924-8: index-dedupe and index-test run once per search, so a
  # second record of either for the same search is misuse, and index-test
  # tests exactly the Dedupe's proposals.
  describe "the once-per-search records" do
    let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
    let(:sct) { Quaack::Enclave::SingleCandidateTest }
    let(:dedupe) do
      table = Quaack::Enclave::TableStatistics.new(name: orders, reltuples: 1000, columns: {},
                                                   column_names: %w[id status], indexes: {})
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]), low_cardinality: [])
    end

    def candidate(key, sources: [:parse]) = Quaack::Enclave::IndexCandidate.new(table: orders, key:, sources:)

    def result(candidate, used: false, refusal: nil)
      plans = refusal ? {} : { slow: sct::Plan.new(used:, total_cost: 1.0, canonical_plan: nil, raw_plan: nil) }
      sct::Result.new(candidate:, size: 1, plans:, refusal:, literal_sets: {})
    end

    def report(*results) = sct::Report.new(baseline: nil, results:)

    def stored = described_class.read(store)

    it "refuses a second index-dedupe record for the same search, and keeps the first" do
      dedupe.filter([candidate(["id"]), candidate(["id"], sources: [:plan])])
      described_class.record_dedupe(store, dedupe, search: :original)
      first = stored

      expect_refused(/index-dedupe already has a record for this search/) do
        described_class.record_dedupe(store, dedupe, search: :original)
      end
      expect(stored).to eq(first)
    end

    it "still records index-dedupe for another search" do
      described_class.record_dedupe(store, dedupe, search: :original)
      described_class.record_dedupe(store, dedupe, search: :rewrite)

      expect(stored["stages"]["index-dedupe"].keys).to eq(%w[original rewrite])
    end

    it "refuses a second index-test record for the same search, and keeps the first" do
      proposals = dedupe.filter([candidate(["id"])])
      tested = report(result(proposals.first, used: true))
      described_class.record_single_candidate_test(store, tested, search: :original, dedupe:)
      first = stored

      expect_refused(/index-test already has a record for this search/) do
        described_class.record_single_candidate_test(store, tested, search: :original, dedupe:)
      end
      expect(stored).to eq(first)
    end

    it "refuses an index-test report that didn't test exactly the Dedupe's proposals" do
      dedupe.filter([candidate(["id"]), candidate(["status"])])
      id, status = dedupe.proposals
      [report(result(id)), report(result(id), result(status), result(candidate(%w[id status]))),
       report(result(id), result(candidate(%w[id status]))), report(result(id), result(id))].each do |tested|
        expect_refused(/index-test report must test exactly the Dedupe's proposals/) do
          described_class.record_single_candidate_test(store, tested, search: :original, dedupe:)
        end
      end
      expect(store.entry?("burndown")).to be(false)
    end

    it "records a report of the Dedupe's proposals, whatever their order and sources" do
      dedupe.filter([candidate(["id"]), candidate(["status"]), candidate(["id"], sources: [:plan])])
      tested = report(result(candidate(["status"]), used: true), result(candidate(["id"], sources: [:llm])))
      described_class.record_single_candidate_test(store, tested, search: :original, dedupe:)

      expect(stored.dig("stages", "index-test", "original")).to include("in" => 2, "out" => 1)
    end

    it "checks the report through the record record_once takes too" do
      dedupe.filter([candidate(["id"])])

      expect_refused(/exactly the Dedupe's proposals/) do
        described_class.single_candidate_test_record(report, search: :original, dedupe:)
      end
    end

    it "counts an unrenderable candidate as its own drop, apart from what HypoPG refused" do
      dedupe.filter([candidate(["id"]), candidate(["status"]), candidate(%w[id status])])
      id, status, both = dedupe.proposals
      unrenderable = sct::Refusal.new(rule: :unrenderable, sqlstate: nil)
      hypopg_refused = sct::Refusal.new(rule: :hypopg_refused, sqlstate: "42704")
      tested = report(result(id, used: true), result(status, refusal: unrenderable),
                      result(both, refusal: hypopg_refused))
      described_class.record_single_candidate_test(store, tested, search: :original, dedupe:)

      expect(stored.dig("stages", "index-test", "original", "dropped"))
        .to eq("unrenderable" => 1, "hypopg_refused" => 1)
    end

    it "refuses a refusal rule that isn't one of SingleCandidateTest's" do
      dedupe.filter([candidate(["id"])])
      refused = sct::Refusal.new(rule: BURNDOWN_SENTINEL.to_sym, sqlstate: nil)

      expect_refused(/refusal/) do
        described_class.record_single_candidate_test(store, report(result(dedupe.proposals.first, refusal: refused)),
                                                     search: :original, dedupe:)
      end
      expect(store.entry?("burndown")).to be(false)
    end
  end

  describe ".record_llm_round, before it looks at the report" do
    let(:report) { Quaack::Enclave::SingleCandidateTest::Report.new(baseline: nil, results: []) }
    let(:since) { { in: 0, dropped: {}, set_aside: 0, out: 0 } }
    let(:dedupe) do
      orders = Quaack::Enclave::TableName.new(schema: "public", name: "orders")
      table = Quaack::Enclave::TableStatistics.new(name: orders, reltuples: 1, columns: {}, column_names: ["id"],
                                                   indexes: {})
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]), low_cardinality: [])
    end

    def round(stage: "llm-index-ideas", since: self.since)
      described_class.record_llm_round(store, stage:, search: :original, dedupe:, since:, report:)
    end

    it "records an empty round as adding nothing" do
      round

      expect(described_class.read(store).dig("stages", "llm-index-ideas", "original")).to eq(
        "in" => 0, "added" => { "llm" => 0 }, "dropped" => {}, "set_aside" => 0, "out" => 0, "extra" => {}
      )
    end

    it "counts DDL refused before the Dedupe as the LLM's, dropped by rule, and keeps extra" do
      described_class.record_llm_round(store, stage: "llm-index-refine", search: :original, dedupe:, since:, report:,
                                              refused: { unqualified_table: 2, too_many: 1 },
                                              extra: { fell_short: 3 })

      expect(described_class.read(store).dig("stages", "llm-index-refine", "original")).to eq(
        "in" => 0, "added" => { "llm" => 3 }, "dropped" => { "unqualified_table" => 2, "too_many" => 1 },
        "set_aside" => 0, "out" => 0, "extra" => { "fell_short" => 3 }
      )
    end

    it "refuses any stage but llm-index-ideas or llm-index-refine" do
      round(stage: "llm-index-refine")
      %w[index-dedupe index-test
         rewrite-index-ideas].each do |stage|
        expect_refused(/llm-index-ideas or llm-index-refine/) do
          round(stage:)
        end
      end
      expect(described_class.read(store)["stages"].keys).to eq(["llm-index-refine"])
    end

    it "refuses a since that isn't the counts an earlier record returned, as Burndown::Error" do
      [
        { "in" => 0, "dropped" => {}, "set_aside" => 0, "out" => 0 },
        since.except(:out),
        since.merge(in: BURNDOWN_SENTINEL),
        since.merge(dropped: { duplicate: -1 }),
        since.merge(dropped: [BURNDOWN_SENTINEL]),
        since.merge(dropped: { "duplicate" => 0 }),
        since.merge(rows: BURNDOWN_SENTINEL),
        nil,
        BURNDOWN_SENTINEL
      ].each do |bad|
        expect_refused(/since/) { round(since: bad) }
      end
      expect(store.entry?("burndown")).to be(false)
    end
  end

  describe ".message" do
    it "builds the burndown message that egress sends as is" do
      record(in: 3, dropped: { duplicate: 1 }, out: 2)
      described_class.add_totals(store, hypothetical_explains: 6)

      out = Quaack::Enclave::Egress.serialize(described_class.message(store))
      expect(JSON.parse(out)).to eq(
        "type" => "burndown",
        "stages" => { "index-dedupe" => { "original" => { "in" => 3, "added" => {}, "dropped" => { "duplicate" => 1 },
                                                          "set_aside" => 0, "out" => 2, "extra" => {} } } },
        "totals" => { "hypothetical_explains" => 6 }
      )
    end

    it "sends only stages and totals, whatever else rides along" do
      message = described_class.message(store).merge(rows: [BURNDOWN_SENTINEL])

      expect(Quaack::Enclave::Egress.serialize(message)).to eq('{"type":"burndown","stages":{},"totals":{}}')
    end

    it "never sends a planted value, since reading the entry refuses it" do
      store.write("burndown", "stages" => {}, "totals" => { "fixture_loads" => BURNDOWN_SENTINEL })

      expect_refused { described_class.message(store) }
    end
  end
end
