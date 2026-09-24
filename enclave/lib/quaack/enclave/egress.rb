# frozen_string_literal: true

require "json"
require "quaack/protocol/whitelist"
require "quaack/protocol/burndown"
require_relative "plain_data"

module Quaack
  module Enclave
    # The egress function (README, "Trust boundary"): the one way anything
    # leaves the enclave. It sends a message only as its type plus the
    # fields Quaack::Protocol::WHITELIST lists for that type, and drops
    # everything else outright rather than scrubbing it.
    #
    #   Egress.serialize(type: :error, step: "3f", rule: "unique_violation",
    #                    sqlstate: "23505", message: "Key (email)=(...)")
    #   # => '{"type":"error","step":"3f","rule":"unique_violation","sqlstate":"23505"}'
    #
    # A message is a Hash. Its keys, and the value of its type key, may be
    # Symbols or Strings. The result is one line of JSON, with no newline:
    # type first, then the allowed fields the message has, in whitelist
    # order. A field the message doesn't have is left out, not sent as null.
    #
    # It returns nil, sending nothing, for a message that isn't a Hash, has
    # no type or one not on the whitelist, or names its type or an allowed
    # field twice (once as a Symbol and once as a String), since then it's
    # unclear which one to send.
    #
    # Values of allowed fields go out unchanged: there are no field types.
    # So the whitelist must list only fields whose values are always
    # shape-class data. The one exception is the burndown type, whose
    # stages and totals must pass Protocol::Burndown.valid?, or it raises
    # Egress::Error. A value must be plain JSON data, though: nil, true,
    # false, an Integer, a Float, a String, a Symbol (sent as its name), or
    # an Array or Hash of those, with String or Symbol keys. Anything else,
    # such as an exception, a Struct, a Time, or a subclass of String, could
    # carry a real value out through its to_s or to_json.
    #
    # For a value that isn't plain JSON data, or that JSON can't write, such
    # as invalid UTF-8 or a NaN, it raises Egress::Error. The error names
    # only the type, which is on the whitelist, and has no cause, so
    # nothing from the message rides along with it.
    module Egress
      class Error < StandardError; end

      # The whitelist with String names, so Symbol and String keys match the
      # same way without turning arbitrary Strings into Symbols. Each type
      # maps to its own name and its fields, so what goes out as the type is
      # always the whitelist's String, never the caller's object.
      TYPES = Protocol::WHITELIST.to_h { |type, fields| [type.name, [type.name, fields.map(&:name)].freeze] }.freeze

      # Marks a name given both as a Symbol and as a String. No message has
      # it as a key, so looking it up finds nothing.
      TWICE = Object.new.freeze

      module_function

      def serialize(message)
        return unless message.is_a?(Hash)

        keys = keys_by_name(message)
        type, fields = TYPES[type_name(message, keys)]
        return if fields.nil? || fields.any? { |f| keys[f].equal?(TWICE) }

        write(type, fields.filter_map { |f| [f, message[keys[f]]] if keys.key?(f) })
      end

      # The message's type as a String, or whatever else its type key holds.
      def type_name(message, keys)
        return unless keys.key?("type")

        type = message[keys["type"]]
        type.is_a?(Symbol) ? type.name : type
      end

      # Each Symbol or String key by its String name, or TWICE for a name
      # given both ways. Other keys can never match a field, so they're
      # skipped.
      def keys_by_name(message)
        message.each_key.with_object({}) do |key, keys|
          next unless key.is_a?(Symbol) || key.is_a?(String)

          name = key.to_s
          keys[name] = keys.key?(name) ? TWICE : key
        end
      end

      # Each value must be plain JSON data (see PlainData). JSON writes a
      # Symbol, value or key, as its name. JSON's default nesting limit of 100
      # stops it long before it could run out of stack (99 levels of Hashes
      # write fine in a thread asking for a 16 KB stack, on macOS and aarch64
      # Linux), so there's no SystemStackError to rescue here.
      def write(type, pairs)
        fields = pairs.to_h
        fields.each_value { PlainData.check(it) }
        check_burndown(fields) if type == "burndown"
        JSON.generate({ "type" => type, **fields })
      rescue PlainData::NotPlain, JSON::JSONError
        raise Error, "a value in this #{type} message can't be written as JSON", cause: nil
      end

      # A burndown's fields are nested Hashes, which go out as they are, so
      # they must be exactly a burndown (see Protocol::Burndown.valid?): only
      # counts, under names that are stages or lowercase words. Both fields
      # are needed.
      def check_burndown(fields)
        return if Protocol::Burndown.valid?(stages: fields["stages"], totals: fields["totals"])

        raise Error, "a value in this burndown message isn't a burndown"
      end
    end
  end
end
