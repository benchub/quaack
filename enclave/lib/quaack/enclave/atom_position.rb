# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # DESIGN.md's unchanged-atoms: which of the original's untested atoms
    # (vacuity-guard) the rewrite left alone, by structural position.
    #
    #   AtomPosition.unchanged(original_sql, candidate_sql, paths)
    #   # => [true, false, ...], one per path, true only when that atom is unchanged
    #
    # Both queries are the unbound ones, with their $n placeholders. paths
    # are the untested atoms' PredicateAtoms paths into the original's parse.
    # The answer is false for every atom unless the test can show the atom
    # unchanged: a parse it can't classify (a set operation, a WITH, a
    # subquery, function, table function, or sample in FROM, a VALUES list,
    # more than one statement), a different scope signature (everything in
    # the one SELECT but its WHERE, HAVING, and join ONs, so a locking clause
    # or INTO counts), an atom it can't place, a different number of copies
    # of the atom's key, or any top-level atom in the rewrite that the
    # original lacks (a new filter can hide what an untested atom never
    # exercised, so it changes every atom). Never raises for a query it can't parse: that's
    # all false.
    #
    # Trust boundary: it reads parse trees and returns booleans. Nothing it
    # computes holds SQL text, and the caller sends only a subset of shapes
    # already sent.
    module AtomPosition
      # A message's field values, or a list's items.
      module Tree
        module_function

        def children(node)
          case node
          when Google::Protobuf::RepeatedField then node.to_a
          when Google::Protobuf::MessageExts then node.class.descriptor.map { |field| field.get(node) }
          else []
          end
        end

        def copy(message) = message.class.decode(message.class.encode(message))
      end

      # One top-level atom: its path, parse node, and position key.
      Top = Data.define(:path, :node, :key)

      # The constructs the test doesn't classify, anywhere in the query.
      UNCLASSIFIED_NODES = [PgQuery::RangeSubselect, PgQuery::RangeFunction, PgQuery::RangeTableFunc,
                            PgQuery::RangeTableSample, PgQuery::CommonTableExpr].freeze

      module_function

      def unchanged(original_sql, candidate_sql, paths)
        none = Array.new(paths.size, false)
        original = Analysis.of(original_sql)
        candidate = Analysis.of(candidate_sql)
        return none unless original && candidate

        return none if candidate.new_atoms?(original)

        paths.map { |path| original.unchanged?(path, candidate) }
      rescue PgQuery::ParseError
        none
      end

      # The shapes among shapes (the untested atoms' redacted shapes, in the
      # order of paths) that the rewrite left unchanged. A shape counts only
      # if every atom with that shape is unchanged, since the report works by
      # shape. Always a subset of shapes.
      def unchanged_shapes(original_sql, candidate_sql, shapes, paths)
        pairs = shapes.zip(unchanged(original_sql, candidate_sql, paths))
        shapes.uniq.select { |shape| pairs.all? { |other, same| other != shape || same } }
      end

      # One query's top-level SELECT: its scope signature and top-level atoms.
      class Analysis
        BASE = ["stmts", 0, "stmt", "select_stmt"].freeze

        attr_reader :scope, :tops

        # nil when the query isn't one the test classifies.
        def self.of(sql)
          tree = PgQuery.parse(sql).tree
          select = tree.stmts.size == 1 ? tree.stmts[0].stmt&.select_stmt : nil
          return nil if select.nil? || unclassified?(tree)

          new(select)
        end

        def self.unclassified?(node)
          case node
          when PgQuery::SelectStmt then unsupported_select?(node) || children_unclassified?(node)
          when *UNCLASSIFIED_NODES then true
          else children_unclassified?(node)
          end
        end

        def self.children_unclassified?(node) = Tree.children(node).any? { unclassified?(it) }

        def self.unsupported_select?(select)
          select.op != :SETOP_NONE || !select.values_lists.empty?
        end

        def initialize(select)
          @scope = Signature.of(scope_copy(select))
          @tops = []
          clause(select.where_clause, BASE + ["where_clause"])
          clause(select.having_clause, BASE + ["having_clause"])
          select.from_clause.each_with_index { |item, i| joins(item, BASE + ["from_clause", i]) }
          @counts = @tops.map(&:key).tally
        end

        # Whether the atom at path, an atom of the original, is unchanged in
        # the candidate: its top-level atom has the same key the same number
        # of times.
        def unchanged?(path, candidate)
          top = tops.find { path.first(it.path.size) == it.path } or return false

          @counts[top.key] == candidate.counts[top.key]
        end

        # Whether this (the candidate) has a top-level atom, in any WHERE,
        # HAVING, or ON, that the original lacks. A new filter can hide the
        # rows an untested atom never exercised, so it changes every atom.
        def new_atoms?(original)
          tops.any? { !original.counts.key?(it.key) }
        end

        protected

        attr_reader :counts

        private

        # The SELECT with its WHERE, HAVING, and every join's ON removed.
        def scope_copy(select)
          copy = Tree.copy(select)
          copy.where_clause = nil
          copy.having_clause = nil
          copy.from_clause.each { strip_quals(it) }
          copy
        end

        def strip_quals(item)
          join = item.join_expr or return
          join.quals = nil
          strip_quals(join.larg)
          strip_quals(join.rarg)
        end

        def joins(item, path)
          join = item.join_expr or return
          clause(join.quals, path + %w[join_expr quals])
          joins(join.larg, path + %w[join_expr larg])
          joins(join.rarg, path + %w[join_expr rarg])
        end

        # The atoms of one clause, split on AND, OR, and NOT as
        # PredicateAtoms splits them. An atom under an OR or NOT carries the
        # whole outermost such expression in its key.
        def clause(node, path, whole: nil, clause_path: path)
          return if node.nil?

          bool = node.bool_expr
          if bool
            whole ||= Signature.of(node) unless bool.boolop == :AND_EXPR
            bool.args.each_with_index do |arg, i|
              clause(arg, path + ["bool_expr", "args", i], whole:, clause_path:)
            end
          elsif !constant?(node)
            @tops << Top.new(path:, node:, key: [@scope, clause_path, whole, Signature.of(node)])
          end
        end

        def constant?(node) = !(node.a_const || node.type_cast&.arg&.a_const).nil?
      end

      # A canonical text of a parse node, with no locations: equal text means
      # equal trees. Every identifier, $n, and constant counts.
      module Signature
        module_function

        def of(node)
          case node
          when Google::Protobuf::RepeatedField then "[#{node.map { of(it) }.join(",")}]"
          when Google::Protobuf::MessageExts then message(node)
          else node.inspect
          end
        end

        def message(node)
          fields = node.class.descriptor.filter_map do |field|
            next if field.name.end_with?("location") || field.name == "stmt_len"

            value = field.get(node)
            "#{field.name}=#{of(value)}" unless value.nil?
          end
          "#{node.class.name.split("::").last}(#{fields.join(",")})"
        end
      end
    end
  end
end
