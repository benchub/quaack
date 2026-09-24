# frozen_string_literal: true

require "json"
require "quaack/enclave/version"

# Runs exe/quaacks the way the jump server does, in its own process, and
# checks what comes out on stdout and stderr and how it exits.
RSpec.describe "quaacks executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaacks") }

  def usage_line(step) = %({"type":"error","step":"#{step}","rule":"usage"}\n)

  it "prints its version as one egress line for --version and for version" do
    [["--version"], ["version"]].each do |argv|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(%({"type":"version","version":"#{Quaack::Enclave::VERSION}"}\n)), "stderr was #{err}"
      expect(err).to eq("")
      expect(status.exitstatus).to eq(0)
    end
  end

  it "rejects anything else with one usage error line on stdout, nothing on stderr, and exit 64" do
    # An error names the step only when argv names one.
    { [] => "cli", ["--bogus"] => "cli", %w[some subcommand] => "cli", %w[extra --version] => "cli",
      %w[--version extra] => "version", %w[--version --version] => "version",
      %w[version --run 20260923T221500Z-0a1b2c3d] => "version" }.each do |argv, step|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(usage_line(step)), "argv #{argv.inspect} printed #{out.inspect} to stdout"
      expect(err).to eq(""), "argv #{argv.inspect} printed #{err.inspect} to stderr"
      expect(status.exitstatus).to eq(64), "argv #{argv.inspect} exited #{status.exitstatus}"
    end
  end
end
