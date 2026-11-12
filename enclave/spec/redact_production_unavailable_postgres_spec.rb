# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/enclave/store"
require "quaack/enclave/steps/redact"
require_relative "support/production_server"

# 20261110-9: redact asks production how its string placeholders print as
# dates (Printed). When production can't be reached, or the question times
# out, the step still succeeds: those literals are masked as before, without
# printed-form matching, and the literal never shows up in what it writes.
RSpec.describe "quaacks redact, when production can't answer the printed-forms question" do
  let(:sku) { "SKU-9#{SecureRandom.hex(6)}" }
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:query) { "SELECT o.id FROM public.orders o WHERE o.sku = '#{sku}'" }
  let(:plan) do
    conn = production.connect
    conn.exec("CREATE TABLE public.orders (id int, sku text)")
    JSON.parse(conn.exec("EXPLAIN (ANALYZE, FORMAT JSON) #{query}").getvalue(0, 0))
  ensure
    conn&.close
  end
  let(:entries) { %w[placeholder_map placeholder_shapes redacted_query redacted_plan] }

  after do
    quaacks.remove
    production.drop
  end

  def fill(store, plan_entry = plan)
    store.write("server", production.host)
    store.write("qualified_query", query)
    store.write("plan", plan_entry)
    store
  end

  def expect_masked(stored)
    expect(stored.read("redacted_query")).to eq("SELECT o.id FROM public.orders o WHERE o.sku = $1")
    expect(stored.read("placeholder_map")["$1"]["value"]).to eq(sku)
    %w[placeholder_shapes redacted_query redacted_plan].each do |name|
      expect(JSON.generate(stored.read(name))).not_to include(sku)
    end
  end

  it "succeeds without printed forms when production refuses the connection" do
    store = fill(Quaack::Enclave::Store.create(base: quaacks.store_base))
    store.write("production_port", 1)

    outcome = quaacks.run("redact", "--run", store.run_id, env: production.quaacks_env(quaacks.home))

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect_masked(Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base))
  end

  context "in process, with the connection faked at PG.connect" do
    let(:base) { Dir.mktmpdir("quaack-redact-") }
    let(:store) { fill(Quaack::Enclave::Store.create(base:)) }

    after { FileUtils.remove_entry(base) }

    # A connection whose every statement is cancelled by statement_timeout.
    def timing_out
      Object.new.tap do |conn|
        def conn.set_notice_receiver(*) = nil
        def conn.close = nil
        def conn.exec(sql) = sql.start_with?("BEGIN", "ROLLBACK") ? nil : raise(PG::QueryCanceled, "timeout")
        def conn.exec_params(*) = raise(PG::QueryCanceled, "canceling statement due to statement timeout")
      end
    end

    it "succeeds without printed forms when the question hits statement_timeout (57014)" do
      store
      allow(PG).to receive(:connect).and_return(timing_out)

      expect(Quaack::Enclave::Steps::Redact.call(store:)).to eq([])
      expect_masked(store)
    end

    it "succeeds without printed forms when PG.connect raises PG::ConnectionBad" do
      store
      allow(PG).to receive(:connect).and_raise(PG::ConnectionBad, "could not connect #{sku}")

      expect(Quaack::Enclave::Steps::Redact.call(store:)).to eq([])
      expect_masked(store)
    end

    it "succeeds without printed forms when closing the connection raises a PG::Error Production doesn't wrap" do
      store
      conn = timing_out
      def conn.close = raise(PG::UnableToSend, "connection lost")
      allow(PG).to receive(:connect).and_return(conn)

      expect(Quaack::Enclave::Steps::Redact.call(store:)).to eq([])
      expect_masked(store)
    end

    it "still fails on a failure outside the printed-forms question, storing nothing" do
      broken = fill(Quaack::Enclave::Store.create(base:), "not a plan")
      allow(PG).to receive(:connect).and_raise(PG::ConnectionBad)

      expect { Quaack::Enclave::Steps::Redact.call(store: broken) }.to raise_error(StandardError)
      expect(entries.map { broken.entry?(it) }).to all(be(false))
    end
  end
end
