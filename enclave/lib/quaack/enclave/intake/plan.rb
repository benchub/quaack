# frozen_string_literal: true

require_relative "error"
require_relative "../cli/input"

module Quaack
  module Enclave
    module Intake
      # Checks the operator's EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT
      # JSON) output, in this order, and returns it parsed:
      #
      # 1. plan_not_json: it isn't one JSON document, read as strictly as
      #    the CLI reads stdin (see CLI::Input): UTF-8, no repeated key, no
      #    comment, no unknown escape, and no number too big for a Float.
      #    Or plan_too_large, before it's parsed, when it has more than
      #    CLI::Input::MAX_ELEMENTS elements.
      # 2. plan_bad_shape: it isn't what EXPLAIN writes for one statement,
      #    an Array of one object whose "Plan" is an object, with a
      #    "Settings" that's an object of Strings if it's there at all.
      #    Postgres 18 writes an empty Settings when every setting is the
      #    default, but the key isn't required.
      # 3. plan_not_analyzed: the root plan node has neither "Actual Rows"
      #    nor "Actual Total Time", which only ANALYZE writes. TIMING OFF
      #    leaves out the times but keeps the rows.
      # 4. plan_no_buffers: the root plan node has none of the block
      #    counters BUFFERS writes. Without ANALYZE, BUFFERS writes them only
      #    under "Planning", but that's already refused above.
      # 5. plan_bad_shape again: a node's "Plans" isn't a list of objects.
      # 6. plan_statement_mismatch: a node anywhere in the plan is a
      #    ModifyTable, which only a data-changing statement's plan has, such
      #    as an UPDATE's. The query is always a SELECT (see Query), so the
      #    plan came from another statement. Comparing the plan's tables
      #    with the query's needs the catalog, so qualify does it (see
      #    PlanTables).
      # 7. plan_too_deep: a node is more than MAX_DEPTH levels down, the
      #    root being level one. Egress writes JSON with its nesting limit
      #    of 100, and a payload holds each level of the plan two deeper,
      #    so a deeper plan, redacted, couldn't go out (unsupported in v1).
      #
      # One leading byte order mark, which some editors write, is dropped
      # first, since JSON refuses it.
      module Plan
        BOM = "﻿"
        BUFFER_COUNTERS = %w[Shared Local Temp].product(%w[Hit Read Dirtied Written])
                                               .map { |kind, what| "#{kind} #{what} Blocks" }.freeze
        ANALYZE_KEYS = ["Actual Rows", "Actual Total Time"].freeze
        MAX_DEPTH = 48

        module_function

        def check(bytes)
          plan = parse(bytes.dup.force_encoding(Encoding::UTF_8).delete_prefix(BOM))
          raise Error, "plan_bad_shape" unless shaped?(plan)

          root = plan[0]["Plan"]
          raise Error, "plan_not_analyzed" unless ANALYZE_KEYS.any? { root.key?(it) }
          raise Error, "plan_no_buffers" unless BUFFER_COUNTERS.any? { root.key?(it) }

          statement!(root)
          plan
        end

        def statement!(root)
          raise Error, "plan_statement_mismatch" if nodes(root).any? { it["Node Type"] == "ModifyTable" }
          raise Error, "plan_too_deep" if depth(root) > MAX_DEPTH
        end

        # The node and every node under it, depth first.
        def nodes(node)
          plans = node.fetch("Plans", [])
          raise Error, "plan_bad_shape" unless plans.instance_of?(Array) && plans.all?(Hash)

          [node, *plans.flat_map { nodes(it) }]
        end

        # The levels of nodes, the root's counted. The shape is checked.
        def depth(node) = 1 + (node.fetch("Plans", []).map { depth(it) }.max || 0)

        def parse(text)
          CLI::Input.parse_document(text)
        rescue CLI::Refused => e
          raise Error, e.rule == "input_too_large" ? "plan_too_large" : "plan_not_json", cause: nil
        end

        def shaped?(plan)
          return false unless plan.instance_of?(Array) && plan.size == 1 && plan[0].instance_of?(Hash)

          settings = plan[0].fetch("Settings", {})
          plan[0]["Plan"].instance_of?(Hash) && settings.instance_of?(Hash) &&
            settings.each_value.all? { it.instance_of?(String) } # rubocop:disable Style/PredicateWithKind
        end
      end
    end
  end
end
