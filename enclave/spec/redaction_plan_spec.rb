# frozen_string_literal: true

require "json"
require "quaack/enclave/redaction"

RSpec.describe Quaack::Enclave::Redaction, ".plan" do
  def fixture(name) = JSON.parse(File.read(File.join(__dir__, "fixtures", "plans", "#{name}.json")))

  def entry(value, type = "unknown") = { "value" => value, "type" => type }

  def map(*entries) = entries.each_with_index.to_h { |e, i| ["$#{i + 1}", e] }

  def node(fields) = [{ "Plan" => { "Node Type" => "Seq Scan" }.merge(fields) }]

  def redact(explain, placeholder_map) = described_class.plan(explain, placeholder_map)

  # The redacted Filter of a one-node plan.
  def filter(text, placeholder_map) = redact(node("Filter" => text), placeholder_map).explain.first["Plan"]["Filter"]

  def masked(text, placeholder_map) = redact(node("Filter" => text), placeholder_map).masked

  describe "literals in quals" do
    it "replaces each literal with the placeholder whose value it matches, whatever its cast" do
      text = "((email = 'a'::text) AND (total_cents > '-5'::integer) AND ((x)::numeric < 1.5) AND (id = 7))"
      placeholder_map = map(entry("a"), entry("-5", "integer"), entry("1.5", "numeric"), entry("7", "integer"))
      expect(filter(text, placeholder_map))
        .to eq("((email = $1::text) AND (total_cents > $2::integer) AND ((x)::numeric < $3) AND (id = $4))")
      expect(masked(text, placeholder_map)).to eq(0)
    end

    it "masks a literal no placeholder matches as $?, and counts each one" do
      text = "((email = 'quaack-sentinel-other'::text) AND (id = 918273645) AND (name = 'a'::text))"
      expect(filter(text, map(entry("a")))).to eq("((email = $?::text) AND (id = $?) AND (name = $1::text))")
      expect(masked(text, map(entry("a")))).to eq(2)
    end

    it "matches a number the query wrote as a string, and a string Postgres printed for a number" do
      placeholder_map = map(entry("5"), entry("-12", "integer"))
      expect(filter("((a = 5) AND (b = '-12'::bigint))", placeholder_map)).to eq("((a = $1) AND (b = $2::bigint))")
    end

    it "matches a number the query wrote in another form to the string Postgres printed for it" do
      expect(filter("(x > '-100'::numeric)", map(entry("-1e2", "numeric")))).to eq("(x > $1::numeric)")
    end

    it "never matches a NULL placeholder" do
      expect(filter("((a = 'x'::text) AND (b = 5))", map(entry(nil), entry("x")))).to eq("((a = $2::text) AND (b = $?))")
    end

    it "doesn't match a string to a different string that reads as the same number" do
      expect(filter("(code = '05'::text)", map(entry("5")))).to eq("(code = $?::text)")
    end

    it "reads a string literal the way Postgres does, quotes and escapes included" do
      placeholder_map = map(entry("Ada's"), entry("a\nb"))
      expect(filter("((name = 'Ada''s'::text) AND (note = E'a\\nb'::text))", placeholder_map))
        .to eq("((name = $1::text) AND (note = $2::text))")
    end

    it "writes the lowest placeholder when several share the value" do
      expect(filter("((a = 5) AND (b = 5))", map(entry("5", "integer"), entry("5", "integer"))))
        .to eq("((a = $1) AND (b = $1))")
    end

    it "matches booleans, but leaves IS TRUE and IS NOT FALSE alone" do
      text = "((flag = true) AND (other = false) AND (a IS TRUE) AND (b IS NOT FALSE))"
      expect(filter(text, map(entry("true", "boolean"))))
        .to eq("((flag = $1) AND (other = $?) AND (a IS TRUE) AND (b IS NOT FALSE))")
    end

    it "leaves subplan numbers, type modifiers, and parameters alone" do
      text = "((((status)::character varying(12))::text = (InitPlan 1).col1) AND (NOT (ANY (id = " \
             "(hashed SubPlan 2).col1))) AND ((total)::numeric(10,2) > $3) AND (x = 'a'::character varying(4)))"
      expect(filter(text, map(entry("a")))).to eq(text.sub("'a'", "$1"))
    end

    it "writes an array literal whose elements match placeholders as an ARRAY of them" do
      text = "(id = ANY ('{1,2,3}'::bigint[]))"
      placeholder_map = map(entry("1", "integer"), entry("2", "integer"), entry("3", "integer"))
      expect(filter(text, placeholder_map)).to eq("(id = ANY (ARRAY[$1, $2, $3]::bigint[]))")
    end

    it "masks each element of an array literal that no placeholder matches" do
      text = "(email = ANY ('{a,\"quaack-sentinel-x\",NULL}'::text[]))"
      expect(filter(text, map(entry("a")))).to eq("(email = ANY (ARRAY[$1, $?, NULL]::text[]))")
      expect(masked(text, map(entry("a")))).to eq(1)
    end

    it "matches a whole array literal to the placeholder that holds it" do
      expect(filter("(id = ANY ('{4,5}'::bigint[]))", map(entry("{4,5}"))))
        .to eq("(id = ANY ($1::bigint[]))")
    end

    it "reads a cast to an array of a type whose name has several words" do
      expect(filter("(t = ANY ('{a}'::timestamp with time zone[]))", map(entry("a"))))
        .to eq("(t = ANY (ARRAY[$1]::timestamp with time zone[]))")
    end

    it "masks a whole literal that looks like an array but isn't cast to one" do
      expect(filter("(note = '{4,5}'::text)", map(entry("4"), entry("5")))).to eq("(note = $?::text)")
    end
  end

  describe "the fields it keeps" do
    let(:plan) do
      node("Relation Name" => "orders", "Alias" => "o", "Plan Rows" => 12, "Actual Rows" => 3.0,
           "Parallel Aware" => false, "Output" => ["o.id", "'a'::text"], "Sort Key" => ["(o.status = 'a'::text)"],
           "Group Key" => ["o.status"], "Presorted Key" => ["o.id"], "Cache Key" => "o.id, 'a'::text",
           "Index Cond" => "(o.id = 7)", "One-Time Filter" => "false", "Run Condition" => "(row_number() OVER w1 < 7)",
           "Workers" => [{ "Worker Number" => 0 }], "Remote SQL" => "SELECT 'a'", "Some Future Field" => "a",
           "Plans" => [{ "Node Type" => "Index Scan", "Filter" => "(x = 'a'::text)", "Invented" => 1 }])
    end
    let(:redacted) { redact(plan, map(entry("a"), entry("7", "integer"))).explain.first["Plan"] }

    it "keeps names, numbers, and flags as they are" do
      expect(redacted.slice("Node Type", "Relation Name", "Alias", "Plan Rows", "Actual Rows", "Parallel Aware"))
        .to eq("Node Type" => "Seq Scan", "Relation Name" => "orders", "Alias" => "o", "Plan Rows" => 12,
               "Actual Rows" => 3.0, "Parallel Aware" => false)
    end

    it "redacts every expression field and every expression list" do
      expect(redacted.slice("Output", "Sort Key", "Group Key", "Presorted Key", "Cache Key", "Index Cond",
                            "One-Time Filter", "Run Condition"))
        .to eq("Output" => ["o.id", "$1::text"], "Sort Key" => ["(o.status = $1::text)"], "Group Key" => ["o.status"],
               "Presorted Key" => ["o.id"], "Cache Key" => "o.id, $1::text", "Index Cond" => "(o.id = $2)",
               "One-Time Filter" => "$?", "Run Condition" => "(row_number() OVER w1 < $2)")
    end

    it "counts the masks in an expression list" do
      lists = node("Output" => ["'quaack-sentinel-a'::text", "'b'::text"], "Sort Key" => ["('c'::text || x)"])
      expect(redact(lists, {}).masked).to eq(3)
    end

    it "drops every field it doesn't know, in every node" do
      expect(redacted.keys).not_to include("Workers", "Remote SQL", "Some Future Field")
      expect(redacted["Plans"]).to eq([{ "Node Type" => "Index Scan", "Filter" => "(x = $1::text)" }])
    end

    it "drops a known field whose value isn't the kind it should be" do
      bad = node("Plan Rows" => "quaack-sentinel-rows", "Relation Name" => ["x"], "Output" => "o.id",
                 "Filter" => ["(a = 1)"])
      expect(redact(bad, {}).explain.first["Plan"]).to eq("Node Type" => "Seq Scan")
    end

    it "drops an expression it can't read, or a whole list with one in it, and counts each" do
      result = redact(node("Filter" => "(email = 'quaack-sentinel-unclosed)", "Output" => ["'a", "o.id"]), {})
      expect(result.explain.first["Plan"]).to eq("Node Type" => "Seq Scan")
      expect(result.dropped).to eq(2)
    end

    it "keeps the statement's times and the planner settings EXPLAIN lists, and drops the rest" do
      explain = fixture("sentinel_literals")
      explain.first["Settings"] = { "work_mem" => "64kB", "search_path" => "app, public",
                                    "myapp.tenant" => "quaack-sentinel-setting" }
      explain.first["JIT"] = { "Functions" => 1 }
      top = redact(explain, {}).explain.first
      expect(top.keys).to contain_exactly("Plan", "Settings", "Planning", "Planning Time", "Execution Time")
      expect(top["Settings"]).to eq("work_mem" => "64kB", "search_path" => "app, public")
      expect(top["Planning"]).to eq(explain.first["Planning"])
    end
  end

  describe "trust boundary" do
    let(:sentinels) { %w[quaack-sentinel-email quaack-sentinel-name] }

    def leaked(data) = sentinels.select { |s| JSON.generate(data).include?(s) }

    it "leaves no literal of the sentinel plan in what it gives back" do
      explain = fixture("sentinel_literals")
      expect(leaked(explain)).to eq(sentinels)
      result = redact(explain, map(entry("quaack-sentinel-email"), entry("quaack-sentinel-name")))
      expect(leaked(result.explain)).to be_empty
      expect(result.explain.first["Plan"]["Filter"]).to eq("((email = $1::text) AND (name = $2::text))")
      expect(leaked([result.inspect, result.to_s])).to be_empty
    end

    it "masks the sentinel plan's literals even with no placeholder map" do
      result = redact(fixture("sentinel_literals"), {})
      expect(leaked(result.explain)).to be_empty
      expect(result.masked).to eq(2)
    end
  end

  it "redacts a plan thousands of nodes deep" do
    deep = { "Node Type" => "Seq Scan", "Filter" => "(email = 'quaack-sentinel-deep'::text)" }
    3_000.times { deep = { "Node Type" => "Limit", "Plans" => [deep] } }
    result = redact([{ "Plan" => deep }], {})
    expect(JSON.generate(result.explain, max_nesting: false)).not_to include("quaack-sentinel-deep")
    expect(result.masked).to eq(1)
  end

  it "refuses a plan that isn't EXPLAIN's JSON, and a map that isn't a placeholder map" do
    expect { redact({ "Plan" => {} }, {}) }.to raise_error(ArgumentError, /EXPLAIN/)
    expect { redact(node({}), { "$1" => "quaack-sentinel-map" }) }
      .to raise_error(described_class::Error, "bad_placeholder_map")
  end
end
