# frozen_string_literal: true

require "quaack/enclave/pg_array"

RSpec.describe Quaack::Enclave::PgArray do
  it "keeps its helpers off the public API" do
    expect(%i[elements element unreadable].select { |name| described_class.respond_to?(name) }).to eq([])
  end

  describe ".parse" do
    it "splits a plain array into its elements" do
      expect(described_class.parse("{delivered,shipped,pending}")).to eq(%w[delivered shipped pending])
    end

    it "reads an empty array as an empty Array" do
      expect(described_class.parse("{}")).to eq([])
    end

    it "reads an unquoted NULL, in any case, as nil, and a quoted one as the text" do
      expect(described_class.parse('{a,NULL,null,"NULL"}')).to eq(["a", nil, nil, "NULL"])
    end

    it "unquotes quoted elements and undoes their backslash escapes" do
      text = '{"a b","x,y","q\\"uote","back\\\\slash","{brace}","","NULL",plain}'

      expect(described_class.parse(text)).to eq(["a b", "x,y", 'q"uote', 'back\\slash', "{brace}", "", "NULL", "plain"])
    end

    it "reads back what Postgres prints for a text array, whatever the elements hold" do
      elements = ["plain", "two words", "comma,inside", 'a "quote"', "back\\slash", "{braces}", "", "NULL", "null",
                  " leading", "tab\there", "new\nline", "café \u{1F986}", "trailing\\", "\\\"", "'single'"]
      placeholders = elements.each_index.map { |i| "$#{i + 1}::text" }.join(", ")
      printed = test_database.connection.exec_params("SELECT ARRAY[#{placeholders}]::text", elements).getvalue(0, 0)

      expect(printed).to include('"a \\"quote\\""') # Postgres did quote and escape
      expect(described_class.parse(printed)).to eq(elements)
    end

    # The text is value-class data, like the MCVs it holds, so no message
    # quotes it.
    describe "text it can't read" do
      let(:sentinel) { "SENTINEL-9e02d4" }

      def message_of
        yield
        raise "expected an error"
      rescue ArgumentError => e
        e.full_message(highlight: false)
      end

      it "raises ArgumentError for anything but a one-dimensional array as Postgres prints one, without quoting it" do
        s = sentinel
        [s, "{#{s}", "#{s}}", "{#{s}}x", "{{#{s}},{b}}", "[0:1]={#{s},b}", "{\"#{s}}", "{#{s},,b}", "{#{s},}",
         "{,#{s}}", "{\"#{s}\"x}", "{#{s} ,b}", "{\"#{s}\\\"}", "", "{"].each do |bad|
          message = message_of { described_class.parse(bad) }

          expect(message).to include("isn't a one-dimensional Postgres array"), bad
          expect(message).not_to include(sentinel)
        end
      end

      it "requires a String" do
        [nil, [sentinel]].each do |bad|
          message = message_of { described_class.parse(bad) }

          expect(message).to include("must be a String")
          expect(message).not_to include(sentinel)
        end
      end
    end
  end
end
