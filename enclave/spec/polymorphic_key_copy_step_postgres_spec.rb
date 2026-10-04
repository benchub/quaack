# frozen_string_literal: true

require "pg_query"
require "securerandom"
require "quaack/enclave/planner_statistics"
require "quaack/enclave/pii_classification"
require "quaack/enclave/table_name"
require_relative "support/index_search_run"

# `quaacks rewrite-rules` running polymorphic_key_copy (DESIGN.md 6c) in
# Canvas's shape, with 6b checking its denormalized_equal assumption against
# the racetrack's data. The polymorphic type, the class whose column the
# rule finds, is itself a sentinel, as are the id and the other literal, so
# neither the type literal nor any data leaves the enclave.
RSpec.describe "quaacks rewrite-rules with polymorphic_key_copy, against a real server" do
  include_context "an index search run"

  let(:hex) { SecureRandom.hex(6) }
  let(:klass) { "Sentinel#{hex}" }
  let(:column) { "sentinel#{hex}_id" }
  let(:sentinels) do
    LeakCheck::Sentinels.new(extra: { tsconfig: "sentinelts#{SecureRandom.hex(6)}", klass: })
  end
  let(:id) { sentinels.number }
  let(:violated) { false }
  let(:query) do
    "SELECT submissions.id, submissions.body FROM public.submissions JOIN public.assignments " \
      "ON assignments.id = submissions.assignment_id WHERE assignments.context_type = '#{klass}' " \
      "AND assignments.context_id = #{id} AND submissions.body = '#{sentinels.text}'"
  end
  let(:rewritten) do
    "SELECT submissions.id, submissions.body FROM public.submissions JOIN public.assignments " \
      "ON assignments.id = submissions.assignment_id WHERE assignments.context_type = $1 " \
      "AND assignments.context_id = $2 AND submissions.body = $3 AND submissions.#{column} = $2"
  end

  # Every assignment of the sentinel class has its submissions keep a copy
  # of its context id, unless the data is to violate that; the other
  # class's submissions keep none.
  let(:seed_sql) do
    copy = violated ? "CASE WHEN s % 97 = 0 THEN -1 ELSE a.context_id END" : "a.context_id"
    <<~SQL
      CREATE TABLE public.assignments (id bigint PRIMARY KEY, context_type text, context_id bigint);
      CREATE TABLE public.submissions (id bigint PRIMARY KEY, assignment_id bigint, #{column} bigint, body text);
      INSERT INTO public.assignments
      SELECT i, CASE WHEN i % 2 = 0 THEN '#{klass}' ELSE 'Other' END, CASE WHEN i = 2 THEN #{id} ELSE i END
      FROM generate_series(1, 200) AS i;
      INSERT INTO public.submissions
      SELECT s, a.id, CASE WHEN a.context_type = '#{klass}' THEN #{copy} END,
             CASE WHEN s % 400 = 1 THEN '#{sentinels.text}' ELSE 'b' || s END
      FROM generate_series(1, 20000) AS s JOIN public.assignments a ON a.id = s % 200 + 1;
      ANALYZE public.assignments, public.submissions;
    SQL
  end

  def seed(conn) = conn.exec(seed_sql)

  def capture_and_classify(conn, explain)
    tables = %w[submissions assignments]
    store.write("plan", explain)
    store.write("relations", tables.map { { "schema" => "public", "name" => it } })
    Quaack::Enclave::PlannerStatistics.run(
      store:, relations: tables.map { Quaack::Enclave::TableName.new(schema: "public", name: it) }, connection: conn
    )
    Quaack::Enclave::PiiClassification.run(store:, config: Quaack::Enclave::Config.new({}))
  end

  def rewrite_rules = quaacks.run("rewrite-rules", "--run", store.run_id, env: libpq_env)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def rows(sql)
    conn = production.connect
    binding = Quaack::Enclave::Redaction.binding(sql, stored.read("placeholder_map"))
    binding.prepare(conn, "rows")
    binding.execute(conn, "rows").values.sort_by(&:to_s)
  ensure
    conn&.close
  end

  it "stores the rule's rewrite when the data holds its assumption, and the rewrite returns the same rows" do
    prepare

    outcome = rewrite_rules

    expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
    expect(stored.read("rewrite_1")).to include(
      "sql" => rewritten, "source" => "rule", "rules" => ["polymorphic_key_copy"], "warnings" => [],
      "assumptions" => [{ "kind" => "denormalized_equal", "table" => "public.submissions", "column" => column,
                          "join_column" => "assignment_id", "references_table" => "public.assignments",
                          "references_column" => "id", "type_column" => "context_type", "type_value" => klass,
                          "id_column" => "context_id" }]
    )
    want = rows(stored.read("redacted_query"))
    expect(want).not_to be_empty
    expect(rows(rewritten)).to eq(want)
  end

  it "sends only rewrite_outcome lines, with neither the type literal nor any data" do
    prepare

    outcome = rewrite_rules

    expect_no_leaks(sentinels, outcome)
    expect(outcome.stdout).not_to include(klass)
    expect(lines(outcome)).to eq(
      [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "accepted", "rule" => nil,
         "rewrite" => "rewrite_1", "warnings" => [] }, { "type" => "done" }]
    )
  end

  context "when the data breaks the assumption" do
    let(:violated) { true }

    it "drops the rewrite as an unmet assumption, which 6b found in the data" do
      prepare

      outcome = rewrite_rules

      expect(lines(outcome)).to eq(
        [{ "type" => "rewrite_outcome", "index" => 1, "outcome" => "rejected", "rule" => "unmet_assumption",
           "rewrite" => nil, "warnings" => [] }, { "type" => "done" }]
      )
      expect(stored.entry?("rewrite_1")).to be(false)
      expect_no_leaks(sentinels, outcome)
    end
  end
end
