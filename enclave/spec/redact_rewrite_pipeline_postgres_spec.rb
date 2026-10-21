# frozen_string_literal: true

require "json"
require "pg_query"
require "quaack/enclave/store"
require "quaack/enclave/deparse"
require_relative "support/production_server"

# 20261020-3: redact-rewrite the way a real run reaches it. The store is
# filled by the real steps, through the installed quaacks outside Bundler:
# qualify (which writes qualified_query) and redact (the only step that
# writes redacted_query and placeholder_map; literals and clock-anchor read
# them and write other entries). The plan is a real EXPLAIN ANALYZE. Then
# redact-rewrite gets the operator's text, with its real constants, as the
# driver sends it. The query is a synthetic copy of the one that failed on
# the user's run, with made-up numbers.
RSpec.describe "quaacks redact-rewrite on a store the real steps filled" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:schema) { %("cluster44_shard_7236") }
  let(:user_id) { 3_141_592_653 }
  let(:context_ids) { (1..21).map { 700_000_000 + (it * 37) } }
  let(:assignment_ids) { (1..12).map { 900_000_000 + (it * 11) } }
  let(:sentinel) { sentinels.text }

  def t(table) = %(#{schema}."#{table}")

  # The user's query, as the app wrote it. The OR's left side is the
  # whole AND chain, as in the original.
  def query(unread:, state: "deleted")
    a = t("assignments")
    s = t("submissions")
    "SELECT #{a}.* FROM #{a} INNER JOIN #{s} ON #{s}.\"assignment_id\" = #{a}.\"id\" " \
      "AND #{s}.\"workflow_state\" <> '#{state}' " \
      "WHERE #{a}.\"workflow_state\" != '#{state}' AND #{a}.\"type\" = 'Assignment' " \
      "AND #{a}.\"context_type\" = 'Course' AND #{a}.\"context_id\" IN (#{context_ids.join(", ")}) " \
      "AND #{s}.\"user_id\" = #{user_id} AND #{s}.\"workflow_state\" != '#{state}' " \
      "AND #{s}.\"cached_due_date\" BETWEEN '2026-03-16 00:00:00' AND '2036-09-16 07:00:00' " \
      "AND ((#{a}.\"muted\" IS NULL OR NOT #{a}.\"muted\") AND #{exists(s, unread)}) " \
      "OR #{a}.\"id\" IN (#{assignment_ids.join(", ")})"
  end

  def exists(subs, unread)
    "EXISTS (SELECT 1 FROM #{t("content_participations")} cp " \
      "WHERE cp.content_type = 'Submission' AND cp.content_id = #{subs}.\"id\" AND cp.user_id = #{user_id} " \
      "AND cp.workflow_state = '#{unread}')"
  end

  # The sentinel stands in for a real value the run's store holds.
  let(:original) { query(unread: sentinel) }

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
      CREATE TABLE #{t("content_participations")} (id bigint, content_type text, content_id bigint,
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

  it "gives back the run's redacted_query for the original's own text, and never a value" do
    outcome = redact_rewrite(original)

    expect([outcome.status.exitstatus, outcome.stderr]).to eq([0, ""])
    expect(lines(outcome).map { it["type"] }).to eq(%w[redacted_rewrite done])
    # A literal whose comparison two placeholders share takes the lowest
    # of those that bind its value (RewriteRedaction.tied): $27, the
    # WHERE's submissions.workflow_state <> 'deleted', comes back as $1,
    # the ON's, which binds the same value. Any other difference is a bug.
    expected = stored.read("redacted_query").sub("workflow_state <> $27", "workflow_state <> $1")
    expect(stored.read("placeholder_map").values_at("$1", "$27").uniq.size).to eq(1)
    expect(deparsed(lines(outcome).first["sql"])).to eq(deparsed(expected))
    expect_no_leaks(sentinels, outcome)
  end

  # The positive control: the checks above would see the sentinel if it
  # were sent, since the store holds it where the same scan finds it.
  it "keeps the sentinel in the store, where the leak check would catch it" do
    held = JSON.generate(stored.read("placeholder_map"))
    expect(LeakCheck.findings(sentinels, stdout: held).join("\n")).to include(sentinels.needles[:text])
  end
end
