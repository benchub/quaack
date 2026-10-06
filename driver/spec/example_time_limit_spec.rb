# frozen_string_literal: true

require "tmpdir"

# spec_helper fails an example that runs past the per-example limit, so a
# hang fails the suite with a clear message instead of hanging rake. This
# runs a throwaway suite under that spec_helper, with the limit set short.
RSpec.describe "the per-example time limit" do
  # Runs the spec file at path under spec_helper with the limit at
  # `limit` seconds. Returns [output, exit status], or fails if the run
  # itself is still going after `guard` seconds.
  def run_suite(path, limit:, guard: 60)
    env = { "QUAACK_EXAMPLE_TIME_LIMIT" => limit.to_s }
    Open3.popen2e(env, *rspec(path), chdir: File.dirname(path), pgroup: true) do |stdin, output, waiter|
      stdin.close
      reader = Thread.new { output.read }
      unless waiter.join(guard)
        Process.kill("KILL", -waiter.pid)
        raise "the suite was still running after #{guard}s, so the limit didn't stop it"
      end
      [reader.value, waiter.value]
    end
  end

  # RSpec on path, under spec_helper and no other options.
  def rspec(path)
    [RbConfig.ruby, "-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--",
     "--options", File::NULL, "--require", File.join(__dir__, "spec_helper"), path]
  end

  it "fails an example that runs past it, even one that rescues StandardError, and runs the rest" do
    Dir.mktmpdir("quaack-time-limit") do |dir|
      path = File.join(dir, "hangs_spec.rb")
      File.write(path, <<~RUBY)
        RSpec.describe "a suite" do
          it("hangs") { sleep }
          it("hangs and rescues") { begin; sleep; rescue StandardError; end }
          it("finishes") { expect(1).to eq(1) }
        end
      RUBY
      output, status = run_suite(path, limit: 1)

      expect(status.exitstatus).to eq(1), output
      expect(output).to include("3 examples, 2 failures")
      expect(output.scan("ran past 1s, the per-example limit (QUAACK_EXAMPLE_TIME_LIMIT). It probably hung.").size)
        .to eq(2)
    end
  end

  it "defaults to a limit far past the slowest example" do
    expect(ExampleTimeLimit.seconds({})).to eq(120)
  end
end
