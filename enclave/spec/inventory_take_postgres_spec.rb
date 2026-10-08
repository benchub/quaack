# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/store"
require "quaack/enclave/steps/inventory"
require_relative "support/production_server"

# Inventory.take and the inventory step, in this process, against a
# stand-in production database (DESIGN.md's inventory).
RSpec.describe Quaack::Enclave::Inventory do
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:params) do
    { host: production.host, port: production.port, dbname: production.name, user: production.user,
      password: production.password }
  end
  let(:plan) { [{ "Plan" => { "Node Type" => "Result" }, "Settings" => { "enable_hashjoin" => "off" } }] }

  after { production.drop }

  # Every connection PG.connect makes while the block runs.
  def connections
    made = []
    allow(PG).to(receive(:connect).and_wrap_original { |original, **args| original.call(**args).tap { made << it } })
    yield
    made
  end

  it "closes its production connection once it has read" do
    made = connections { described_class.take(production: params, plan:, memory_command: nil) }

    expect(made.size).to eq(1)
    expect(made.first.finished?).to be(true)
  end

  it "closes its production connection when the memory command fails too" do
    made = connections do
      described_class.take(production: params, plan:, memory_command: "exit 1")
    rescue Quaack::Enclave::Inventory::Error
      nil
    end

    expect(made.map(&:finished?)).to eq([true])
  end

  describe "the step" do
    around do |example|
      Dir.mktmpdir("quaack-inventory-step") do |tmp|
        @base = File.join(tmp, "runs")
        example.run
      end
    end

    let(:store) { Quaack::Enclave::Store.create(base: @base).tap { it.write("server", production.host) } }

    # The test server is Postgres 18, so a step that printed 18 whatever
    # it read would pass a real read. This inventory says 17.
    it "prints the major version and whether the memory is known, as the inventory has them" do
      allow(Quaack::Enclave::Config).to receive(:load).and_return(Quaack::Enclave::Config.new({}))
      store.write("plan", plan)
      allow(described_class).to receive(:take).and_return("major_version" => 17, "memory_bytes" => 1024)

      lines = Quaack::Enclave::Steps::Inventory.call(store:)

      expect(lines).to eq([{ type: :inventory, major_version: 17, memory_known: true }])
      expect(store.read("inventory")).to eq("major_version" => 17, "memory_bytes" => 1024)
    end
  end
end
