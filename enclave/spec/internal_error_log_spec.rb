# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/internal_error_log"

RSpec.describe Quaack::Enclave::InternalErrorLog do
  let(:sentinel) { "SENTINEL_LOG_VALUE_7f3a" }
  let(:now) { Time.utc(2026, 11, 18, 12, 30, 5) }

  def file(dir) = File.join(dir, described_class::FILE_NAME)

  # An exception raised from where the backtrace names: the gem file first,
  # then the outside ones, each as Ruby writes a backtrace line.
  def raised(backtrace, klass: RuntimeError)
    error = klass.new("message #{sentinel}")
    error.set_backtrace(backtrace)
    error
  end

  def gem_line(rel, line) = "#{File.join(described_class::GEM_LIB, rel)}:#{line}:in 'm'"

  it "appends one line with the time, step, class, and the first gem-relative location, mode 0600" do
    Dir.mktmpdir do |dir|
      outside = "/opt/#{sentinel}/other.rb:9:in 'x'"
      error = raised([outside, gem_line("quaack/enclave/redaction.rb", 42), gem_line("quaack/enclave/cli.rb", 7)])
      2.times { described_class.append(dir, step: "redact-rewrite", exception: error, now:) }

      expect(File.read(file(dir))).to eq(
        "2026-11-18T12:30:05Z step=redact-rewrite class=RuntimeError at=quaack/enclave/redaction.rb:42\n" * 2
      )
      expect(File.stat(file(dir)).mode & 0o777).to eq(0o600)
    end
  end

  it "never writes the message or a location outside the gem" do
    Dir.mktmpdir do |dir|
      described_class.append(dir, step: "classify", exception: raised(["/x/#{sentinel}.rb:1:in 'y'"]), now:)

      text = File.read(file(dir))
      expect(text).to eq("2026-11-18T12:30:05Z step=classify class=RuntimeError at=none\n")
      expect(text).not_to include(sentinel)
    end
  end

  # Plain lowercase paths that the path-shape check alone would accept. A
  # relative one is what Ruby writes for a file loaded through a relative
  # load path.
  it "skips a plain lowercase location outside the gem and logs the gem one after it" do
    Dir.mktmpdir do |dir|
      outside = ["lib/pg/connection.rb:5:in 'x'", "/usr/lib/ruby/gems/x/lib/pg/connection.rb:5:in 'x'"]
      error = raised([*outside, gem_line("quaack/enclave/cli.rb", 7)])
      described_class.append(dir, step: "classify", exception: error, now:)
      described_class.append(dir, step: "classify", exception: raised(outside), now:)

      expect(File.read(file(dir))).to eq(
        "2026-11-18T12:30:05Z step=classify class=RuntimeError at=quaack/enclave/cli.rb:7\n" \
        "2026-11-18T12:30:05Z step=classify class=RuntimeError at=none\n"
      )
    end
  end

  it "leaves out a class name or step that isn't plain" do
    Dir.mktmpdir do |dir|
      anonymous = Class.new(StandardError)
      described_class.append(dir, step: "Bad #{sentinel}", exception: raised([], klass: anonymous), now:)

      expect(File.read(file(dir))).to eq("2026-11-18T12:30:05Z step=none class=none at=none\n")
    end
  end

  it "stops appending once the file reaches MAX_BYTES" do
    Dir.mktmpdir do |dir|
      File.write(file(dir), "x" * described_class::MAX_BYTES)
      described_class.append(dir, step: "classify", exception: raised([]), now:)

      expect(File.size(file(dir))).to eq(described_class::MAX_BYTES)
    end
  end

  it "doesn't follow a symlink at the file's name, and never raises" do
    Dir.mktmpdir do |dir|
      target = File.join(dir, "target")
      File.write(target, "")
      File.symlink(target, file(dir))

      expect(described_class.append(dir, step: "classify", exception: raised([]), now:)).to be_nil
      expect(described_class.append(File.join(dir, "gone"), step: "classify", exception: raised([]), now:)).to be_nil
      expect(File.read(target)).to eq("")
    end
  end
end
