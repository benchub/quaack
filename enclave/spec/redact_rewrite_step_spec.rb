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

  context "with two placeholders in equal comparisons (20261020-1)" do
    let(:store) do
      Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
        store.write("redacted_query", "SELECT o.id FROM public.orders o JOIN public.users u ON u.id = o.user_id " \
                                      "AND o.note <> $1 WHERE o.note <> $2")
        store.write("placeholder_map", "$1" => { "value" => "other-#{sentinel}", "type" => "unknown" },
                                       "$2" => { "value" => sentinel, "type" => "unknown" })
      end
    end

    it "takes the one whose value the rewrite's literal has, and never sends a value" do
      outcome = redact_rewrite("SELECT o.id FROM orders o WHERE o.note != '#{sentinel}'")
      expect(lines(outcome).first).to eq("type" => "redacted_rewrite",
                                         "sql" => "SELECT o.id FROM orders o WHERE o.note <> $2")
      expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
    end

    it "refuses a value neither holds, naming the candidates and never a value" do
      sql = "SELECT o.id FROM orders o WHERE o.note <> 'changed-#{sentinel}'"
      outcome = redact_rewrite(sql)
      expect(outcome.status.exitstatus).to eq(64)
      expect(lines(outcome)).to eq([{ "type" => "error", "step" => "redact-rewrite",
                                      "rule" => "redact_rewrite_ambiguous", "position" => sql.index("'") + 1,
                                      "candidates" => [1, 2] }])
      expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
      expect(entries).to eq(%w[placeholder_map.json redacted_query.json store_format.json])
    end
  end

  it "refuses input that isn't one {\"sql\": String} object" do
    outcome = quaacks.run("redact-rewrite", "--run", store.run_id, stdin: JSON.generate("sql" => 1))
    expect([outcome.status.exitstatus, lines(outcome)])
      .to eq([64, [{ "type" => "error", "step" => "redact-rewrite", "rule" => "bad_input" }]])
  end

  it "refuses input with a key besides sql as bad_input" do
    outcome = quaacks.run("redact-rewrite", "--run", store.run_id,
                          stdin: JSON.generate("sql" => "SELECT o.id FROM orders o", "extra" => 1))
    expect([outcome.status.exitstatus, lines(outcome)])
      .to eq([64, [{ "type" => "error", "step" => "redact-rewrite", "rule" => "bad_input" }]])
  end

  # 20261019-5: pg_query's message quotes the bad SQL, so the sentinel sits
  # right where the parse fails.
  it "refuses a statement that doesn't parse as usage, with its position and never the SQL" do
    sql = "SELECT o.id FROM orders o WHERE o.note = = '#{sentinel}'"
    outcome = redact_rewrite(sql)
    expect([outcome.status.exitstatus, lines(outcome)])
      .to eq([64, [{ "type" => "error", "step" => "redact-rewrite", "rule" => "redact_rewrite_unparsable",
                     "position" => sql.index("= =") + 3 }]])
    expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
  end

  { "redact_rewrite_not_one_statement" => "SELECT 1; SELECT '%s'",
    "redact_rewrite_empty" => "-- %s\n" }.each do |rule, template|
    it "refuses as #{rule}, never sending the SQL" do
      outcome = redact_rewrite(format(template, sentinel))
      expect([outcome.status.exitstatus, lines(outcome)])
        .to eq([64, [{ "type" => "error", "step" => "redact-rewrite", "rule" => rule }]])
      expect([outcome.stdout, outcome.stderr].join).not_to include(sentinel)
    end
  end

  # The positive control: the checks above would see the sentinel if it were
  # there, since the same scan finds it in what was sent.
  it "would see the sentinel in its input" do
    expect(JSON.generate("sql" => "SELECT '#{sentinel}'")).to include(sentinel)
  end
end
