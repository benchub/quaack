# frozen_string_literal: true

require_relative "index_candidate"
require_relative "plan_expression"

module Quaack
  module Enclave
    # The README 5a-2 patterns, for GeneratorTwo's walk. It's private to the
    # enclave namespace. Each pattern takes one PlanNode and returns the
    # candidates it proposes there, with nil for any the IndexCandidate
    # constructor refused. The walk supplies columns (a PlanColumns) and the
    # helpers build, extend_index, at_least?, scan_table, scan_conjuncts,
    # own_columns, constant_columns, by_selectivity, and selectivity.
    #
    # "Constant equality columns" below are the columns in conjuncts like
    # `col = literal` or `col = $1`. A column or string the walk can't map
    # is left out (see PlanColumns), so a pattern with nothing left to key
    # on proposes nothing.
    module GeneratorTwoPatterns
      SCAN_QUALS = ["Filter", "Index Cond", "Recheck Cond"].freeze

      module ScanPatterns
        # Seq Scan whose Filter removes most rows: a btree on the Filter's
        # constant equality columns, most selective first. The plan can't
        # show how much each conjunct removes, so a `col = literal` conjunct
        # removes most rows on its own when 1 - its
        # TableStatistics#equality_selectivity is at least most_rows_removed.
        # Each one gets a partial index WHERE that conjunct, keyed on the
        # Filter's other columns, constant equality columns first. With no
        # other columns there's no partial index, because the plain btree on
        # the column already covers it. A `col = $1` conjunct can't be a
        # predicate. The IndexCandidate constructor refuses both an empty key
        # and a parameter, so build gives nil for them, and a Filter with no
        # constant equality columns proposes nothing.
        def seq_scan(node)
          table = scan_table(node, "Seq Scan")
          return [] unless table && at_least?(node.removed_fraction, :most_rows_removed)

          conjuncts = scan_conjuncts(node, ["Filter"])
          equality = by_selectivity(constant_columns(conjuncts, node.alias_name)).map(&:name)
          [build(table, key: equality), *partials(table, conjuncts, node.alias_name, equality)]
        end

        def partials(table, conjuncts, alias_name, equality)
          columns = (equality + own_columns(conjuncts, alias_name).map(&:name)).uniq
          conjuncts.select { |c| removes_most_alone?(c) }.map do |c|
            build(table, key: columns - [c.columns.first.name], predicate: PlanExpression.unqualified_sql(c.node))
          end
        end

        # A scan's own Filter can only compare its own columns to constants,
        # because Postgres prints another relation's column there as a
        # parameter, so the conjunct's column is the scan's.
        def removes_most_alone?(conjunct)
          return false unless conjunct.kind == :constant

          selectivity = selectivity(conjunct.columns.first)
          at_least?(selectivity && (1 - selectivity), :most_rows_removed)
        end

        # Index Scan or Bitmap Heap Scan whose Filter and recheck remove many
        # rows: the index in use, found by "Index Name" in
        # TableStatistics#indexes (for a Bitmap Heap Scan, on its one child
        # Bitmap Index Scan), extended with the Filter's columns, constant
        # equality columns first: once in the key, and once as INCLUDE
        # columns. An index that isn't listed or maps to nil is skipped, and
        # so is a variant its method can't take.
        def filtered_index_scan(node)
          table = scan_table(node, "Index Scan", "Bitmap Heap Scan")
          existing = table.indexes[index_name(node)] if table && many_rows_removed?(node)
          added = existing ? filter_columns(node) - existing.key.map(&:name) : []
          added.empty? ? [] : extended(existing, added)
        end

        def extended(existing, added)
          [extend_index(existing, key: existing.key + added, include: existing.include - added),
           extend_index(existing, include: (existing.include + added).uniq)]
        end

        def many_rows_removed?(node)
          at_least?(node.removed_fraction, :many_rows_removed) && at_least?(node.removed * node.loops, :many_rows_min)
        end

        def filter_columns(node)
          own_columns(scan_conjuncts(node, ["Filter"]), node.alias_name, constant_first: true).map(&:name)
        end

        def index_name(node)
          return node["Index Name"] if node.type == "Index Scan"

          node.children.find { |c| c.type == "Bitmap Index Scan" }&.[]("Index Name")
        end

        # Bitmap Heap Scan over a BitmapAnd or BitmapOr: one index on the
        # columns of the single-column indexes it combines, in plan order,
        # when there are at least two. Only a Bitmap Heap Scan has Bitmap
        # Index Scans under it, so this reads any scan.
        def bitmap_combination(node)
          table = columns.table(node)
          scans = table ? bitmap_index_scans(node) : []
          names = scans.filter_map { |s| single_column(table.indexes[s["Index Name"]]) }.uniq
          names.size > 1 ? [build(table, key: names)] : []
        end

        def single_column(index) = (index.key.first.name if index&.key&.size == 1)

        def bitmap_index_scans(node)
          node.children.flat_map do |child|
            case child.type
            when "Bitmap Index Scan" then [child]
            when "BitmapAnd", "BitmapOr" then bitmap_index_scans(child)
            else []
            end
          end
        end
      end

      # Nested Loop with an expensive inner side, and Hash Join with a large
      # inner build. A join equality is a conjunct `a = b` with a under an
      # alias on the inner side and b under one outside it.
      module JoinPatterns
        # For each inner relation in a join equality, from the Nested Loop's
        # Join Filter or the inner scans' quals: an index on its join
        # columns, then the other columns of its scan's quals, constant
        # equality columns first.
        def nested_loop(node)
          inner = node.inner if node.type == "Nested Loop"
          return [] unless inner && at_least?(inner.loops * inner.rows, :expensive_inner_rows)

          aliases = inner_aliases(inner)
          join_columns(nested_loop_conjuncts(node, aliases), aliases).map do |alias_name, keys|
            join_index(keys, scan_quals(alias_name))
          end
        end

        def nested_loop_conjuncts(node, aliases)
          columns.conjuncts(node, ["Join Filter"], columns.sole_alias) + aliases.flat_map { |a| scan_quals(a) }
        end

        def scan_quals(alias_name) = scan_conjuncts(columns.scan(alias_name))

        # For each inner relation in a Hash Cond equality: an index on its
        # join columns.
        def hash_join(node)
          hash = node.inner if node.type == "Hash Join"
          return [] unless hash && large_hash?(hash)

          conjuncts = columns.conjuncts(node, ["Hash Cond"], columns.sole_alias)
          join_columns(conjuncts, inner_aliases(hash)).values.map { |keys| join_index(keys) }
        end

        def large_hash?(hash)
          at_least?(hash.rows, :large_hash_rows) || at_least?(hash["Hash Batches"].to_f, :large_hash_batches)
        end

        def inner_aliases(inner) = inner.subtree.map(&:alias_name).select { |a| columns.scan(a) }

        # Each inner alias's columns in join equalities, in order.
        def join_columns(conjuncts, inner_aliases)
          columns = conjuncts.select { |c| c.kind == :join }.filter_map do |c|
            # A join conjunct has two columns under different aliases.
            inner = c.columns.select { |column| inner_aliases.include?(column.alias_name) }
            inner.first if inner.size == 1
          end
          columns.group_by(&:alias_name)
        end

        # The join columns, then the columns of the scan's other quals.
        def join_index(keys, quals = [])
          others = own_columns(quals, keys.first.alias_name, constant_first: true)
          build(keys.first.table, key: (keys + others).map(&:name).uniq)
        end
      end

      # Sort, and an aggregate fed by a Sort or a hash.
      module OrderPatterns
        # Sort or Incremental Sort, whatever its method: the constant
        # equality columns of the scans below it that read the first sort
        # key's relation, most selective first, then the sort keys with their
        # direction and nulls ordering. The sort keys stop at the first one
        # that isn't a plain column of that relation. Postgres already drops
        # a sort key that an equality makes constant, so none of the sort
        # keys repeats an equality column.
        def sort(node)
          keys = node.sort? ? columns.sort_keys(node["Sort Key"]) : []
          return [] if keys.empty?

          lead = keys.first.first
          sorted = keys.map do |column, direction, nulls|
            IndexCandidate::KeyColumn.new(name: column.name, direction:, nulls:)
          end
          [build(lead.table, key: equality_names(node, lead.alias_name) + sorted)]
        end

        # Every node's quals are read, and constant_columns keeps only the
        # alias's own columns.
        def equality_names(node, alias_name)
          # Only the alias's one scan has any, so there are no repeats.
          by_selectivity(node.subtree.flat_map { |n| constant_columns(scan_conjuncts(n), alias_name) }).map(&:name)
        end

        # Aggregate with Strategy Hashed, or Sorted over a Sort: for each
        # relation in its Group Key, an index on its group keys, in order.
        def aggregate(node)
          return [] unless node.type == "Aggregate" && sorted_or_hashed?(node)

          columns.group_columns(node["Group Key"]).group_by(&:alias_name).map do |_, group|
            build(group.first.table, key: group.map(&:name))
          end
        end

        def sorted_or_hashed?(node)
          node["Strategy"] == "Hashed" || (node["Strategy"] == "Sorted" && node.children.any?(&:sort?))
        end
      end

      include ScanPatterns
      include JoinPatterns
      include OrderPatterns

      # Every pattern's candidates for one node, in this order.
      def patterns(node)
        seq_scan(node) + filtered_index_scan(node) + bitmap_combination(node) + sort(node) +
          nested_loop(node) + hash_join(node) + aggregate(node)
      end
    end

    private_constant :GeneratorTwoPatterns
  end
end
