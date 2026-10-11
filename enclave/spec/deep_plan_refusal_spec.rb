# frozen_string_literal: true

require "quaack/enclave/measurement"
require "quaack/enclave/index_build"
require "quaack/enclave/single_candidate_test"
require "quaack/enclave/error_filter"

# A plan nested deeper than PlainData::MAX_DEPTH is a clean refusal with a
# fixed rule, never a JSON::NestingError. Postgres can't easily produce a
# plan 3000 levels deep, so the server's EXPLAIN output is faked at the
# connection edge.
RSpec.describe "a plan deeper than PlainData::MAX_DEPTH" do
  let(:sentinel) { "SENTINEL_DEEP_PLAN_7c1" }
  let(:deep) do
    depth = Quaack::Enclave::PlainData::MAX_DEPTH + 10
    "#{"[" * depth}\"#{sentinel}\"#{"]" * depth}"
  end
  let(:result) { Struct.new(:text) { def getvalue(_row, _col) = text }.new(deep) }

  def expect_clean_line(error)
    line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "baseline")
    expect(JSON.parse(line)).to eq("type" => "error", "step" => "baseline", "rule" => "plan_too_deep")
    expect(line).not_to include(sentinel)
  end

  it "is plan_too_deep in Measurement.measure_set, with nothing from the plan" do
    run = Struct.new(:timed_out, :result).new(false, result)
    allow(Quaack::Enclave::RunDiscipline).to receive(:run).and_return(run)
    bound = Struct.new(:sql).new("SELECT 1")

    expect { Quaack::Enclave::Measurement.measure_set(nil, bound, [], {}, 1000) }
      .to raise_error(Quaack::Enclave::Measurement::Error, "plan_too_deep") { |e|
        expect_clean_line(e)
        expect(e.rule).to eq("plan_too_deep")
        expect(e.cause).to be_nil
      }
  end

  it "is plan_too_deep in IndexBuild.confirm, with nothing from the plan" do
    connection = double("connection")
    allow(connection).to receive(:exec_params).and_return(result)
    build = { "indexes" => { "quaack_a" => {} } }

    expect { Quaack::Enclave::IndexBuild.confirm(connection, build, [], sql: "SELECT 1") }
      .to raise_error(Quaack::Enclave::IndexBuild::Error, "plan_too_deep") { |e|
        expect_clean_line(e)
        expect(e.cause).to be_nil
      }
  end

  it "is explain_failed in SingleCandidateTest's plan parse, bounded like the others" do
    too_deep = Quaack::Enclave::PlainData::MAX_DEPTH + 1
    bounded = "#{"[" * too_deep}1#{"]" * too_deep}"
    expect { Quaack::Enclave::SingleCandidateTest.send(:parse_plan, bounded) }
      .to raise_error(Quaack::Enclave::SingleCandidateTest::Error) { |e| expect(e.message).not_to include("1]") }
    allowed = "#{"[" * 200}1#{"]" * 200}"
    expect(Quaack::Enclave::SingleCandidateTest.send(:parse_plan, allowed).flatten).to eq([1])
  end
end
