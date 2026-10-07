# frozen_string_literal: true

require "quaack/driver/quiet_stream"

# QuietStream over real pipes: one whose reader is open, and one whose
# reader has closed, as when the program reading the stream exits. Ruby
# ignores SIGPIPE, so a write to the closed one raises Errno::EPIPE.
RSpec.describe Quaack::Driver::QuietStream do
  let(:pipe) { IO.pipe }

  after { pipe.each { it.close unless it.closed? } }

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
end
