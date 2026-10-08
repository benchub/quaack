# frozen_string_literal: true

require "quaack/driver/enclave_error"

# Task 20261007-29: the driver's words for each enclave rule. The error line
# holds only the rule and its shape-class fields, so the words are the
# driver's own fixed text, and the facts beside them are the checked fields.
RSpec.describe Quaack::Driver::FixedNotes do
  def error(rule, **fields) = Quaack::Driver::EnclaveError.new(subcommand: "run-server", rule:, **fields)

  let(:next_step) { "resume with `quaack setup --run R1`" }

  it "gives a rule an operator can act on its own words, ending with what to do next" do
    expect(error("run_server_autovacuum_on").rule_with_note(next_step:))
      .to eq("run_server_autovacuum_on: Autovacuum is on on the run server. Turn it off there, with " \
             "autovacuum = off. To go on, resume with `quaack setup --run R1`")
  end

  it "says a rule whose words end with what to do next goes on" do
    expect(error("run_server_autovacuum_on").to_go_on?).to be(true)
    expect(error("teardown_failed").to_go_on?).to be(false)
  end

  # The review of 20261007-29: a plan gate mismatch is the operator's to
  # fix, from PlanGate::MISMATCH_DETAIL's words.
  it "says a plan gate mismatch likely means stale statistics, and how to fix them" do
    expect(error("plan_gate_mismatch_likely_stale_statistics").rule_with_note(next_step:))
      .to eq("plan_gate_mismatch_likely_stale_statistics: The racetrack's plan for the slow literals doesn't " \
             "match production's plan. The likely cause is that the racetrack's statistics don't match " \
             "production's, such as a backup older than the statistics QUAACK read from production. Restore a " \
             "fresh backup on the run server, or run ANALYZE in the racetrack database. To go on, resume with " \
             "`quaack setup --run R1`")
  end

  it "says a plan the gate can't compare is a query QUAACK v1 can't tune, not a bug" do
    expect(error("plan_gate_not_comparable").rule_with_note(next_step:))
      .to eq("plan_gate_not_comparable: A plan has a condition QUAACK can't compare, so it can't tell whether " \
             "the racetrack plans the query as production did. QUAACK v1 can't tune this query")
  end

  it "leaves the next step to teardown for a teardown rule" do
    expect(error("teardown_failed").rule_with_note(next_step:))
      .to eq("teardown_failed: QUAACK couldn't finish deleting the run's store on the jump server, " \
             "and part of it is still there")
  end

  it "gives an internal rule the shared line, with the step" do
    expect(error("index_build_unique", step: "index-build").rule_with_note(next_step:))
      .to eq("index_build_unique (step index-build): QUAACK hit an internal check it can't recover from. " \
             "This is a QUAACK bug: report the rule name and the step.")
  end

  it "gives an internal rule the shared line without a step when the error line had none" do
    expect(error("internal_error").rule_with_note)
      .to eq("internal_error: QUAACK hit an internal check it can't recover from. " \
             "This is a QUAACK bug: report the rule name and the step.")
  end

  it "gives every missing_<entry> rule the store's words" do
    expect(error("missing_index_search_rewrite_3").rule_with_note(next_step:))
      .to eq("missing_index_search_rewrite_3: #{described_class::MISSING_ENTRY.sub("{next}", next_step).chomp(".")}")
    expect(described_class::MISSING_ENTRY).to include("{next}")
  end

  it "gives an exact rule that starts with missing_ its own words, not the store's" do
    expect(error("missing_columns").rule_with_note).to include("internal check")
  end

  it "puts an intake refusal's reason before its words" do
    expect(error("query_unreadable", reason: "symlink").rule_with_note(next_step: "run `quaack start` again"))
      .to eq("query_unreadable: path is a symlink on the jump server. QUAACK couldn't read the query file on the " \
             "jump server. Check the --query path you gave quaack start, then run `quaack start` again")
  end

  it "names the volatile function before the words" do
    expect(error("volatile_function", function: "pg_catalog.random").rule_with_note)
      .to start_with("volatile_function: pg_catalog.random. The query calls a volatile function")
  end

  it "names the other clients before the words" do
    clients = [{ "pid" => 42, "backend_start" => "2026-10-08T01:02:03Z" }]

    expect(error("run_server_other_clients", clients:).rule_with_note)
      .to start_with("run_server_other_clients: pid 42 started 2026-10-08T01:02:03Z. Another client is connected")
  end

  it "keeps every note to fixed text, with no placeholder but {next}" do
    texts = [*described_class::BY_RULE.values, described_class::MISSING_ENTRY, described_class::INTERNAL_NOTE]

    expect(texts.map { it.gsub("{next}", "") }.grep(/[{}]|<[a-z]/)).to eq([])
  end

  it "doesn't give a rule both its own words and the shared line" do
    expect(described_class::BY_RULE.keys & described_class::INTERNAL).to eq([])
    expect(described_class::CODED & (described_class::BY_RULE.keys + described_class::INTERNAL)).to eq([])
  end
end
