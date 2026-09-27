# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/driver/cli"

RSpec.describe "quaack executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaack") }

  it "prints its version for --version" do
    out, err, status = run_ruby(exe, "--version")

    expect(out).to eq("quaack #{Quaack::Driver::VERSION}\n"), "stderr was #{err}"
    expect(status.exitstatus).to eq(0)
  end

  describe "start" do
    let(:dir) { Dir.mktmpdir("quaack-cli-start") }

    after { FileUtils.rm_rf(dir) }

    # Shell that answers `quaacks version` as a jump server with version.
    def version_answer(version = Quaack::Driver::ENCLAVE_VERSION)
      "case \"$*\" in *\" quaacks version\") " \
        "printf '{\"type\":\"version\",\"version\":\"#{version}\"}\\n{\"type\":\"done\"}\\n'; exit;; esac"
    end

    # A fake ssh first on PATH that answers version as the expected one and
    # any other call with one run message, and a driver config whose
    # jump_command prints jump-1.
    def env
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p([bin, File.join(dir, ".quaack")])
      File.write(File.join(bin, "ssh"), <<~SH)
        #!/bin/sh
        #{version_answer}
        printf '%s\\n' "$*" > '#{dir}/ssh-args'
        printf '{"type":"run","run_id":"20260926T010203Z-0123abcd"}\\n{"type":"done"}\\n'
      SH
      FileUtils.chmod(0o755, File.join(bin, "ssh"))
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "echo jump-1"}')
      { "HOME" => dir, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
    end

    it "prints the run ID of the run it started" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "prod-1", "--query", "/q",
                                        "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args"))).to include("jump-1 quaacks intake --query /q --plan /p")
    end

    it "refuses a jump server with another quaacks version before intake, pointing to quaack deploy" do
      e = env
      script = File.join(dir, "bin", "ssh")
      File.write(script, File.read(script).sub(version_answer, version_answer("0.0.9")))
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: jump-1 has quaacks 0.0.9, but this driver needs " \
                    "#{Quaack::Driver::ENCLAVE_VERSION}. Run `quaack deploy --host jump-1`.\n", 1])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "prints only the rule when it fails, and exits 1" do
      e = env
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "exit 1"}')
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus]).to eq(["", "quaack start failed: jump_command_failed\n", 1])
    end

    # The enclave's error line carries only the rule, so the driver adds the
    # parser note itself.
    it "names the parser's Postgres version when intake can't parse the query" do
      e = env
      File.write(File.join(dir, "bin", "ssh"), <<~SH)
        #!/bin/sh
        #{version_answer}
        printf '{"type":"error","step":"intake","rule":"query_unparsable"}\\n'
        exit 70
      SH
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: query_unparsable (pg_query parses with the Postgres 17 grammar; " \
                    "Postgres 18-only syntax isn't supported yet)\n", 1])
    end

    it "rejects missing options with the usage message" do
      out, err, status = run_ruby(exe, "start", "--server", "p")

      expect([out, status.exitstatus]).to eq(["", 64])
      expect(err).to include("quaack start --server")
    end
  end

  it "rejects anything else with a usage message on stderr and nothing on stdout" do
    [[], ["--bogus"], %w[some subcommand], %w[--version extra], %w[extra --version],
     %w[--version --version]].each do |argv|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(""), "argv #{argv.inspect} printed #{out.inspect} to stdout"
      expect(err).to eq(Quaack::Driver::CLI::USAGE), "argv #{argv.inspect} printed #{err.inspect}"
      expect(status.exitstatus).to eq(64), "argv #{argv.inspect} exited #{status.exitstatus}"
    end
  end
end
