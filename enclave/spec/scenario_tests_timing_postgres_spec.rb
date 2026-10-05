# frozen_string_literal: true

require "quaack/enclave/scenario_tests"

# A guard against rewrite-test's Ruby CPU growing back (task 20261004-23): a
# seven-table join over a Rails-style schema once cost about 26 seconds of
# CPU per rewrite, most of it comparing and hashing whole fixture rows. It
# takes about 3 now. The bound is generous, so a slow machine or a busy
# Docker doesn't make it flaky, and it's CPU time, not wall time, so waiting
# on Postgres doesn't count.
RSpec.describe Quaack::Enclave::ScenarioTests do
  cpu_bound = 12

  let(:conn) { racetrack_and_arena.arena.connection }

  let(:sql) do
    <<~SQL
      SELECT c.id, c.body, t.title, u.email, tg.name FROM rs.comments c
      INNER JOIN rs.tasks t ON t.id = c.task_id
      INNER JOIN rs.projects p ON p.id = t.project_id
      INNER JOIN rs.users u ON u.id = c.author_id
      INNER JOIN rs.taggings tgg ON tgg.task_id = t.id
      INNER JOIN rs.tags tg ON tg.id = tgg.tag_id
      INNER JOIN rs.accounts a ON a.id = p.account_id
      WHERE a.subdomain = 'acme' AND p.slug = 'web' AND tg.name = 'bug' AND t.status IN ('open', 'in_progress')
        AND u.role = 'member' AND p.archived = false AND c.created_at > '2026-01-01'
      ORDER BY c.created_at DESC, c.id DESC LIMIT 25
    SQL
  end

  before do
    schema = File.read(File.join(GEM_ROOT, "spec/fixtures/rails_style_schema.sql")).gsub("public.", "rs.")
    conn.exec("CREATE SCHEMA rs; #{schema}")
  end

  it "tests a rewrite of a seven-table join on a Rails-style schema in under #{cpu_bound} seconds of CPU" do
    started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    report = described_class.run(conn, sql, [sql])
    spent = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started

    expect([report.refused, report.results.map(&:passed).uniq]).to eq([nil, [true]])
    expect(spent).to be < cpu_bound
  end

  # Where the time went. The bound above is loose, so these count the work
  # instead of timing it.
  describe "a build" do
    let(:builder) { Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql)) }

    # Parts tries each colliding group's retries against every fixture.
    it "builds each group's rows once" do
      built = []
      allow(builder).to(receive(:row).and_wrap_original { |original, *args| (built << args) && original.call(*args) })
      builder.build

      expect(built).not_to be_empty
      expect(built.size).to eq(built.uniq.size)
    end

    # Finding a slot's members once walked every column of every foreign
    # key: the stacks the user's gdb caught.
    it "finds each slot's members once for its atoms and once for its columns, however many builds" do
      topology = builder.instance_variable_get(:@topology)
      slots = []
      allow(topology).to(receive(:members).and_wrap_original { |members, slot| (slots << slot) && members.call(slot) })
      builder.build
      builder.build(0 => 1)

      expect(slots).not_to be_empty
      expect(slots.tally.values.max).to eq(2)
    end
  end
end
