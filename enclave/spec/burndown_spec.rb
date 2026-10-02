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

  def record(stage = "5a-3", search = :original, **counts) = described_class.record(store, stage, search, **counts)

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

  describe ".record" do
    it "stores a stage's counts under its stage and search, filling in what the stage didn't give" do
      record(in: 10, dropped: { duplicate: 2, covered_by_existing: 1 }, set_aside: 1, out: 6,
             extra: { gist_candidates: 1 })

      expect(JSON.parse(File.read(stored_file))).to eq(
        "stages" => {
          "5a-3" => {
            "original" => { "in" => 10, "added" => {}, "dropped" => { "duplicate" => 2, "covered_by_existing" => 1 },
                            "set_aside" => 1, "out" => 6, "extra" => { "gist_candidates" => 1 } }
          }
        },
        "totals" => {}
      )
    end

    it "keeps each stage and each search apart" do
      record("5a-1", :original, in: 0, added: { generator_one: 4 }, out: 4)
      record("5a-3", :original, in: 4, out: 4)
      record("5a-3", :rewrite2, in: 3, dropped: { duplicate: 1 }, out: 2)

      stages = described_class.read(store)["stages"]
      expect(stages.keys).to eq(%w[5a-1 5a-3])
      expect(stages["5a-3"].keys).to eq(%w[original rewrite2])
      expect(stages.dig("5a-1", "original", "added")).to eq("generator_one" => 4)
      expect(stages.dig("5a-3", "rewrite2", "out")).to eq(2)
    end

    describe ".record_all" do
      it "stores several stages' records in one write, as record stores each" do
        described_class.record_all(store, [["6c", :rewrites, { in: 0, added: { some_rule: 2 }, out: 2 }],
                                           ["step8", :rewrites, { in: 2, dropped: { failed_to_plan: 1 }, out: 1 }]])

        expect(described_class.read(reopened)["stages"]).to eq(
          "6c" => { "rewrites" => { "in" => 0, "added" => { "some_rule" => 2 }, "dropped" => {}, "set_aside" => 0,
                                    "out" => 2, "extra" => {} } },
          "step8" => { "rewrites" => { "in" => 2, "added" => {}, "dropped" => { "failed_to_plan" => 1 },
                                       "set_aside" => 0, "out" => 1, "extra" => {} } }
        )
      end

      it "stores none of them when one is refused" do
        expect_refused(/a step8 record's in/) do
          described_class.record_all(store, [["6c", :rewrites, { in: 0, added: { some_rule: 2 }, out: 2 }],
                                             ["step8", :rewrites, { in: 2, out: 1 }]])
        end
        expect(store.entry?("burndown")).to be(false)
      end
    end

    describe "across calls to the enclave script" do
      it "adds each call's counts to what earlier calls stored, never losing one" do
        record(in: 5, added: { generator_one: 1 }, dropped: { duplicate: 2 }, out: 4, extra: { retries: 1 })
        described_class.record(reopened, "5a-3", :original, in: 3, added: { generator_two: 2 },
                                                            dropped: { duplicate: 1, covered_by_existing: 1 },
                                                            set_aside: 1, out: 2, extra: { masks: 3 })
        described_class.record(reopened, "5a-4", :original, in: 6, dropped: { never_used: 2 }, out: 4)

        expect(described_class.read(reopened)["stages"]).to eq(
          "5a-3" => {
            "original" => { "in" => 8, "added" => { "generator_one" => 1, "generator_two" => 2 },
                            "dropped" => { "duplicate" => 3, "covered_by_existing" => 1 }, "set_aside" => 1,
                            "out" => 6, "extra" => { "retries" => 1, "masks" => 3 } }
          },
          "5a-4" => {
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
        described_class.record(reopened, "5a-4", :original, in: 1, out: 1)

        burndown = described_class.read(reopened)
        expect(burndown["stages"].keys).to eq(%w[5a-3 5a-4])
        expect(burndown["totals"]).to eq("measurement_runs" => 2)
      end
    end

    describe "the consistency check" do
      it "refuses a record where in plus added, less dropped and set aside, isn't out, storing nothing" do
        expect_refused(/5a-3.*in \+ added - dropped - set_aside must equal out/) do
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

        expect(described_class.read(store).dig("stages", "5a-3", "original", "extra")).to eq("untested_atoms" => 5)
      end

      it "leaves an earlier record alone when a later one is refused" do
        record(in: 2, out: 2)
        expect_refused { record(in: 2, out: 1) }

        expect(described_class.read(reopened).dig("stages", "5a-3", "original", "in")).to eq(2)
      end
    end

    describe "type checks" do
      it "refuses a stage that isn't one of the DESIGN.md 15b stages, without quoting it" do
        expect_refused(/stage/) { record(BURNDOWN_SENTINEL, in: 0, out: 0) }
        expect_refused(/stage/) { record(:"5a-3", in: 0, out: 0) }
        expect_refused(/stage/) { record("5a-3\n", in: 0, out: 0) }
      end

      it "stores a stage given as a String subclass as the protocol's own String" do
        record(Class.new(String).new("5a-3"), in: 1, out: 1)

        expect(described_class.read(store)["stages"].keys).to eq(["5a-3"])
      end

      it "refuses a search that isn't a Symbol naming a lowercase word, without quoting it" do
        expect_refused(/search/) { record("5a-3", "original", in: 0, out: 0) }
        expect_refused(/search/) { record("5a-3", :"#{BURNDOWN_SENTINEL}@x.com", in: 0, out: 0) }
        expect_refused(/search/) { record("5a-3", :"SENTINEL-5f2b", in: 0, out: 0) }
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
        record("5a-3", :original, in: 1, dropped: { BURNDOWN_SENTINEL.to_sym => 1 }, out: 0)

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
        plant("stages" => { "5a-3" => { "original" => change[good_record] } }, "totals" => {})

        expect_refused(/burndown entry in run #{store.run_id}/) { described_class.read(store) }
        expect_refused { described_class.record(store, "5a-3", :original, in: 0, out: 0) }
      end
    end

    it "refuses one with an unknown stage, search, or total, or a top level that isn't stages and totals" do
      [
        { "stages" => { "SENTINEL" => {} }, "totals" => {} },
        { "stages" => { "5a-3" => { "Sentinel@x" => good_record } }, "totals" => {} },
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
      plant("stages" => { "5a-3" => { "original" => good_record } }, "totals" => { "fixture_loads" => 2 })

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

    it "records a search's drops by reason, what it set aside, and what went on to 5a-4" do
      mechanical
      described_class.record_dedupe(store, dedupe, search: :original)

      expect(described_class.read(store).dig("stages", "5a-3", "original")).to eq(
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

      expect_refused(/5a-3/) { described_class.record_dedupe(store, lossy, search: :original) }
      expect(store.entry?("burndown")).to be(false)
    end

    it "records only 5a-3, so it takes no stage and no since" do
      mechanical
      expect { described_class.record_dedupe(store, dedupe, search: :original, stage: "5a-5") }
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

  describe ".record_llm_round, before it looks at the report" do
    let(:report) { Quaack::Enclave::SingleCandidateTest::Report.new(baseline: nil, results: []) }
    let(:since) { { in: 0, dropped: {}, set_aside: 0, out: 0 } }
    let(:dedupe) do
      orders = Quaack::Enclave::TableName.new(schema: "public", name: "orders")
      table = Quaack::Enclave::TableStatistics.new(name: orders, reltuples: 1, columns: {}, column_names: ["id"],
                                                   indexes: {})
      Quaack::Enclave::Dedupe.new(statistics: Quaack::Enclave::Statistics.new(tables: [table]), low_cardinality: [])
    end

    def round(stage: "5a-5", since: self.since)
      described_class.record_llm_round(store, stage:, search: :original, dedupe:, since:, report:)
    end

    it "records an empty round as adding nothing" do
      round

      expect(described_class.read(store).dig("stages", "5a-5", "original")).to eq(
        "in" => 0, "added" => { "llm" => 0 }, "dropped" => {}, "set_aside" => 0, "out" => 0, "extra" => {}
      )
    end

    it "refuses any stage but 5a-5 or 5a-6" do
      round(stage: "5a-6")
      %w[5a-3 5a-4 step11].each { |stage| expect_refused(/5a-5 or 5a-6/) { round(stage:) } }
      expect(described_class.read(store)["stages"].keys).to eq(["5a-6"])
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
        "stages" => { "5a-3" => { "original" => { "in" => 3, "added" => {}, "dropped" => { "duplicate" => 1 },
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
