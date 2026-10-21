# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/store"
require "quaack/enclave/deparse"
require "quaack/enclave/redaction"
require_relative "support/production_server"

# 20261020-7: the user's run. The original has no EXISTS, only an IN over
# a UNION ALL; the rewrite says EXISTS (SELECT 1 ...), whose 1 has no
# placeholder to take. The store is filled by the real qualify and redact
# through the installed quaacks, as in redact_rewrite_pipeline_postgres_spec.rb.
# Synthetic copy with made-up numbers.
RSpec.describe "quaacks redact-rewrite of an EXISTS rewrite of an IN over UNION ALL" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:schema) { %("cluster44_shard_7236") }
  let(:user_id) { 3_141_592_653 }
  let(:context_ids) { (1..21).map { 700_000_000 + (it * 37) } }
  let(:assignment_ids) { (1..12).map { 900_000_000 + (it * 11) } }
  let(:sentinel) { sentinels.text }

  # Every literal but the EXISTS's 1 takes the original's placeholder.
  let(:expected) do
    one_line(<<~SQL)
      SELECT count(*) FROM cluster44_shard_7236.assignments JOIN cluster44_shard_7236.submissions
      ON submissions.assignment_id = assignments.id AND submissions.workflow_state <> $1
      WHERE assignments.type = $2 AND assignments.workflow_state <> $6 AND assignments.context_type = $7
      AND assignments.context_id IN ($8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22,
      $23, $24, $25, $26, $27, $28) AND submissions.user_id = $67 AND submissions.workflow_state <> $1
      AND submissions.cached_due_date BETWEEN $69 AND $70
      AND (((assignments.muted IS NULL OR NOT assignments.muted)
      AND EXISTS (SELECT 1 FROM cluster44_shard_7236.content_participations cp
      WHERE cp.content_type = $4 AND cp.content_id = submissions.id AND cp.user_id = $29
      AND cp.workflow_state = $30)) OR assignments.id IN ($55, $56, $57, $58, $59, $60, $61, $62, $63, $64, $65, $66))
    SQL
  end

  def t(table) = %(#{schema}."#{table}")

  def one_line(sql) = sql.split.join(" ").gsub("( ", "(")

  def ids(list) = list.join(", ")

  # The user's original, as the app wrote it: an IN over a UNION ALL, no EXISTS.
  def query(unread)
    one_line(<<~SQL)
      SELECT COUNT(*) FROM #{schema}."assignments" #{join}
      WHERE "assignments"."type" = 'Assignment' AND ("assignments"."id" IN (#{union(unread)}))
      AND #{submission_filters}
    SQL
  end

  def join
    one_line(<<~SQL)
      INNER JOIN #{schema}."submissions" ON "submissions"."assignment_id" = "assignments"."id"
      AND (submissions.workflow_state <> 'deleted')
    SQL
  end

  def scope
    one_line(<<~SQL)
      "assignments"."type" = 'Assignment' AND "assignments"."workflow_state" != 'deleted'
      AND "assignments"."context_type" = 'Course' AND "assignments"."context_id" IN (#{ids(context_ids)})
    SQL
  end

  def submission_filters
    one_line(<<~SQL)
      "submissions"."user_id" = #{user_id} AND "submissions"."workflow_state" != 'deleted'
      AND "submissions"."cached_due_date" BETWEEN '2026-03-16 00:00:00' AND '2036-09-16 07:00:00'
    SQL
  end

  # The UNION ALL the original's IN reads from.
  def union(unread)
    one_line(<<~SQL)
      (SELECT "assignments"."id" FROM #{schema}."assignments" #{join}
      INNER JOIN #{schema}."content_participations" ON "content_participations"."content_type" = 'Submission'
      AND "content_participations"."content_id" = "submissions"."id" WHERE #{scope}
      AND (assignments.muted IS NULL OR NOT assignments.muted) AND "content_participations"."user_id" = #{user_id}
      AND "content_participations"."workflow_state" = '#{unread}') UNION ALL
      (SELECT "assignments"."id" FROM #{schema}."assignments" WHERE #{scope}
      AND "assignments"."id" IN (#{ids(assignment_ids)}))
    SQL
  end

  # The user's rewrite: the UNION ALL becomes an EXISTS that says SELECT 1.
  def rewrite(unread)
    one_line(<<~SQL)
      SELECT COUNT(*) FROM #{schema}."assignments" #{join} WHERE #{scope} AND #{submission_filters}
      AND (((assignments.muted IS NULL OR NOT assignments.muted) AND EXISTS (SELECT 1
      FROM #{schema}."content_participations" cp WHERE cp.content_type = 'Submission'
      AND cp.content_id = submissions.id AND cp.user_id = #{user_id} AND cp.workflow_state = '#{unread}'))
      OR assignments.id IN (#{ids(assignment_ids)}))
    SQL
  end

  # The sentinel stands in for a real value the run's store holds.
  let(:original) { query(sentinel) }

  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("query", original)
      store.write("plan", explain)
    end
  end

  def explain
    conn = production.connect
    conn.exec(ddl)
    JSON.parse(conn.exec("EXPLAIN (ANALYZE, SETTINGS, FORMAT JSON) #{original}").getvalue(0, 0))
  ensure
    conn&.close
  end

  def ddl
    <<~SQL
      CREATE SCHEMA #{schema};
      CREATE TABLE #{t("assignments")} (id bigint, workflow_state text, type text, context_type text,
        context_id bigint, muted boolean);
      CREATE TABLE #{t("submissions")} (id bigint, assignment_id bigint, user_id bigint, workflow_state text,
        cached_due_date timestamp);
      CREATE TABLE #{schema}."content_participations" (id bigint, content_type text, content_id bigint,
        user_id bigint, workflow_state text);
    SQL
  end

  before do
    path = File.join(quaacks.home, ".pgpass")
    File.write(path, "*:#{production.port}:*:#{production.user}:#{production.password}\n")
    File.chmod(0o600, path)
    %w[qualify redact].each do |step|
      outcome = quaacks.run(step, "--run", store.run_id, env: operator_env)
      expect([step, outcome.stdout, outcome.stderr]).to eq([step, %({"type":"done"}\n), ""])
    end
  end

  after do
    quaacks.remove
    production.drop
  end

  def operator_env
    ENV.keys.grep(/\APG/).to_h { [it, nil] }
       .merge("PGPORT" => production.port.to_s, "PGUSER" => production.user, "PGDATABASE" => production.name)
  end

  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def redact_rewrite(sql) = quaacks.run("redact-rewrite", "--run", store.run_id, stdin: JSON.generate("sql" => sql))
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }
  def deparsed(sql) = Quaack::Enclave::Deparse.faithfully(PgQuery.parse(sql).tree)

  it "redacts the user's EXISTS rewrite whole, keeping only the EXISTS's SELECT 1 as written" do
    sql = rewrite(sentinel)
    outcome = redact_rewrite(sql)

    expect([outcome.stdout, outcome.status.exitstatus, outcome.stderr]).to eq([outcome.stdout, 0, ""])
    expect(lines(outcome).map { it["type"] }).to eq(%w[redacted_rewrite done])
    out = lines(outcome).first["sql"]
    expect(out).to eq(expected)
    # Every other literal took a placeholder that binds the user's value, in order.
    map = stored.read("placeholder_map")
    values = Quaack::Enclave::Redaction.literals(PgQuery.parse(sql)).sort.map(&:last)
    kept = values.index({ "value" => "1", "type" => "integer" })
    values.delete_at(kept)
    expect(out.scan(/\$(\d+)/).flatten.map { map.fetch("$#{it}") }).to eq(values)
    expect_no_leaks(sentinels, outcome)
  end

  # The positive control: the checks above would see the sentinel if it
  # were sent, since the store holds it where the same scan finds it.
  it "keeps the sentinel in the store, where the leak check would catch it" do
    held = JSON.generate(stored.read("placeholder_map"))
    expect(LeakCheck.findings(sentinels, stdout: held).join("\n")).to include(sentinels.needles[:text])
  end
end
