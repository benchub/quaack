# frozen_string_literal: true

require "stringio"
require "tempfile"

module LeakCheck
  # One sentinel found in one place. channel says where, such as "stderr",
  # "status", or "error.cause.message" for the cause of the object passed as
  # objects: { error: ... }. context is the text around it.
  Finding = Data.define(:sentinel, :channel, :context) do
    def to_s = "#{sentinel} in #{channel}: ...#{context}..."
  end

  # Collects every piece of text a Ruby object could show, each with the
  # path it came from: a String itself; any other object's to_s and inspect;
  # an error's message, detailed_message, full_message, backtrace, and cause;
  # the elements of an Array, the keys and values of a Hash, the members of
  # a Struct or Data (which a custom inspect can hide), a StringIO's text,
  # and every object's instance variables. It visits each object once, so a cycle
  # ends, and goes at most MAX_DEPTH deep. A describing method that raises
  # gives the raised error's message instead, since that's what a caller
  # would see.
  class Texts
    MAX_DEPTH = 24
    ERROR_METHODS = %i[message detailed_message full_message backtrace].freeze
    # Arguments for the describing methods that take them, so the text has
    # no terminal color codes in it.
    ARGUMENTS = { detailed_message: { highlight: false }, full_message: { highlight: false } }.freeze
    IMMEDIATE = [Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    def self.of(object, path) = new.tap { it.visit(object, path, 0) }.texts

    attr_reader :texts

    def initialize
      @texts = []
      @seen = Set.new.compare_by_identity
    end

    def visit(object, path, depth)
      return if depth > MAX_DEPTH
      return @texts << [path, object] if object.instance_of?(String)
      return @texts << [path, object.inspect] if IMMEDIATE.any? { object.is_a?(it) }
      return unless @seen.add?(object)

      refuse_io(object, path)

      describe(object, path)
      children(object, path).each { |child, child_path| visit(child, child_path, depth + 1) }
    end

    private

    # An IO's text can't be read back, so it can't be scanned. A Tempfile is
    # a Delegator, not an IO, so it's checked by name.
    def refuse_io(object, path)
      return unless object.is_a?(IO) || object.is_a?(Tempfile)

      raise ArgumentError, "#{path} is an IO, whose text can't be scanned; pass the text it wrote instead"
    end

    # An object's to_s is recorded at its own path, and every other
    # describing method's text at the path plus the method's name.
    def describe(object, path)
      ask(object, :to_s, path)
      methods = [:inspect]
      methods += ERROR_METHODS if object.is_a?(Exception)
      methods.each { |name| ask(object, name, "#{path}.#{name}") }
    end

    def ask(object, name, path)
      value = object.public_send(name, **ARGUMENTS.fetch(name, {}))
      @texts << [path, Array(value).join("\n")]
    rescue StandardError, ScriptError, SystemStackError, NoMemoryError => e
      @texts << ["#{path} (raised)", message_of(e)]
    end

    # Not through ask, since the raised error's own message could raise too.
    def message_of(error)
      error.message.to_s
    rescue StandardError, ScriptError, SystemStackError, NoMemoryError
      ""
    end

    # Each object inside object, with its path.
    def children(object, path)
      kids = object.instance_variables.map { [object.instance_variable_get(it), "#{path}.#{it}"] }
      kids << [object.cause, "#{path}.cause"] if object.is_a?(Exception) && object.cause
      kids << [object.string, "#{path}.string"] if object.is_a?(StringIO)
      kids + members(object, path)
    end

    def members(object, path)
      case object
      when Array then object.each_with_index.map { |item, i| [item, "#{path}[#{i}]"] }
      when Hash then [[object.keys, "#{path}.keys"]] + object.map { |k, v| [v, "#{path}[#{k.inspect}]"] }
      when Struct, Data then object.to_h.map { |k, v| [v, "#{path}.#{k}"] }
      else []
      end
    end
  end

  module_function

  # Every sentinel of sentinels (a Sentinels) in what a step put out: its
  # stdout and stderr, as captured, its exit status, and objects, a Hash of
  # names to anything else meant to leave or be shown, such as an error, a
  # verdict, or a result for egress. It matches without regard to case or
  # encoding. It returns Findings, at most one for each sentinel in each
  # place, and [] when it finds none.
  #
  # Use it directly only for exposure checks, which assert that a sentinel
  # is there, such as in the plan a step reads. For "nothing leaked," use
  # expect_no_leaks, which runs the positive control first, so a broken
  # scanner can't make an empty result look clean.
  #
  # stdout and stderr must be Strings or nil. A StringIO's to_s is only
  # #<StringIO:...>, so passing the capture instead of its text would
  # scan nothing. Among objects, a StringIO's text is scanned, and any
  # other IO or Tempfile among them, at any depth, is refused, since what it holds can't be read.
  def findings(sentinels, stdout: nil, stderr: nil, status: nil, objects: {})
    texts = { "stdout" => text_channel("stdout", stdout), "stderr" => text_channel("stderr", stderr) }.compact.to_a
    texts += Texts.of(status, "status") unless status.nil?
    objects.each { |name, object| texts += Texts.of(object, name.to_s) }
    texts.flat_map { |channel, text| findings_in(sentinels, channel, text) }
  end

  def text_channel(name, text)
    return text if text.nil? || text.is_a?(String)

    raise ArgumentError,
          "#{name} must be a String or nil, not a #{text.class}; pass the text it captured, such as out.string"
  end

  def findings_in(sentinels, channel, text)
    haystack = comparable(text)
    sentinels.needles.filter_map do |name, needle|
      at = haystack.index(comparable(needle))
      Finding.new(sentinel: name, channel:, context: haystack[[at - 20, 0].max, needle.size + 40]) if at
    end
  end

  # text as lowercase bytes. Text in an encoding that isn't ASCII
  # compatible, such as UTF-16, is turned into UTF-8 first.
  def comparable(text)
    text = text.to_s
    text = text.encode("UTF-8", invalid: :replace, undef: :replace) unless text.encoding.ascii_compatible?
    text.b.downcase
  end
end
