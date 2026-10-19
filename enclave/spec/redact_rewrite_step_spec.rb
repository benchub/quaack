# frozen_string_literal: true

require "json"
require "quaack/enclave/store"
require_relative "support/leak_check"

# `quaacks redact-rewrite --run <run ID>` (DESIGN.md's redact-rewrite) the
# way the jump server runs it: the installed quaacks in its own process,
# outside Bundler. It reads the run's redacted_query, takes the rewrite as
# {"sql"} on stdin, and needs no database.
RSpec.describe "quaacks redact-rewrite" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinel) { "SENTINEL-redact-rewrite-41c9" }
  let(:number_sentinel) { "918273645" }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("redacted_query", "SELECT o.id FROM public.orders o WHERE o.note = $1 AND o.code > $2")
      store.write("placeholder_map", "$1" => { "value" => sentinel, "type" => "unknown" },
                                     "$2" => { "value" => number_sentinel, "type" => "integer" })
    end
  end

  after { quaacks.remove }

  def redact_rewrite(sql) = quaacks.run("redact-rewrite", "--run", store.run_id, stdin: JSON.generate("sql" => sql))
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }
  def entries = Dir.children(File.join(quaacks.store_base, store.run_id)).sort

  it "sends the rewrite with the run's placeholders, and never a literal or a store write" do
    before = entries
    sql = "SELECT o.id FROM orders o WHERE o.code > #{number_sentinel} AND o.note = '#{sentinel}'"
    outcome = redact_rewrite(sql)
    expect(outcome.status.exitstatus).to eq(0)
    expect(lines(outcome)).to eq([{ "type" => "redacted_rewrite",
                                    "sql" => "SELECT o.id FROM orders o WHERE o.code > $2 AND o.note = $1" },
                                  { "type" => "done" }])
    expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
    expect([outcome.stdout, outcome.stderr].join).not_to include(number_sentinel)
    expect(entries).to eq(before)
  end

  it "refuses a literal with no match as usage, naming its position and never its value" do
    sql = "SELECT o.id FROM orders o WHERE o.code < '#{sentinel}'"
    outcome = redact_rewrite(sql)
    expect(outcome.status.exitstatus).to eq(64)
    expect(lines(outcome)).to eq([{ "type" => "error", "step" => "redact-rewrite",
                                    "rule" => "redact_rewrite_no_match", "position" => sql.index("'") + 1 }])
    expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
  end

  it "refuses input that isn't one {\"sql\": String} object" do
    outcome = quaacks.run("redact-rewrite", "--run", store.run_id, stdin: JSON.generate("sql" => 1))
    expect([outcome.status.exitstatus, lines(outcome)])
      .to eq([64, [{ "type" => "error", "step" => "redact-rewrite", "rule" => "bad_input" }]])
  end

  # The positive control: the checks above would see the sentinel if it were
  # there, since the same scan finds it in what was sent.
  it "would see the sentinel in its input" do
    expect(JSON.generate("sql" => "SELECT '#{sentinel}'")).to include(sentinel)
  end
end
