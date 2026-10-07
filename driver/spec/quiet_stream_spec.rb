# frozen_string_literal: true

require "stringio"
require "quaack/driver/quiet_stream"

# QuietStream over real pipes: one whose reader is open, and one whose
# reader has closed, as when the program reading the stream exits. Ruby
# ignores SIGPIPE, so a write to the closed one raises Errno::EPIPE.
RSpec.describe Quaack::Driver::QuietStream do
  let(:pipe) { IO.pipe }

  # A writer left holding bytes for a closed reader raises EPIPE as it
  # closes, which is no part of what these examples check.
  after do
    pipe.each do |io|
      io.close unless io.closed?
    rescue Errno::EPIPE
      nil
    end
  end

  # Each write method, what it writes, and what it should answer on the
  # closed pipe.
  {
    print: [->(s) { s.print("a", "b\n") }, "ab\n", nil],
    puts: [->(s) { s.puts("a", "b") }, "a\nb\n", nil],
    write: [->(s) { s.write("a", "b\n") }, "ab\n", nil],
    printf: [->(s) { s.printf("%<a>s%<b>s\n", a: "a", b: "b") }, "ab\n", nil],
    putc: [->(s) { s.putc("a") }, "a", nil],
    "<<": [->(s) { s << "a" << "b\n" }, "ab\n", :stream]
  }.each do |name, (write, written, gone)|
    it "writes through with #{name} while the reader is open" do
      write.call(described_class.wrap(pipe.last))
      pipe.last.close

      expect(pipe.first.read).to eq(written)
    end

    it "skips #{name} quietly once the reader has closed" do
      pipe.first.close
      stream = described_class.wrap(pipe.last)

      expect(write.call(stream)).to eq(gone == :stream ? stream : gone)
      expect(stream.print("again\n")).to be_nil
    end
  end

  it "flushes through while the reader is open" do
    pipe.last.sync = false
    stream = described_class.wrap(pipe.last)
    stream.write("ab\n")
    stream.flush

    expect(pipe.first.read_nonblock(10)).to eq("ab\n")
  end

  it "skips flush quietly once the reader has closed, and every write after it" do
    pipe.first.close
    pipe.last.sync = false
    pipe.last.write("buffered\n")
    stream = described_class.wrap(pipe.last)

    expect(stream.flush).to be_nil
    expect(stream.print("again\n")).to be_nil
  end

  # $stdout holds what it's given until a flush, unlike IO.pipe's writer.
  # Ruby flushes $stdout before it starts a child process, so bytes held
  # for a closed reader would raise there, out of QuietStream's reach.
  it "writes through at once, holding nothing back, on a stream that would buffer" do
    pipe.last.sync = false
    described_class.wrap(pipe.last).print("ab\n")

    expect(pipe.first.wait_readable(0) && pipe.first.read_nonblock(10)).to eq("ab\n")
  end

  it "leaves nothing for a child process's flush to fail on once the reader has closed" do
    pipe.first.close
    pipe.last.sync = false
    stream = described_class.wrap(pipe.last)
    stream.print("lost\n")

    expect([stream.print("again\n"), pipe.last.flush]).to eq([nil, pipe.last])
  end

  it "skips writes quietly once the stream itself is closed" do
    pipe.last.close

    expect(described_class.wrap(pipe.last).print("a\n")).to be_nil
  end

  # Streams at the edge that fail as a full disk does, or as a socket whose
  # peer reset it. Losing the reader is only for show, but a full disk
  # isn't, so it still raises.
  full_disk = Class.new(StringIO) do
    def write(*) = raise(Errno::ENOSPC)
    def flush = raise(Errno::ENOSPC)
  end

  it "still raises a full disk on a write" do
    stream = described_class.wrap(full_disk.new)

    expect { stream.print("a\n") }.to raise_error(Errno::ENOSPC)
    expect { stream.write("a\n") }.to raise_error(Errno::ENOSPC)
  end

  it "still raises a full disk on a flush" do
    expect { described_class.wrap(full_disk.new).flush }.to raise_error(Errno::ENOSPC)
  end

  it "skips a write quietly once the connection is reset" do
    reset = Class.new(StringIO) { def write(*) = raise(Errno::ECONNRESET) }
    stream = described_class.wrap(reset.new)

    expect([stream.write("a\n"), stream.print("again\n")]).to eq([nil, nil])
  end
end
