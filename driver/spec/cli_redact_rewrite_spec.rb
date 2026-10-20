# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/driver/cli"
require "quaack/driver/enclave_error"
require "quaack/driver/runs"

# `quaack redact-rewrite --run <ID>` (DESIGN.md's redact-rewrite): the rewrite
# with real literals comes in on stdin and goes to the enclave over ssh's
# stdin, never on a command line or to disk. ssh is the edge, so the
# transport is a fake that records each call.
RSpec.describe "quaack redact-rewrite" do
  let(:home) { Dir.mktmpdir("quaack-cli-redact-rewrite") }
  let(:run_id) { "20260926T010203Z-0123abcd" }
  let(:sentinel) { "SENTINEL-driver-redact-5e1d" }
  let(:rewrite) { "SELECT o.id FROM orders o WHERE o.note = '#{sentinel}'\n" }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:reply) { [{ "type" => "redacted_rewrite", "sql" => "SELECT o.id FROM orders o WHERE o.note = $1" }] }
  let(:failure) { nil }
  let(:transport) do
    replies = { "version" => [{ "type" => "version", "version" => Quaack::Driver::ENCLAVE_VERSION }],
                "redact-rewrite" => reply }
    f = failure
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:call) do |subcommand, **options|
        @calls << [subcommand, options]
        raise f if f && subcommand == "redact-rewrite"

        Data.define(:messages).new(messages: replies.fetch(subcommand))
      end
    end.new
  end
  let(:hosts) { [] }

  def cli(input = rewrite)
    t = transport
    h = hosts
    Quaack::Driver::CLI.new(stdout:, stderr:, home:, stdin: StringIO.new(input),
                            transport: ->(host, **) { (h << host) && t })
  end

  # Every file under home, with its text: the run record and anything else.
  def files = Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).select { File.file?(it) }.map { File.read(it) }

  before { Quaack::Driver::Runs.new(home).record(run_id, "jump-1") }
  after { FileUtils.rm_rf(home) }

  it "sends the rewrite on the enclave's stdin and prints only the placeholders" do
    before = files
    expect(cli.run(["redact-rewrite", "--run", run_id])).to eq(0)
    expect(stdout.string).to eq("SELECT o.id FROM orders o WHERE o.note = $1\n")
    expect(hosts).to eq(["jump-1"])
    expect(transport.calls.last).to eq(["redact-rewrite", { args: { run: run_id }, input: { "sql" => rewrite } }])
    # Only the input carries the sentinel: no argument does.
    expect(transport.calls.last[1][:args].to_s).not_to include(sentinel)
    expect(stdout.string + stderr.string).not_to include(sentinel)
    expect(files).to eq(before)
    expect(files.join).not_to include(sentinel)
  end

  it "would see the sentinel where it went: in the input sent" do
    cli.run(["redact-rewrite", "--run", run_id])
    expect(transport.calls.last[1][:input].to_s).to include(sentinel)
  end

  context "when the enclave refuses a literal" do
    let(:failure) do
      Quaack::Driver::EnclaveError.new(subcommand: "redact-rewrite", rule: "redact_rewrite_no_match",
                                       step: "redact-rewrite", position: 42, exit_status: 64)
    end

    it "names the rule and the position, and never the literal" do
      expect(cli.run(["redact-rewrite", "--run", run_id])).to eq(1)
      expect(stdout.string).to eq("")
      expect(stderr.string).to include("redact_rewrite_no_match")
        .and include("The literal at character 42. It has no comparison")
      expect(stderr.string).not_to include(sentinel)
    end
  end

  context "when the enclave finds a literal ambiguous (20261020-1)" do
    let(:failure) do
      Quaack::Driver::EnclaveError.new(subcommand: "redact-rewrite", rule: "redact_rewrite_ambiguous",
                                       step: "redact-rewrite", position: 42, candidates: [1, 2, 36], exit_status: 64)
    end

    it "names the candidate placeholders, and never the literal" do
      expect(cli.run(["redact-rewrite", "--run", run_id])).to eq(1)
      expect(stderr.string).to include("The literal at character 42 could take $1, $2, or $36")
      expect(stderr.string).not_to include(sentinel)
    end
  end

  it "says in its usage that a failed run leaves the redirect's file empty" do
    expect(cli.run(["redact-rewrite"])).to eq(64)
    expect(stderr.string).to include("a failed run leaves the redirect's file empty")
  end

  it "takes no --file or other argument that could hold the statement" do
    expect(cli.run(["redact-rewrite", "--run", run_id, "--file", "x.sql"])).to eq(64)
    expect(transport.calls).to eq([])
  end

  it "refuses empty stdin before touching the jump server" do
    expect(cli("").run(["redact-rewrite", "--run", run_id])).to eq(64)
    expect(stderr.string).to eq("quaack redact-rewrite: no SQL on stdin\n")
    expect(transport.calls).to eq([])
  end

  it "refuses a run this laptop never started" do
    expect(cli.run(["redact-rewrite", "--run", "20260926T010203Z-ffffffff"])).to eq(64)
    expect(stderr.string).to eq("quaack redact-rewrite: unknown run ID\n")
  end
end

RSpec.describe "Transport::ErrorFields for redact-rewrite" do
  before { require "quaack/driver/transport/error_fields" }

  def fields(line) = Quaack::Driver::Transport::ErrorFields.call(line)

  it "keeps a positive Integer position only on a redact-rewrite refusal" do
    expect(fields("rule" => "redact_rewrite_ambiguous", "position" => 7)[:position]).to eq(7)
    expect(fields("rule" => "redact_rewrite_no_match", "position" => "7")[:position]).to be_nil
    expect(fields("rule" => "bad_input", "position" => 7)[:position]).to be_nil
  end

  it "keeps ascending positive Integer candidates only on an ambiguous refusal" do
    expect(fields("rule" => "redact_rewrite_ambiguous", "candidates" => [1, 36])[:candidates]).to eq([1, 36])
    expect(fields("rule" => "redact_rewrite_no_match", "candidates" => [1, 36])[:candidates]).to be_nil
    [[1, "SENTINEL-x"], [3], [2, 1], [0, 1], "1, 2", (1..65).to_a].each do |bad|
      expect(fields("rule" => "redact_rewrite_ambiguous", "candidates" => bad)[:candidates]).to be_nil
    end
  end
end
