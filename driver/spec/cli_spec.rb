# frozen_string_literal: true

require "quaack/driver/version"

RSpec.describe "quaack executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaack") }

  it "prints its version for --version" do
    out, err, status = run_ruby(exe, "--version")

    expect(out).to eq("quaack #{Quaack::Driver::VERSION}\n"), "stderr was #{err}"
    expect(status.exitstatus).to eq(0)
  end

  it "rejects anything else with a usage message on stderr and nothing on stdout" do
    [[], ["--bogus"], %w[some subcommand]].each do |argv|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(""), "argv #{argv.inspect} printed #{out.inspect} to stdout"
      expect(err).to eq("Usage: quaack --version\n"), "argv #{argv.inspect} printed #{err.inspect}"
      expect(status.exitstatus).to eq(64), "argv #{argv.inspect} exited #{status.exitstatus}"
    end
  end
end
