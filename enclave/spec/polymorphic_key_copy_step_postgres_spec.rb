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
  # class's submissions keep none. The copy is a foreign key to the class's
  # table, as in Canvas.
  let(:seed_sql) do
    copy = violated ? "CASE WHEN s % 97 = 0 THEN NULL ELSE a.context_id END" : "a.context_id"
    <<~SQL
      #{tables_sql}
      INSERT INTO public.assignments
      SELECT i, CASE WHEN i % 2 = 0 THEN '#{klass}' ELSE 'Other' END, CASE WHEN i = 2 THEN #{id} ELSE i END
      FROM generate_series(1, 200) AS i;
      INSERT INTO public.#{column.delete_suffix("_id")}s SELECT DISTINCT context_id FROM public.assignments
      WHERE context_type = '#{klass}';
      INSERT INTO public.submissions
      SELECT s, a.id, CASE WHEN a.context_type = '#{klass}' THEN #{copy} END,
             CASE WHEN s % 400 = 1 THEN '#{sentinels.text}' ELSE 'b' || s END
      FROM generate_series(1, 20000) AS s JOIN public.assignments a ON a.id = s % 200 + 1;
      ANALYZE public.assignments, public.submissions;
    SQL
  end

  def tables_sql
    <<~SQL
      CREATE TABLE public.#{column.delete_suffix("_id")}s (id bigint PRIMARY KEY);
      CREATE TABLE public.assignments (id bigint PRIMARY KEY, context_type text, context_id bigint);
      CREATE TABLE public.submissions (id bigint PRIMARY KEY, assignment_id bigint REFERENCES public.assignments,
                                       #{column} bigint REFERENCES public.#{column.delete_suffix("_id")}s, body text);
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

  # Steps 9 and 10 on an arena of the same tables, with no rows. The
  # fixtures honour the rule's own assumption, and only on the class's rows.
  context "when steps 9 and 10 test the rewrite on the arena" do
    let(:arena_name) { "quaack_arena_#{SecureRandom.hex(4)}" }
    let(:courses) { "public.#{column.delete_suffix("_id")}s" }

    after { production.server.admin.exec(%(DROP DATABASE IF EXISTS "#{arena_name}" WITH (FORCE))) }

    def ready
      prepare
      rewrite_rules
      make_arena
      store.write("schema_subset", "tables" => [["public", courses.delete_prefix("public.")],
                                                %w[public assignments], %w[public submissions]], "ddl" => tables_sql)
      store.write("run_server", store.read("run_server").merge("arena_db" => arena_name))
      store.write("arena_setup", true)
    end

    def make_arena
      production.server.admin.exec(%(CREATE DATABASE "#{arena_name}"))
      PG.connect(host: production.host, port: production.port, dbname: arena_name, user: TestPostgres::USER,
                 password: TestPostgres::PASSWORD).tap { it.exec(tables_sql) }.close
    end

    def step(*argv, stdin: nil) = quaacks.run(*argv, "--run", store.run_id, stdin:, env: libpq_env)
    def test(search) = step("rewrite-test", "--search", search)

    def round(search, number, inserts)
      step("counterexample-round", "--search", search, "--round", number.to_s,
           stdin: JSON.generate("inserts" => inserts))
    end

    # A twin of the rule's rewrite, stored under search, by its SQL and
    # whatever else changes.
    def twin(sql = rewritten, changes = {}, search: "rewrite_2")
      store.write(search, stored.read("rewrite_1").merge("sql" => sql, "anchored_sql" => sql, **changes))
      search
    end

    # A submission of an assignment of another class, whose copy is the
    # queried id, and one of the class's, which keeps no copy.
    let(:inserts) do
      ["INSERT INTO #{courses} (id) VALUES ($2)",
       "INSERT INTO public.assignments (id, context_type, context_id) VALUES (900001, 'Other', $2)",
       "INSERT INTO public.assignments (id, context_type, context_id) VALUES (900002, $1, $2)",
       "INSERT INTO public.submissions (id, assignment_id, #{column}, body) VALUES (900001, 900001, $2, $3)",
       "INSERT INTO public.submissions (id, assignment_id, #{column}, body) VALUES (900002, 900002, NULL, $3)"]
    end

    def outcome(output) = lines(output).first

    it "passes the rule's rewrite in step 9 and every round, sending no type literal or data" do
      ready
      outputs = [test("rewrite_1"), *(1..3).map { round("rewrite_1", it, inserts) }]

      expect(outcome(outputs.first)).to include("passed" => true)
      expect(outputs.drop(1).map { outcome(it).values_at("match", "load_failed") }).to eq([[true, false]] * 3)
      expect(stored.read("rewrite_survived_1")).to include("survived" => true)
      outputs.each do |output|
        expect_no_leaks(sentinels, output)
        expect(output.stdout).not_to include(klass)
      end
    end

    it "disproves in step 9 a twin that copies the wrong id" do
      ready

      expect(outcome(test(twin(rewritten.sub("#{column} = $2", "#{column} = $2 + 1"))))).to include("passed" => false)
    end

    # Rows of another class aren't honoured, so step 9's near misses keep
    # no copy and the twin matches them; 10b's insert of such a row with a
    # copy is what tells them apart.
    it "disproves in step 10 a twin that drops the type filter" do
      ready
      search = twin(rewritten.sub("assignments.context_type = $1 AND ", ""))

      expect(outcome(test(search))).to include("passed" => true)
      expect(outcome(round(search, 1, inserts))).to include("match" => false)
      expect(stored.read("rewrite_survived_2")).to eq("survived" => false)
    end

    it "honours only the rule's own assumption, so the same SQL from elsewhere is disproved in step 9" do
      ready
      llm = outcome(test(twin(rewritten, { "source" => "llm" })))
      bare = outcome(test(twin(rewritten, { "assumptions" => [] }, search: "rewrite_3")))

      expect([llm, bare].map { it["passed"] }).to eq([false, false])
    end
  end
end
