# frozen_string_literal: true

module LeakCheck
  # The scanner missed a sentinel planted where it must look.
  class BrokenScanner < StandardError; end

  # Plants each needle of a Sentinels in each place the scanner must look,
  # one at a time, and checks the scanner finds it there. expect_no_leaks
  # runs it before every scan, so a scanner that stops looking somewhere
  # fails loudly instead of passing everything.
  module PositiveControl
    # Stands in for an object that keeps a value but doesn't show it in
    # inspect or to_s, so only a walk of its instance variables finds it.
    class Hidden
      def initialize(value) = @value = value
      def inspect = "#<hidden>"
      def to_s = "hidden"
    end

    # Errors whose detailed_message or full_message shows the needle while
    # nothing else does. They keep it reversed, so a walk of their instance
    # variables can't find it either.
    class DetailedError < StandardError
      def initialize(needle)
        super("clean")
        @reversed = needle.reverse
      end

      def detailed_message(**) = "clean #{@reversed.reverse}"
    end

    class FullError < DetailedError
      def detailed_message(**) = "clean"
      def full_message(**) = "clean #{@reversed.reverse}"
    end

    # Each place, and how to plant needle there as scanner arguments.
    PLANTS = {
      "stdout" => ->(needle) { { stdout: "line #{needle} line" } },
      "stderr" => ->(needle) { { stderr: "line #{needle} line" } },
      "status" => ->(needle) { { status: Struct.new(:detail).new(needle) } },
      "a nested object" => ->(needle) { { objects: { verdict: [{ value: [needle] }] } } },
      "an error's message" => ->(needle) { { objects: { error: RuntimeError.new(needle) } } },
      "an error's backtrace" => lambda { |needle|
        { objects: { error: RuntimeError.new("clean").tap { it.set_backtrace(["#{needle}.rb:1"]) } } }
      },
      "an error's detailed_message" => ->(needle) { { objects: { error: DetailedError.new(needle) } } },
      "an error's full_message" => ->(needle) { { objects: { error: FullError.new(needle) } } },
      "an error's cause" => ->(needle) { { objects: { error: PositiveControl.caused_by(needle) } } },
      "an error's instance variable" => lambda { |needle|
        { objects: { error: RuntimeError.new("clean").tap { it.instance_variable_set(:@kept, Hidden.new(needle)) } } }
      },
      "an object's instance variable" => ->(needle) { { objects: { result: Hidden.new(needle) } } }
    }.freeze

    module_function

    # An error with a clean message whose cause's message holds needle.
    def caused_by(needle)
      begin
        raise needle
      rescue RuntimeError
        raise "clean"
      end
    rescue RuntimeError => e
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
