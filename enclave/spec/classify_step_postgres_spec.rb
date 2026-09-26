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

  def outbound(name)
    stored.read("classification")["outbound_statistics"]["tables"][0]["columns"].find { it["name"] == name }
  end

  def expect_frequencies(freqs, count)
    expect(freqs.size).to eq(count)
    expect(freqs).to all(be_a(Float).and(be_between(0.0, 1.0)))
  end

  it "stores the classification, printing only DONE" do
    statistics!

    outcome = classify

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([done, "", 0])
    classes = stored.read("classification")["columns"].to_h { [it["column"], [it["pii"], it["low_cardinality"]]] }
    expect(classes).to eq("id" => [false, false], "status" => [false, true], "email" => [true, false],
                          "code" => [false, false], "note" => [true, false])
  end

  it "stores a low-cardinality, non-PII column's MCV values and frequencies for the payload" do
    statistics!
    classify

    status = outbound("status")

    expect(status["most_common_vals"]).to match_array(categories)
    expect_frequencies(status["most_common_freqs"], 2)
    expect(status.values_at("n_distinct", "null_frac")).to eq([2.0, 0.0])
  end

  it "stores no MCV values or frequencies for a PII column, but keeps its scalars" do
    statistics!
    classify

    email = outbound("email")

    expect(email.values_at("most_common_vals", "most_common_freqs")).to eq([nil, nil])
    expect(email["n_distinct"]).to eq(5.0)
  end

  it "stores a high-cardinality non-PII column's frequencies but never its values" do
    statistics!
    classify

    code = outbound("code")

    expect(code["most_common_vals"]).to be_nil
    expect_frequencies(code["most_common_freqs"], 60)
  end

  it "prints no sentinel, though the store holds them" do
    statistics!

    outcome = classify

    expect(outcome.stdout).to eq(done)
    held = JSON.generate(stored.read("statistics"))
    expect(held).to include(sentinels.text, sentinels.number.to_s, sentinels.like_prefix)
    expect_no_leaks(sentinels, outcome)
  end

  context "when a low-cardinality category is itself a sentinel" do
    let(:categories) { [sentinels.text, "pending"] }

    before { config({}) }

    # The positive control: the leak check sees the sentinel in what the
    # payload step will send, so its finding nothing in classify's output
    # means something.
    it "stores it for the payload, and the leak check would catch it going out" do
      statistics!

      outcome = classify

      values = outbound("status")["most_common_vals"]
      expect(values).to include(sentinels.text)
      found = LeakCheck.findings(sentinels, stdout: JSON.generate(values))
      expect(found.join("\n")).to include(sentinels.needles[:text])
      expect_no_leaks(sentinels, outcome)
    end
  end

  context "with a cardinality_threshold of 2" do
    before { config(pii_columns: ["public.orders.email"], cardinality_threshold: 2) }

    it "treats status as not low-cardinality, and stores none of its values" do
      statistics!
      classify

      expect(outbound("status")["most_common_vals"]).to be_nil
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
