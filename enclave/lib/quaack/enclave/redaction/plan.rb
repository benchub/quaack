# frozen_string_literal: true

require_relative "expression"
require_relative "plan_fields"

module Quaack
  module Enclave
    module Redaction
      # Builds a redacted copy of an EXPLAIN (FORMAT JSON) plan. See
      # Redaction.plan.
      #
      # The copy is built from a whitelist, not scrubbed: each field in
      # PlanFields is copied (a name, number, or flag, when its value is that kind) or
      # redacted (an expression, through Expression), and every other field
      # is left out, so a field a later Postgres adds is dropped until
      # someone adds it here. The fields are the ones Postgres 18 prints for
      # a SELECT, with ANALYZE, BUFFERS, SETTINGS, VERBOSE, WAL, and
      # MEMORY. Among those left out:
      # - Workers (per-worker counts), Full-sort Groups and Pre-sorted
      #   Groups (an Incremental Sort's details), Grouping Sets (which
      #   SupportedSql refuses), and Params Evaluated.
      # - Anything from an extension, such as postgres_fdw's Remote SQL,
      #   which is a whole query with its literals.
      # - JIT, Triggers, Query Identifier, and Serialization.
      class Plan
        # One place a placeholder was found: the plan node's own fields and
        # the qual that held it.
        Consumer = Data.define(:fields, :qual)

        attr_reader :explain, :masked, :dropped

        # consumers maps each placeholder's number to every Consumer of it.
        attr_reader :consumers

        def initialize(explain, matcher)
          check(explain)
          @matcher = matcher
          @masked = 0
          @dropped = 0
          @consumers = Hash.new { |h, k| h[k] = [] }
          @explain = explain.map { |entry| statement(entry) }.freeze
        end

        private

        def check(explain)
          statements = explain.is_a?(Array) && !explain.empty? && explain.all?(Hash)
          return if statements && explain.all? { |e| e["Plan"].is_a?(Hash) }

          raise ArgumentError, "explain must be the parsed JSON of EXPLAIN (FORMAT JSON)"
        end

        def statement(entry)
          out = { "Plan" => node(entry["Plan"]) }
          settings = entry["Settings"]
          if settings.is_a?(Hash)
            out["Settings"] = settings.select { |name, value| PlanFields::SETTINGS.include?(name) && value.is_a?(String) }
          end
          out["Planning"] = numbers(entry["Planning"], PlanFields::PLANNING) if entry["Planning"].is_a?(Hash)
          out.merge!(numbers(entry, PlanFields::TOP_NUMBERS))
        end

        def numbers(fields, keys) = fields.slice(*keys).select { |_key, value| value.is_a?(Numeric) }

        # The walk keeps its own stack of nodes still to copy, rather than
        # recursing, so a plan of any depth can't overflow Ruby's stack.
        def node(root)
          out = {}
          pending = [[root, out]]
          until pending.empty?
            fields, copy = pending.pop
            copy_fields(fields, copy, pending)
          end
          out
        end

        def copy_fields(fields, copy, pending)
          raise ArgumentError, "explain has a plan node that isn't an object" unless fields.is_a?(Hash)

          fields.each do |key, value|
            kept = key == "Plans" ? plans(value, pending) : field(fields, key, value)
            kept == :drop ? (@dropped += 1) : (copy[key] = kept unless kept.nil?)
          end
        end

        # The field's redacted value, nil if it isn't on the whitelist, or
        # :drop if it is, but its value can't be kept.
        def field(fields, key, value)
          kind = PlanFields::KINDS[key]
          case kind
          when :expression then expression(fields, key, value)
          when :expressions then expression_list(value)
          when nil then nil
          else PlanFields::SCALARS.fetch(kind).call(value) ? value : :drop
          end
        end

        # Empty copies of the children, which the walk fills in later.
        def plans(value, pending)
          raise ArgumentError, "explain has a Plans entry that isn't a list" unless value.is_a?(Array)

          value.map { |child| {}.tap { |copy| pending << [child, copy] } }
        end

        def expression(fields, key, value)
          redacted = Expression.redact(value, @matcher)
          return :drop unless redacted

          @masked += redacted.masked
          if PlanFields::CONSUMERS.include?(key)
            redacted.matches.flatten.uniq.each { |n| @consumers[n] << Consumer.new(fields:, qual: key) }
          end
          redacted.text
        end

        # A list is dropped whole if any of it can't be read, since each
        # entry's place in it means something.
        def expression_list(value)
          return :drop unless value.is_a?(Array)

          redacted = value.map { |text| Expression.redact(text, @matcher) }
          return :drop unless redacted.all?

          @masked += redacted.sum(&:masked)
          redacted.map(&:text)
        end
      end

      private_constant :Plan
    end
  end
end
