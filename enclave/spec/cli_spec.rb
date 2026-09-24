# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/enclave/store"
require "quaack/enclave/version"

# Runs exe/quaacks the way the jump server does, in its own process, and
# checks what comes out on stdout and stderr and how it exits.
RSpec.describe "quaacks executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaacks") }

  def usage_line(step) = %({"type":"error","step":"#{step}","rule":"usage"}\n)
  # The line that ends every successful run, and no failed one.
  def done = %({"type":"done"}\n)

  it "prints its version line and then the done line for --version and for version" do
    [["--version"], ["version"]].each do |argv|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(%({"type":"version","version":"#{Quaack::Enclave::VERSION}"}\n#{done})), "stderr was #{err}"
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

  # CLI.main, the method the exe runs, with a test step plugged into the
  # steps table. The step's body is Ruby run inside the step.
  describe "CLI.main with a test step" do
    let(:sentinel) { "sentinel-4d81e2-ssn" }

    # step holds the Step's input: and run: settings. prelude runs after
    # the enclave loads and before main.
    def main(step_body, argv: ["probe"], stdin: "", prelude: "", **step)
      run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", <<~RUBY, *argv, stdin_data: stdin)
        require "quaack/enclave"
        #{prelude}
        cli = Quaack::Enclave::CLI
        handler = ->(**inputs) { #{step_body} }
        exit cli.main(ARGV, steps: { "probe" => cli::Step.new(handler:, **#{step.inspect}) })
      RUBY
    end

    def error_line(rule) = %({"type":"error","step":"probe","rule":"#{rule}"}\n)

    it "sends nothing a step writes itself, on stdout or stderr, only the messages it returns" do
      out, err, status = main(<<~RUBY)
        puts "#{sentinel} puts"; print "#{sentinel} print"; $stdout.write("#{sentinel} write")
        STDOUT.syswrite("#{sentinel} syswrite"); $stdout.flush
        system("echo #{sentinel} child; echo #{sentinel} child >&2")
        warn "#{sentinel} warn"; $stderr.puts "#{sentinel} stderr"; STDERR.syswrite("#{sentinel} fd2")
        Warning.warn("#{sentinel} warning")
        [{ type: :version, version: "1" }]
      RUBY

      expect(out).to eq(%({"type":"version","version":"1"}\n#{done}))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(0)
    end

    it "sends nothing a step writes to $stdout even if $stdout was pointed elsewhere before main" do
      out, err, status = main(%(puts "#{sentinel}"; $stdout.flush; [{ type: :version, version: "1" }]),
                              prelude: "$stdout = STDOUT.dup")

      expect(out).to eq(%({"type":"version","version":"1"}\n#{done}))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(0)
    end

    it "turns a step's exit or abort, whatever its status, into one error line and exit 70" do
      [%(abort "#{sentinel}"), "exit 0", "exit 3", "exit", "exit false"].each do |body|
        out, err, status = main("#{body}; [{ type: :version, version: '1' }]")

        expect(out).to eq(error_line("internal_error")), "#{body} printed #{out.inspect}"
        expect(err).to eq("")
        expect(status.exitstatus).to eq(70), "#{body} exited #{status.exitstatus}"
      end
    end

    # exit! ends the process at once, skipping every rescue and ensure, so
    # the CLI can't catch it. It prints nothing, not even the done line, so
    # the driver can tell it from a success that sent no messages.
    it "can't catch a step's exit!, which ends the process with nothing on stdout" do
      out, err, status = main("exit!(0)")

      expect(out).to eq("")
      expect(err).to eq("")
      expect(status.exitstatus).to eq(0)
    end

    it "sends a step's error as one error line, without its message, and exits 70" do
      out, err, status = main(%(raise ArgumentError, "#{sentinel}"))

      expect(out).to eq(error_line("internal_error"))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(70)
    end

    it "drops a field that isn't on the whitelist" do
      out, err, status = main(%([{ type: :version, version: "1", literal: "#{sentinel}" }]))

      expect(out).to eq(%({"type":"version","version":"1"}\n#{done}))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(0)
    end

    it "refuses bad stdin as bad_input, without its text, and exits 64" do
      out, err, status = main("[]", input: true, stdin: %({"sql": "#{sentinel}"))

      expect(out).to eq(error_line("bad_input"))
      expect(err).to eq("")
      expect(status.exitstatus).to eq(64)
    end

    it "passes the JSON object on stdin to a step that takes input" do
      out, err, status = main("[{ type: :version, version: inputs[:input].fetch('v') }]",
                              input: true, stdin: '{"v":"from stdin"}')

      expect(out).to eq(%({"type":"version","version":"from stdin"}\n#{done})), "stderr was #{err}"
      expect(status.exitstatus).to eq(0)
    end

    it "opens a run under the default base, ~/.quaack/runs" do
      Dir.mktmpdir("quaack-home") do |home|
        store = Quaack::Enclave::Store.create(base: File.join(home, ".quaack", "runs"))
        out, err, status = main("[{ type: :version, version: inputs[:store].run_id }]",
                                argv: ["probe", "--run", store.run_id], run: true,
                                prelude: "ENV['HOME'] = #{home.inspect}")

        expect(out).to eq(%({"type":"version","version":"#{store.run_id}"}\n#{done})), "stderr was #{err}"
        expect(status.exitstatus).to eq(0)
      end
    end

    it "sends a signal's error line and then dies by the signal" do
      out, err, status = main(%(Process.kill(:TERM, Process.pid); sleep 5; [{ type: :version, version: "1" }]))

      expect(out).to eq(error_line("internal_error"))
      expect(err).to eq("")
      expect(status.termsig).to eq(Signal.list.fetch("TERM"))
    end
  end
end
