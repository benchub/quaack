# frozen_string_literal: true

require "delegate"
require "quaack/enclave/scenario_tests"

# rewrite-test asks Postgres about each CHECK value once per run, not once per
# row, group, retry, or build. A Canvas-like schema, with several
# workflow_state-style CHECK IN lists of eight values, once sent tens of
# thousands of the same probes.
RSpec.describe Quaack::Enclave::Scenarios::Checks do
  # Counts what the code under test sends; the connection itself is real.
  counting = Class.new(SimpleDelegator) do
    def sent = @sent ||= []

    %i[exec exec_params].each do |name|
      define_method(name) do |sql, params = nil, *rest|
        sent << [sql, params&.map { it.is_a?(Hash) ? it[:value] : it }]
        __getobj__.public_send(name, sql, *[params, *rest].compact)
      end
    end
  end

  let(:conn) { counting.new(racetrack_and_arena.arena.connection) }

  states = %w[active invited creation_pending deleted rejected completed inactive pending]
  kinds = %w[created claimed available completed deleted processing complete archived]
  list = ->(values) { "ARRAY[#{values.map { "'#{it}'::character varying" }.join(", ")}]::text[]" }
  check = ->(column, values) { "#{column} varchar(255) NOT NULL CHECK (#{column}::text = ANY (#{list.call(values)}))" }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA cv;
      CREATE TABLE cv.accounts (id bigserial PRIMARY KEY, name varchar(255), #{check.call("workflow_state", states)});
      CREATE TABLE cv.users (id bigserial PRIMARY KEY, name varchar(255), #{check.call("workflow_state", states)},
        #{check.call("kind", kinds)});
      CREATE TABLE cv.courses (id bigserial PRIMARY KEY, account_id bigint NOT NULL REFERENCES cv.accounts,
        name varchar(255), #{check.call("workflow_state", kinds)}, #{check.call("sis_state", states)},
        seats integer NOT NULL CHECK (seats >= 0));
      CREATE TABLE cv.enrollments (id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES cv.users,
        course_id bigint NOT NULL REFERENCES cv.courses, #{check.call("type", kinds)},
        #{check.call("workflow_state", states)}, #{check.call("role_state", kinds)}, created_at timestamp NOT NULL);
    SQL
  end

  let(:sql) do
    "SELECT e.id, c.name, u.name FROM cv.enrollments e JOIN cv.courses c ON c.id = e.course_id " \
      "JOIN cv.users u ON u.id = e.user_id WHERE e.workflow_state = 'active' AND c.workflow_state <> 'deleted'"
  end

  # Each atom and CHECK probe binds a value in place of the column as $1.
  def probes = conn.sent.select { |q, _| q.start_with?("SELECT $1") }

  it "probes each atom and CHECK once per value, and a second build sends nothing" do
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    conn.sent.clear
    first = builder.build
    sent = probes
    expect(sent).not_to be_empty
    expect(sent.size).to eq(sent.uniq.size)
    expect(conn.sent.size).to be < 500

    conn.sent.clear
    expect(builder.build).to eq(first)
    expect(conn.sent.map(&:first).uniq).to eq([])
  end

  # Only sorting a CHECK's own values casts its literal (0) to the
  # column's type; the typical value, 0, already passes seats >= 0.
  it "sorts a CHECK's own values only when no preferred value passes" do
    first = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql)).build
    seats = first[:s1].find { it.table.name == "courses" }.then { it.values[it.columns.index("seats")] }
    expect(seats).to eq("0")
    expect(conn.sent.map(&:first).grep(/CAST\(q\.v AS integer\)/)).to eq([])
  end

  it "runs rewrite-test on the join in a few hundred queries" do
    Quaack::Enclave::ScenarioTests.run(conn, sql, [sql])
    expect(probes.size).to eq(probes.uniq.size)
    expect(conn.sent.size).to be < 1500
  end
end
