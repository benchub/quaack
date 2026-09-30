# frozen_string_literal: true

require "digest"
require "pg_query"
require_relative "clock_functions"
require_relative "node_rewrite"
require_relative "plan_node"
require_relative "plan_expression"

module Quaack
  module Enclave
    # The canonical plan form (DESIGN.md step 1), which steps 5, 5a-4, and 8 use
    # to compare plans:
    #
    #   CanonicalPlan.new(explain).matches?(CanonicalPlan.new(other))
    #   CanonicalPlan.new(explain, hypothetical_indexes: { 13542 => definition })
    #
    # explain is the parsed JSON of EXPLAIN (FORMAT JSON): the top-level
    # array Postgres prints. It can come from EXPLAIN ANALYZE, with or
    # without BUFFERS, SETTINGS, and VERBOSE, or from a plain EXPLAIN.
    #
    # Each node keeps its type (with "Parallel " in front for a
    # parallel-aware node, as the text format prints it), its NAMES fields,
    # a fingerprint of each of its QUALS and SORT_KEYS, and its children in
    # order. Everything else is dropped: costs, row counts, timings, buffers,
    # workers, memory and disk use, Output, Schema, Settings, and aliases.
    # So are fields no step compares, such as a Memoize's Cache Key and an
    # Aggregate's Grouping Sets.
    #
    # A qual or key is parsed with pg_query, each alias in it is replaced
    # with what it stands for, and pg_query's fingerprint is kept. The
    # fingerprint ignores literals and parameters, so quals that differ only
    # in those match. It also ignores the order of AND and OR arms and of a
    # function's arguments, and drops repeated arms. An alias stands for its
    # scan's relation, or, for a scan with none (such as a CTE Scan or a
    # Subquery Scan), for the nth such scan in the plan, counted depth first.
    # A bare column belongs to the scan whose qual it's in (a bitmap index
    # scan's belongs to its heap scan), or else to the plan's only scan, if
    # it has just one. That way the qualified columns VERBOSE prints match
    # the bare ones plain EXPLAIN prints. Two aliases of one relation, as in
    # a self-join, can't be told apart.
    #
    # A clock function 3h anchors (ClockFunctions), such as now() or
    # CURRENT_DATE, is compared as the anchored expression that replaces it,
    # and the type in a cast of quaack.clock_anchor() is compared without a
    # pg_catalog in front, since Postgres prints it without one. So the
    # step 1 plan's "(created_at > (CURRENT_DATE - 7))" matches the
    # racetrack's "(created_at > ((quaack.clock_anchor())::date - 7))", as
    # step 5 needs, but not a cast to another type.
    #
    # Postgres prints references to InitPlans and SubPlans in forms that
    # aren't SQL, such as "(InitPlan 1).col1" and
    # "(ANY (id = (hashed SubPlan 1).col1))". Before parsing, those become
    # calls to functions named for the subplan and the wrapper, so they
    # compare by subplan name, hashing, wrapper, and column. A qual or key
    # that still doesn't parse, parses as more than one expression, or isn't
    # text can't be compared. Rather than guess, it makes the whole plan not
    # comparable?, and a plan that isn't comparable matches nothing, not even
    # itself.
    #
    # Trust boundary: quals hold real literals, but the canonical form keeps
    # only fingerprints of them, so it holds no literal, and nothing here
    # raises on a qual, so no error can quote one. The form still comes from
    # production quals, so it stays in the enclave with the plan.
    class CanonicalPlan
      # Kept as they are, except for a HypoPG index's name, "<oid>" followed
      # by a name made from its method, table, and columns. Each session
      # gives the same index a new oid, and different indexes, such as a
      # partial one and a plain one, can get the same name. So a caller
      # whose plan has hypothetical indexes passes hypothetical_indexes, a
      # Hash from each one's oid, as HypoPG reports it, to an identity
      # string, such as its definition from hypopg_get_indexdef. Each index
      # whose name is "<oid>" for an oid in the Hash, read in decimal, then
      # stands for its identity. The canonical form keeps only a digest of
      # the identity, since a partial index's predicate holds a literal.
      #
      # Every other index name is kept as it is, even one that starts with
      # "<digits>", since a real index can have a name like that, such as
      # "<1>orders_pkey" as a quoted identifier. So without a map, or for an
      # oid the map leaves out, the same hypothetical index in two sessions
      # doesn't match itself. A real index whose name starts with the
      # "<oid>" of a hypothetical index in the map is taken for that
      # hypothetical index.
      #
      # The digest covers a partial index's predicate, literal and all, and
      # a short literal could be guessed from it. It stays in the enclave
      # today, but any step that sends a canonical form out must not send it.
      NAMES = ["Parent Relationship", "Subplan Name", "Relation Name", "CTE Name", "Function Name", "Index Name",
               "Join Type", "Strategy", "Partial Mode", "Scan Direction"].freeze

      QUALS = ["Filter", "Index Cond", "Recheck Cond", "Join Filter", "Hash Cond", "Merge Cond", "TID Cond",
               "One-Time Filter", "Run Condition", "Order By"].freeze

      # Lists of keys. Their order matters.
      SORT_KEYS = ["Sort Key", "Presorted Key", "Group Key"].freeze

      # Raises ArgumentError, without quoting either argument, if explain
      # isn't the parsed JSON of EXPLAIN (FORMAT JSON) or hypothetical_indexes
      # isn't nil or a Hash from Integer oids to Strings.
      def initialize(explain, hypothetical_indexes: nil)
        builder = Builder.new(roots(explain), checked(hypothetical_indexes))
        @tree = builder.tree
        @comparable = builder.comparable
        freeze
      end

      # False if a qual or key couldn't be compared.
      def comparable? = @comparable

      # True if both plans are comparable? and their canonical forms are the
      # same.
      def matches?(other) = other.is_a?(CanonicalPlan) && comparable? && other.comparable? && tree == other.tree

      protected

      attr_reader :tree

      private

      def roots(explain)
        valid = explain.is_a?(Array) && !explain.empty? && explain.all? { |e| e.is_a?(Hash) && e["Plan"].is_a?(Hash) }
        raise ArgumentError, "explain must be the parsed JSON of EXPLAIN (FORMAT JSON)" unless valid

        explain.map { |entry| PlanNode.new(entry["Plan"]) }
      end

      def checked(hypothetical_indexes)
        return hypothetical_indexes if hypothetical_indexes.nil? ||
                                       (hypothetical_indexes.is_a?(Hash) &&
                                        hypothetical_indexes.all? { |oid, id| oid.is_a?(Integer) && id.is_a?(String) })

        raise ArgumentError, "hypothetical_indexes must map index oids to identity strings"
      end

      # Builds the canonical form of a plan's roots.
      class Builder
        # A bare column in these nodes' quals belongs to the heap scan above.
        BITMAPS = ["Bitmap Index Scan", "BitmapAnd", "BitmapOr"].freeze

        HYPOTHETICAL_INDEX = /\A<(\d+)>/

        # "InitPlan 1", "SubPlan 1", "hashed SubPlan 1", or "rescan SubPlan 1".
        SUBPLAN = /(?:hashed |rescan )?(?:InitPlan|SubPlan) \d+/

        # "(ANY " and "(ALL ", which no SQL has right after a parenthesis, and
        # "EXISTS(", "ARRAY(", or "CTE(" right before a subplan's name.
        SUBPLAN_WRAPPER = /\((ANY|ALL) |\b(EXISTS|ARRAY|CTE)\((?=(?:hashed )?SubPlan \d+\))/

        attr_reader :tree, :comparable

        def initialize(roots, hypothetical_indexes)
          @comparable = true
          @hypothetical_indexes = hypothetical_indexes
          @identities = identities(roots.flat_map(&:subtree))
          sole = @identities.values.uniq
          @sole = sole.first if sole.size == 1
          @tree = roots.map { |root| node(root, @sole) }
        end

        private

        # What each alias stands for.
        def identities(nodes)
          unnamed = 0
          nodes.select(&:alias_name).to_h { |n| [n.alias_name, n.relation || "#{n.type} #{unnamed += 1}"] }
        end

        def node(plan_node, inherited)
          default = default_identity(plan_node, inherited)
          type = plan_node.parallel? ? "Parallel #{plan_node.type}" : plan_node.type
          { "Node Type" => type, **names(plan_node), **quals(plan_node, default), **keys(plan_node, default),
            "Plans" => plan_node.children.map { |child| node(child, default) } }
        end

        def names(plan_node)
          names = NAMES.filter_map { |key| [key, plan_node[key]] if plan_node[key] }.to_h
          identity = hypothetical_identity(names["Index Name"])
          names["Index Name"] = "<hypothetical #{Digest::SHA256.hexdigest(identity)}>" if identity
          names
        end

        # The identity the map gives an index name's "<oid>", or nil for a
        # real index.
        def hypothetical_identity(index)
          oid = index[HYPOTHETICAL_INDEX, 1] if @hypothetical_indexes && index.is_a?(String)
          @hypothetical_indexes[Integer(oid, 10)] if oid
        end

        def quals(plan_node, default)
          QUALS.filter_map do |key|
            text = plan_node[key]
            [key, text?(text) ? fingerprint("SELECT WHERE #{text}", default) : unparsed] if text
          end.to_h
        end

        def keys(plan_node, default)
          SORT_KEYS.filter_map do |key|
            texts = plan_node[key]
            next unless texts
            next [key, unparsed] unless texts.is_a?(Array) && texts.all? { |text| text?(text) }

            [key, texts.map { |text| fingerprint("SELECT ORDER BY #{text}", default) }]
          end.to_h
        end

        # Text pg_query and the subplan rewrite can take without raising:
        # valid UTF-8 with no NUL byte.
        def text?(value) = value.is_a?(String) && value.valid_encoding? && !value.include?("\0")

        # What a bare column in the node's quals and keys belongs to, or nil.
        def default_identity(plan_node, inherited)
          return @identities[plan_node.alias_name] if plan_node.alias_name

          BITMAPS.include?(plan_node.type) ? inherited : @sole
        end

        # The fingerprint of SQL that must be one SELECT with nothing but a
        # WHERE clause or a one-key ORDER BY. Anything else is unparsed.
        def fingerprint(sql, default)
          result = PgQuery.parse(subplans_as_sql(sql))
          stmts = result.tree.stmts
          select = stmts.first.stmt.select_stmt if stmts.size == 1
          return unparsed unless select && PlanExpression.bare?(select)

          normalize(select, default)
          result.fingerprint
        rescue PgQuery::ParseError
          unparsed
        end

        # Requalifies columns, replaces each clock function with its
        # anchored expression, then drops pg_catalog from the type of every
        # cast of the anchor.
        def normalize(select, default)
          PlanExpression.each_message(select) { |m| requalify(m, default) if m.is_a?(PgQuery::ColumnRef) }
          NodeRewrite.each(select) { |node| (sql = ClockFunctions.anchored_sql(node)) && anchored(sql) }
          PlanExpression.each_message(select) { |m| unqualify_type(m) if m.is_a?(PgQuery::TypeCast) }
        end

        def unqualify_type(cast)
          return unless anchor_call?(cast.arg)

          names = cast.type_name.names
          names.shift if names.first.string&.sval == "pg_catalog"
        end

        def anchored(sql)
          PgQuery.parse("SELECT #{sql}").tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val
        end

        def anchor_call?(node)
          call = node&.func_call
          call && call.args.empty? && call.funcname.map { |part| part.string&.sval } == %w[quaack clock_anchor]
        end

        def unparsed
          @comparable = false
          :unparsed
        end

        # "(NOT (ANY (id = (hashed SubPlan 1).col1)))" becomes
        # "(NOT \"quaack ANY\"((id = (\"hashed SubPlan 1\"()).col1)))". It
        # can change a literal that holds one of these forms, but the
        # fingerprint ignores literals.
        def subplans_as_sql(text)
          text.gsub(SUBPLAN_WRAPPER) { "\"quaack #{Regexp.last_match(1) || Regexp.last_match(2)}\"(" }
              .gsub(SUBPLAN) { "\"#{Regexp.last_match(0)}\"()" }
        end

        # Qualifies a bare column with default, or swaps an alias qualifier
        # for what it stands for. A qualifier that isn't an alias in the plan
        # stays as it is.
        def requalify(column_ref, default)
          fields = column_ref.fields
          if fields.size == 1
            fields.unshift(PgQuery::Node.from_string(default)) if default
          elsif (identity = @identities[fields.first.string&.sval])
            fields[0] = PgQuery::Node.from_string(identity)
          end
        end
      end

      private_constant :Builder
    end
  end
end
