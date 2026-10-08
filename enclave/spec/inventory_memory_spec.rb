# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/inventory/memory"

# The operator's memory command (DESIGN.md's inventory), run on the jump server with
# the production host filled in. Its output is the operator's, so it never
# goes into an error.
RSpec.describe Quaack::Enclave::Inventory::Memory do
  let(:memory) { described_class }
  let(:sentinels) { LeakCheck::Sentinels.new }
  let(:dir) { Dir.mktmpdir("quaack-memory") }

  after { FileUtils.rm_rf(dir) }

  def rule_of
    yield
    nil
  rescue Quaack::Enclave::Inventory::Error => e
    e.rule
  end

  describe ".parse" do
    {
      "68719476736" => 68_719_476_736,
      "68719476736\n" => 68_719_476_736,
      "  1024  \n" => 1024,
      "64GB" => 64 * (1024**3),
      "64 GB\n" => 64 * (1024**3),
      "64gb" => 64 * (1024**3),
      "64GiB" => 64 * (1024**3),
      "512 MiB" => 512 * (1024**2),
      "512mb" => 512 * (1024**2),
      "16384kB" => 16_384 * 1024,
      "16384 KiB" => 16_384 * 1024,
      "2TB" => 2 * (1024**4),
      "2 tib" => 2 * (1024**4),
      "1024 TB" => 1024**5,
      "1048576 GiB" => 1024**5,
      (1024**5).to_s => 1024**5
    }.each do |text, bytes|
      it "reads #{text.inspect} as #{bytes} bytes" do
        expect(memory.parse(text)).to eq(bytes)
      end
    end

    ["", "\n", "lots", "64 G", "64B", "64 PB", "-1", "0", "0GB", "1.5GB", "64GB extra", "64GB\n64GB", "0x40",
     "64\nGB", "１０２４", "64  GB", "1025 TB", ((1024**5) + 1).to_s, "9" * 40].each do |text|
      it "refuses #{text.inspect} as memory_command_bad_output" do
        expect(rule_of { memory.parse(text) }).to eq("memory_command_bad_output")
      end
    end
  end

  describe ".bytes" do
    it "runs the command with /bin/sh and reads its output" do
      expect(memory.bytes("printf '%s\\n' 32GB", "prod-db-3")).to eq(32 * (1024**3))
    end

    it "fills in {host} everywhere it appears, as one shell word" do
      command = %(test {host} = 'prod db;3' && test "x"{host} = 'xprod db;3' && echo 1024)

      expect(memory.bytes(command, "prod db;3")).to eq(1024)
    end

    it "refuses a command that exits with a failure as memory_command_failed" do
      expect(rule_of { memory.bytes("echo 1024; exit 3", "prod-db-3") }).to eq("memory_command_failed")
    end

    it "refuses output it can't read as memory_command_bad_output" do
      expect(rule_of { memory.bytes("echo lots", "prod-db-3") }).to eq("memory_command_bad_output")
    end

    it "refuses output past 256 bytes as memory_command_bad_output, even if it would parse" do
      expect(rule_of { memory.bytes("printf '%257s' 1024", "prod-db-3") }).to eq("memory_command_bad_output")
      expect(memory.bytes("printf '%256s' 1024", "prod-db-3")).to eq(1024)
    end

    it "gives the command 30 seconds by default" do
      expect(memory::TIMEOUT).to eq(30)
    end

    it "refuses a command that can't start as memory_command_failed" do
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)

      expect(rule_of { memory.bytes("echo 1024", "prod-db-3") }).to eq("memory_command_failed")
    end

    # A child left in the background can hold stdout open long after the
    # command is done. Its output is the command's once the shell exits,
    # and the child is stopped with the rest of the process group.
    it "doesn't wait for a background child that holds stdout, and stops it" do
      pid_file = File.join(dir, "pid")
      command = "sh -c 'echo $$ > #{pid_file}.new && mv #{pid_file}.new #{pid_file} && exec sleep 30' & " \
                "while [ ! -f #{pid_file} ]; do sleep 0.01; done; echo 64GB"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      bytes = memory.bytes(command, "prod-db-3", timeout: 10)

      expect(bytes).to eq(64 * (1024**3))
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      sleeper = Integer(File.read(pid_file))
      expect(gone_soon?(sleeper)).to be(true), "sleep #{sleeper} is still running"
    end

    # The shell's pid comes from the spawn, not from a pid file, which a
    # shell killed while still starting under load may not have written yet.
    # The sleep writes its own pid file once it's running, so a missing file
    # says the kill came before the sleep started, and the check would prove
    # nothing, not that the kill worked.
    it "stops a command that runs past its timeout, and everything it started, as memory_command_timed_out" do
      pids = []
      allow(Process).to receive(:spawn).and_wrap_original do |original, *args, **opts|
        original.call(*args, **opts).tap { pids << it }
      end
      pid_file = File.join(dir, "pid")
      command = "sh -c 'echo $$ > #{pid_file}.new && mv #{pid_file}.new #{pid_file} && exec sleep 30' & wait"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      rule = rule_of { memory.bytes(command, "prod-db-3", timeout: 1) }

      expect(rule).to eq("memory_command_timed_out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(File.exist?(pid_file)).to be(true), "the sleep never started before the timeout, so this proves nothing"
      expect(pids.size).to eq(1)
      sleeper = Integer(File.read(pid_file))
      expect(gone_soon?(sleeper)).to be(true), "sleep #{sleeper} is still running"
      expect(gone_soon?(-pids.first)).to be(true), "process group #{pids.first} is still running"
      expect { Process.wait(pids.first, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    ensure
      # If the kill missed the group, don't leave the sleep running.
      pids&.each do |pid|
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    it "keeps the command's stdout and stderr out of its error, and off this process's stderr" do
      s = sentinels
      command = "echo #{s.text}; echo #{s.word} >&2; exit 3"
      error = nil

      expect { error = capture_error { memory.bytes(command, "prod-db-3") } }.not_to output.to_stderr_from_any_process

      expect(error.rule).to eq("memory_command_failed")
      expect_no_leaks(sentinels, objects: { error: })
    end

    it "keeps unreadable output out of its error" do
      error = capture_error { memory.bytes("echo #{sentinels.text}", "prod-db-3") }

      expect(error.rule).to eq("memory_command_bad_output")
      expect_no_leaks(sentinels, objects: { error: })
    end

    it "times out a command that closes its stdout and keeps running" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      rule = rule_of { memory.bytes("exec >&-; sleep 30", "prod-db-3", timeout: 0.5) }

      expect(rule).to eq("memory_command_timed_out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    end

    it "gives the command no stdin, not even this process's" do
      bytes = with_stdin("#{sentinels.text}\n") { memory.bytes("test -z \"$(cat)\" && echo 1024", "prod-db-3") }

      expect(bytes).to eq(1024)
    end
  end

  # Runs the block with this process's stdin, file descriptor 0, reading
  # text, so a child process that inherited it would read text too.
  def with_stdin(text)
    saved = STDIN.dup # rubocop:disable Style/GlobalStdStream
    IO.pipe do |reader, writer|
      writer.write(text)
      writer.close
      STDIN.reopen(reader) # rubocop:disable Style/GlobalStdStream
      yield
    end
  ensure
    STDIN.reopen(saved) # rubocop:disable Style/GlobalStdStream
    saved.close
  end

  def capture_error
    yield
    raise "expected an Inventory::Error"
  rescue Quaack::Enclave::Inventory::Error => e
    e
  end

  # Whether pid, or with a negative pid its whole process group, ends within
  # two seconds. The killed sleep's parent was the shell, so once the shell
  # is gone, init reaps it.
  def gone_soon?(pid)
    20.times do
      Process.kill(0, pid)
      sleep 0.1
    end
    false
  rescue Errno::ESRCH
    true
  end
end
