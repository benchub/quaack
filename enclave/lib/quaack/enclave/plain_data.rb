# frozen_string_literal: true

module Quaack
  module Enclave
    # Checks that a value is plain JSON data, for the egress function and
    # the governed store. Plain data is nil, true, false, an Integer, a
    # Float, a String, a Symbol, or an Array or Hash of those, with String
    # or Symbol keys, nested at most MAX_DEPTH deep.
    #
    # Classes must match exactly. A subclass of String, Array, or Hash can
    # bring its own to_s or to_json, and the json that ships with Ruby
    # writes any other object, including a Hash key, with its to_s. So
    # anything else could carry a real value somewhere it shouldn't go. A
    # Hash that names a key twice, once as a Symbol and once as a String,
    # isn't plain either, since JSON would write both under the same name.
    #
    # It checks classes, not singleton methods. So a plain Array or Hash
    # given its own to_json passes, and since callers write the original
    # object, JSON would call that to_json. Doing that takes deliberate
    # effort, not an honest mistake, so it's outside the threat model.
    #
    # The walk uses its own stack rather than recursion, so deep data, or
    # data that contains itself, raises NotPlain instead of overflowing the
    # stack.
    module PlainData
      # Its message never carries anything from the value, and it's raised
      # outside any rescue, so it has no cause.
      class NotPlain < StandardError; end

      # Deeper than any plan or parse tree QUAACK stores (the deepest real
      # pg_query tree seen is about 1,500 levels, and a plan adds about two
      # levels a node), and shallow enough for the json that ships with Ruby
      # (2.9.1) to write and read. JSON recurses on the machine stack, and
      # nested Hashes need the most. Measured limits for writing nested
      # Hashes: about 9,700 levels on the main thread (8 MB stack) on
      # aarch64 Linux, 12,400 on macOS, and about 1,200 and 1,500 in a thread
      # with Ruby's default 1 MB stack. Arrays go deeper, and reading goes
      # deeper still.
      #
      # So MAX_DEPTH is safe on the main thread, where the enclave script
      # runs, and in any thread with a stack of 4 MB or more, which the specs
      # test. In a smaller thread, JSON can run out of stack before
      # MAX_DEPTH, and callers turn the SystemStackError into their own
      # error. That's best effort: Ruby can crash outright if one thread runs
      # out of stack a second time.
      MAX_DEPTH = 3_000

      SCALARS = [NilClass, TrueClass, FalseClass, Integer, Float, String, Symbol].freeze

      module_function

      # Returns value if it's plain data, and raises NotPlain if it isn't.
      def check(value)
        stack = [[value, 0]]
        until stack.empty?
          item, depth = stack.pop
          children(item, depth).each { |child| stack.push([child, depth + 1]) }
        end
        value
      end

      # The values inside item, which sits inside depth containers.
      def children(item, depth)
        # A BasicObject has no class method, so ask Object first.
        raise NotPlain, "the value isn't plain JSON data" unless Object === item # rubocop:disable Style/CaseEquality

        klass = item.class
        return [] if SCALARS.include?(klass)
        raise NotPlain, "the value isn't plain JSON data" unless [Array, Hash].include?(klass)
        raise NotPlain, "the value is nested more than #{MAX_DEPTH} deep" if depth >= MAX_DEPTH

        klass == Hash ? hash_values(item) : item
      end

      def hash_values(hash)
        names = {}
        hash.each_key do |key|
          raise NotPlain, "a Hash key isn't a String or Symbol" unless [String, Symbol].include?(key.class)
          raise NotPlain, "a Hash names a key twice" if names.key?(key.to_s)

          names[key.to_s] = true
        end
        hash.values
      end
    end
  end
end
