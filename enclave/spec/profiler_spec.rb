# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "quaack/enclave/profiler"

# QUAACKS_PROFILE's sampling profiler (task 20261004-23). rbspy can't attach
# to Ubuntu's packaged Ruby, so quaacks samples itself.
# counterexample_steps_postgres_spec.rb runs it through the installed
# quaacks, with sentinels in the run.
RSpec.describe Quaack::Enclave::Profiler do
  let(:dir) { Dir.mktmpdir("quaack-profile") }
  let(:path) { File.join(dir, "profile.txt") }

  after { FileUtils.rm_rf(dir) }

  # Spins for at least seconds of CPU on this line, so the sampler sees it.
  def spin(seconds)
    started = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    nil while Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - started < seconds
  end

  def spin_line = "#{__FILE__}:#{method(:spin).source_location.last + 2}"

  def profile = File.read(path).lines.drop(1).map { it.chomp.split("\t") }

  def samples = File.read(path).lines.first[/(\d+) samples/, 1].to_i

  # Busy in Ruby, the sampler runs only at thread switches, a few times a
  # second; waiting, it runs every 10 ms or so.
  it "counts each sampled line, self and total, busiest first" do
    result = described_class.during(path) do
      sleep 0.1
      spin(0.6)
      :done
    end

    expect(result).to eq(:done)
    header, *rows = File.read(path).lines
    expect(header).to match(/\A# quaacks profile: \d+ samples\. self, total, location\.\n\z/)
    expect(samples).to be > 4
    expect(rows).to all(match(/\A\d+\t\d+\t[^\t]+:\d+\n\z/))
    counts = profile.to_h { |own, total, location| [location, [own.to_i, total.to_i]] }
    expect(counts.fetch(spin_line).first).to be_positive
    expect(counts.values).to all(satisfy { |own, total| total.between?(own, samples) })
    expect(profile.map { it[1].to_i }).to eq(profile.map { it[1].to_i }.sort.reverse)
  end

  it "counts a line once a sample in total, however deep it recurses" do
    recurse = ->(n) { n.zero? ? sleep(0.1) : recurse.call(n - 1) }
    described_class.during(path) { recurse.call(5) }

    expect(samples).to be > 2
    expect(profile.map { it[1].to_i }.max).to eq(samples)
  end

  it "writes the profile when the block raises, and raises on" do
    expect do
      described_class.during(path) do
        spin(0.05)
        raise ArgumentError, "boom"
      end
    end.to raise_error(ArgumentError, "boom")

    expect(File.read(path)).to start_with("# quaacks profile: ")
  end

  it "makes the profile readable only by its owner" do
    described_class.during(path) { nil }

    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "stops sampling when the block ends" do
    before = Thread.list
    described_class.during(path) { spin(0.05) }

    expect(Thread.list - before).to eq([])
  end

  it "writes nothing to stdout or stderr, and doesn't fail the block when it can't write the profile" do
    out = StringIO.new
    err = StringIO.new
    unwritable = File.join(dir, "missing", "profile.txt")

    result = with_std(out, err) { described_class.during(unwritable) { :done } }

    expect([result, out.string, err.string, File.exist?(unwritable)]).to eq([:done, "", "", false])
  end

  it "does nothing without a path" do
    before = Thread.list
    results = [nil, ""].map { |none| described_class.during(none) { Thread.list - before } }

    expect(results).to eq([[], []])
    expect(Dir.children(dir)).to eq([])
  end

  def with_std(out, err)
    saved = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    yield
  ensure
    $stdout, $stderr = saved
  end
end
