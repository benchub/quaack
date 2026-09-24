# frozen_string_literal: true

module LeakCheck
  # The scanner missed a sentinel planted where it must look.
  class BrokenScanner < StandardError; end

  # Plants each needle of a Sentinels in each place the scanner must look,
  # one at a time, and checks the scanner finds it there. expect_no_leaks
  # runs it before every scan, so a scanner that stops looking somewhere
  # fails loudly instead of passing everything.
  module PositiveControl
    # How deep the deep plant nests its needle.
    DEPTH = 10

    # Stands in for an object that keeps a value but doesn't show it in
    # inspect or to_s, so only a walk of its instance variables finds it.
    class Hidden
      def initialize(value) = @value = value
      def inspect = "#<hidden>"
      def to_s = "hidden"
    end

    # Each place must be the only one that shows its needle, or a scanner
    # that stopped looking there would still find it somewhere else. On
    # Ruby 3.4 an ordinary error's full_message holds its message,
    # backtrace, and cause, and inspect holds its message. So these stand-ins
    # keep the needle reversed, where no walk of their instance variables
    # finds it, and show it only through the one method named by via.
    # Every other describing method gives "clean".
    class Shows
      def initialize(needle, via)
        @reversed = needle.reverse
        @via = via
      end

      def to_s = shown(:to_s)
      def inspect = shown(:inspect)

      private

      def shown(name) = name == @via ? "clean #{@reversed.reverse}" : "clean"
    end

    class CleanError < StandardError
      def initialize(needle = "", via: nil)
        super("clean")
        @reversed = needle.reverse
        @via = via
      end

      %i[message to_s inspect detailed_message full_message].each do |name|
        define_method(name) { |**| name == @via ? "clean #{@reversed.reverse}" : "clean" }
      end
    end

    # Each place, and how to plant needle there as scanner arguments. The
    # capitals and UTF-16 plants check the scanner ignores case and
    # encoding, and the deep one that it looks DEPTH objects down.
    PLANTS = {
      "stdout" => ->(needle) { { stdout: "line #{needle} line" } },
      "stdout, in capitals" => ->(needle) { { stdout: "line #{needle.upcase} line" } },
      "stdout, in UTF-16" => ->(needle) { { stdout: "line #{needle} line".encode("UTF-16LE") } },
      "stderr" => ->(needle) { { stderr: "line #{needle} line" } },
      "status" => ->(needle) { { status: Struct.new(:detail).new(needle) } },
      "a deep object" => ->(needle) { { objects: { result: PositiveControl.nested(needle) } } },
      "an object's to_s" => ->(needle) { { objects: { result: Shows.new(needle, :to_s) } } },
      "an object's inspect" => ->(needle) { { objects: { result: Shows.new(needle, :inspect) } } },
      "an object's instance variable" => ->(needle) { { objects: { result: Hidden.new(needle) } } },
      "an error's message" => ->(needle) { { objects: { error: CleanError.new(needle, via: :message) } } },
      "an error's backtrace" => lambda { |needle|
        { objects: { error: CleanError.new.tap { it.set_backtrace(["#{needle}.rb:1"]) } } }
      },
      "an error's detailed_message" => lambda { |needle|
        { objects: { error: CleanError.new(needle, via: :detailed_message) } }
      },
      "an error's full_message" => ->(needle) { { objects: { error: CleanError.new(needle, via: :full_message) } } },
      "an error's cause" => ->(needle) { { objects: { error: PositiveControl.caused_by(needle) } } },
      "an error's instance variable" => lambda { |needle|
        { objects: { error: CleanError.new.tap { it.instance_variable_set(:@kept, Hidden.new(needle)) } } }
      }
    }.freeze

    module_function

    # needle inside DEPTH Hidden objects, each inside the last.
    def nested(needle) = DEPTH.times.reduce(needle) { |inner, _| Hidden.new(inner) }

    # A CleanError whose cause, an ordinary error, holds needle.
    def caused_by(needle)
      begin
        raise needle
      rescue RuntimeError
        raise CleanError
      end
    rescue CleanError => e
      e
    end

    # The places where scanner missed each sentinel of sentinels, as
    # "sentinel name in place" Strings.
    def misses(sentinels, scanner)
      PLANTS.flat_map do |place, plant|
        sentinels.needles.filter_map do |name, needle|
          found = scanner.call(sentinels, **plant.call(needle)).any? { it.sentinel == name }
          "#{name} in #{place}" unless found
        end
      end
    end
  end

  module_function

  # Raises BrokenScanner, naming each miss, unless scanner (the real one by
  # default) finds every sentinel of sentinels planted in every place in
  # PositiveControl::PLANTS. Returns nil otherwise.
  def check_scanner!(sentinels, scanner: method(:findings))
    misses = PositiveControl.misses(sentinels, scanner)
    raise BrokenScanner, "the leak scanner missed a planted sentinel: #{misses.join(", ")}" unless misses.empty?
  end
end
