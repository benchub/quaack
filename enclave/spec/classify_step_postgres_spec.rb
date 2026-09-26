# frozen_string_literal: true

require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks classify --run <run ID>` (README 3f) the way the jump server runs
# it: the installed quaacks in its own process, outside Bundler, in a
# temporary HOME with the operator's config. It reads the run's statistics
# entry, which a real `quaacks statistics` run writes first, from a real
# server's pg_stats.
#
# public.orders holds:
# - status, a low-cardinality text column of made-up categories, whose MCV
#   values README 3f lets out.
# - email, few distinct values that repeat, but PII by the config's glob.
#   Its values are the text sentinel.
# - code, an int column with 60 distinct values that repeat, so not PII but
#   not low-cardinality either. Its values are near the number sentinel.
# - note, a text column with 60 distinct values: PII by the heuristic. Its
#   values hold the like sentinel's prefix.
RSpec.describe "quaacks classify, after quaacks statistics against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:categories) { %w[shipped pending] }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("relations", [{ "schema" => "public", "name" => "orders" }])
    end
  end

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE TABLE public.orders (id int, status text, email text, code int, note text);
      INSERT INTO public.orders
        SELECT g, CASE WHEN g % 3 = 0 THEN '#{categories[0]}' ELSE '#{categories[1]}' END,
               '#{sentinels.text}' || (g % 5), #{sentinels.number} + (g % 60), '#{sentinels.like_prefix}' || (g % 60)
        FROM generate_series(1, 3000) g;
      ANALYZE public.orders;
    SQL
    conn.close
    config(pii_columns: ["public.orders.email"])
  end

  after do
    quaacks.remove
    production.drop
  end

  def home_file(relative, text)
    path = File.join(quaacks.home, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(0o600, path)
  end

  def config(object) = home_file(".quaack/config.json", JSON.generate(object))

  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def operator_env = libpq_env(PGPORT: production.port.to_s, PGUSER: production.user, PGDATABASE: production.name)

  def statistics!
    home_file(".pgpass", "*:#{production.port}:*:#{production.user}:#{production.password}\n")
    expect(quaacks.run("statistics", "--run", store.run_id, env: operator_env).stdout).to eq(done)
  end

  def classify = quaacks.run("classify", "--run", store.run_id, env: libpq_env)

  def done = %({"type":"done"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }
  def column_line(outcome, name) = lines(outcome).find { it["column"] == name }

  it "stores the classification and sends one column_stats line per column, then DONE" do
    statistics!

    outcome = classify

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    expect(outcome.stdout.lines.last).to eq(done)
    expect(lines(outcome)[0..-2].map { [it["type"], it["table"], it["column"]] })
      .to eq(%w[id status email code note].map { ["column_stats", { "schema" => "public", "name" => "orders" }, it] })
    expect(lines(outcome)[0..-2].map(&:keys).uniq)
      .to eq([%w[type table column n_distinct null_frac correlation mcv_freqs low_card_values]])
    classes = stored.read("classification")["columns"].to_h { [it["column"], [it["pii"], it["low_cardinality"]]] }
    expect(classes).to eq("id" => [false, false], "status" => [false, true], "email" => [true, false],
                          "code" => [false, false], "note" => [true, false])
  end

  it "sends a low-cardinality, non-PII column's MCV values and frequencies" do
    statistics!

    status = column_line(classify, "status")

    expect(status["low_card_values"]).to match_array(categories)
    expect(status["mcv_freqs"].size).to eq(2)
    expect(status["n_distinct"]).to eq(2.0)
    expect(status["null_frac"]).to eq(0.0)
  end

  it "withholds a PII column's MCV values and frequencies, but sends its scalars" do
    statistics!

    email = column_line(classify, "email")

    expect(email.values_at("low_card_values", "mcv_freqs")).to eq([nil, nil])
    expect(email["n_distinct"]).to eq(5.0)
  end

  it "sends a high-cardinality non-PII column's frequencies but never its values" do
    statistics!

    code = column_line(classify, "code")

    expect(code["low_card_values"]).to be_nil
    expect(code["mcv_freqs"].size).to eq(60)
  end

  it "never sends a sentinel, though the store holds them" do
    statistics!

    outcome = classify

    expect(outcome.stdout.lines.size).to eq(6)
    held = JSON.generate(stored.read("statistics"))
    expect(held).to include(sentinels.text, sentinels.number.to_s, sentinels.like_prefix)
    expect_no_leaks(sentinels, outcome)
  end

  context "when a low-cardinality category is itself a sentinel" do
    let(:categories) { [sentinels.text, "pending"] }

    before { config({}) }

    # The positive control: the leak check does see values in this output,
    # so its passing above means something.
    it "sends it, and the leak check catches it" do
      statistics!

      outcome = classify

      expect(column_line(outcome, "status")["low_card_values"]).to include(sentinels.text)
      found = LeakCheck.findings(sentinels, stdout: outcome.stdout, stderr: outcome.stderr, status: outcome.status)
      expect(found.join("\n")).to include(sentinels.needles[:text])
    end
  end

  context "with a cardinality_threshold of 2" do
    before { config(pii_columns: ["public.orders.email"], cardinality_threshold: 2) }

    it "treats status as not low-cardinality, and sends none of its values" do
      statistics!

      expect(column_line(classify, "status")["low_card_values"]).to be_nil
    end
  end

  it "refuses a run with no statistics entry, storing nothing" do
    outcome = classify

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"classify","rule":"internal_error"}\n), "", 70])
    expect(stored.entry?("classification")).to be(false)
  end

  it "refuses a bad config before classifying, storing nothing" do
    statistics!
    home_file(".quaack/config.json", "not json #{sentinels.text}")

    outcome = classify

    expect([outcome.stdout, outcome.status.exitstatus])
      .to eq([%({"type":"error","step":"classify","rule":"bad_config"}\n), 70])
    expect(stored.entry?("classification")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end
end
