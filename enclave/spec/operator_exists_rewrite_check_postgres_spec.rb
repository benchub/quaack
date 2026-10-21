# frozen_string_literal: true

require_relative "support/index_search_run"

# 20261021-1: the user's run. The original is the assignments and submissions
# join with an IN over a UNION ALL (as in redact_rewrite_exists_pipeline_postgres_spec.rb),
# the operator's rewrite an EXISTS. redact-rewrite reuses the original's
# placeholders and leaves some unused; rewrite-check, as operator-rewrites
# calls it, must accept it. Synthetic copy with made-up numbers.
RSpec.describe "rewrite-check of the user's redacted EXISTS rewrite, against a real server" do
  include_context "an index search run"

  let(:schema) { "cluster44_shard_7236" }
  let(:user_id) { 3_141_592_653 }
  let(:context_ids) { (1..21).map { 700_000_000 + (it * 37) } }
  let(:assignment_ids) { (1..12).map { 900_000_000 + (it * 11) } }
  let(:query) { original(sentinels.text) }

  def one_line(sql) = sql.split.join(" ").gsub("( ", "(")
  def ids(list) = list.join(", ")
  def t(table) = %(#{schema}."#{table}")

  def join
    %(INNER JOIN #{t("submissions")} ON "submissions"."assignment_id" = "assignments"."id" \
      AND (submissions.workflow_state <> 'deleted'))
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

  def original(unread)
    one_line(<<~SQL)
      SELECT COUNT(*) FROM #{t("assignments")} #{join}
      WHERE "assignments"."type" = 'Assignment' AND ("assignments"."id" IN (#{union(unread)}))
      AND #{submission_filters}
    SQL
  end

  def union(unread)
    one_line(<<~SQL)
      (SELECT "assignments"."id" FROM #{t("assignments")} #{join}
      INNER JOIN #{t("content_participations")} ON "content_participations"."content_type" = 'Submission'
      AND "content_participations"."content_id" = "submissions"."id" WHERE #{scope}
      AND (assignments.muted IS NULL OR NOT assignments.muted) AND "content_participations"."user_id" = #{user_id}
      AND "content_participations"."workflow_state" = '#{unread}') UNION ALL
      (SELECT "assignments"."id" FROM #{t("assignments")} WHERE #{scope}
      AND "assignments"."id" IN (#{ids(assignment_ids)}))
    SQL
  end

  def rewrite(unread)
    one_line(<<~SQL)
      SELECT COUNT(*) FROM #{t("assignments")} #{join} WHERE #{scope} AND #{submission_filters}
      AND (((assignments.muted IS NULL OR NOT assignments.muted) AND #{exists(unread)})
      OR assignments.id IN (#{ids(assignment_ids)}))
    SQL
  end

  def exists(unread)
    one_line(<<~SQL)
      EXISTS (SELECT 1 FROM #{t("content_participations")} cp WHERE cp.content_type = 'Submission'
      AND cp.content_id = submissions.id AND cp.user_id = #{user_id} AND cp.workflow_state = '#{unread}')
    SQL
  end

  def seed(conn)
    conn.exec(<<~SQL)
      CREATE SCHEMA #{schema};
      CREATE TABLE #{t("assignments")} (id bigint, workflow_state text, type text, context_type text,
        context_id bigint, muted boolean);
      CREATE TABLE #{t("submissions")} (id bigint, assignment_id bigint, user_id bigint, workflow_state text,
        cached_due_date timestamp);
      CREATE TABLE #{t("content_participations")} (id bigint, content_type text, content_id bigint,
        user_id bigint, workflow_state text);
      ANALYZE;
    SQL
  end

  def tables
    %w[assignments submissions content_participations].map { Quaack::Enclave::TableName.new(schema:, name: it) }
  end

  def capture_and_classify(conn, explain)
    store.write("plan", explain)
    store.write("qualified_query", query)
    store.write("relations", tables.map { { "schema" => schema, "name" => it.name } })
    Quaack::Enclave::PlannerStatistics.run(store:, connection: conn, relations: tables)
    Quaack::Enclave::PiiClassification.run(store:, config: Quaack::Enclave::Config.new({}))
  end

  define_negated_matcher :not_include, :include

  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def check(sql)
    candidate = { "sql" => sql, "transformation" => "t", "assumptions" => [] }
    checked = run_step("rewrite-check", JSON.generate("rewrites" => [candidate], "inferred" => true))
    expect_no_leaks(sentinels, checked)
    lines(checked).first
  end

  # The BETWEEN's timestamps stay string literals, as in the user's file.
  def with_timestamps(sql)
    sql.sub(/BETWEEN \$\d+ AND \$\d+/, "BETWEEN '2026-03-16 00:00:00' AND '2036-09-16 07:00:00'")
  end

  it "accepts it, though it leaves some of the original's placeholders unused" do
    prepare
    redacted = run_step("redact-rewrite", JSON.generate("sql" => rewrite(sentinels.text)))
    sql = lines(redacted).first.fetch("sql")
    expect(sql).to include("$1 ", "$2 ").and(not_include("$3,", "$5,"))
    expect(check(sql)).to include("outcome" => "accepted", "rule" => nil)
    expect(check(with_timestamps(sql))).to include("outcome" => "accepted", "rule" => nil)
  end

  # The user's own numbering, which doesn't match this original's: $17 is a
  # context_id here, a bigint, compared with the text cp.content_type. That
  # doesn't prepare, but not for an untyped literal.
  it "refuses a rewrite whose placeholders don't match the original's types as failed_to_plan" do
    prepare
    sql = with_timestamps(lines(run_step("redact-rewrite", JSON.generate("sql" => rewrite(sentinels.text))))
                            .first.fetch("sql")).sub("cp.content_type = $4", "cp.content_type = $17")
    expect(check(sql)).to include("outcome" => "rejected", "rule" => "failed_to_plan")
  end

  def run_step(step, stdin) = quaacks.run(step, "--run", store.run_id, stdin:, env: libpq_env)
end
