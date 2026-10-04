# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "polymorphic_key_copy/query"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' polymorphic_key_copy, a heuristic rule checked
      # against the data. Where a SELECT joins child.<x> = parent.id and
      # filters parent.<p>_type = $m and parent.<p>_id = $n, Rails's
      # polymorphic convention, and the child has its own column for that
      # class, named Rails's way, this adds child.<column> = $n to the
      # WHERE and keeps every original predicate, so Postgres can narrow the
      # child before the join.
      #
      # It only adds a predicate, so it can drop rows but never add them,
      # and it drops none if every joined row of that type has the child's
      # column equal to parent.<p>_id. The schema can't say that, so the
      # rewrite states it as a denormalized_equal assumption, and assumption-check checks
      # it against the data.
      #
      # The rule never reads the type literal. For each child column named
      # <stem>_id, it turns the stem into the class names whose Rails name
      # it is (snake_case for CamelCase and _ for ::, so foo_bar_id is
      # FooBar's or Foo::Bar's), and asks the literal oracle whether $m is
      # one of them. A column with a foreign key fires only if every one
      # points at the stem's table, the stem plus s or es. When two columns
      # could match for one join, it refuses. The child and parent are
      # plain tables, not on an outer join's nullable side; the join and
      # filters are top-level conjuncts of the WHERE or of an inner join's
      # ON, each column qualified, each constant a bare placeholder.
      class PolymorphicKeyCopy
        # A stem's most words; each word boundary doubles the class names to
        # ask about.
        MAX_WORDS = 4
        STEM = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

        Match = Data.define(:join, :type_filter, :id_filter, :column, :class_name)

        def name = "polymorphic_key_copy"

        def description
          "Where a joined parent is filtered to one Rails polymorphic type and id, the child's own column for " \
            "that type is filtered to the same id."
        end

        def rewrites(parse, catalog, literals)
          return [] unless literals

          Tree.find(parse.tree, PgQuery::SelectStmt).each_with_index.flat_map do |select, i|
            Query.new(select).joins.flat_map { matches(it, catalog, literals) }.map { rewrite(parse, i, it) }
          end
        end

        private

        # The one match for a join, or none: refused when two columns could
        # match, and skipped when the query already has the copy.
        def matches(join, catalog, literals)
          found = join.pairs.flat_map do |type_filter, id_filter|
            columns(join.child, type_filter.param, catalog, literals).map do |column, class_name|
              Match.new(join:, type_filter:, id_filter:, column:, class_name:)
            end
          end
          return [] unless found.size == 1

          match = found.first
          join.query.copied?(join.qualifier, match.column, match.id_filter.param) ? [] : found
        end

        # [column, class name] for each column of table one of whose class
        # names $param is, and whose foreign keys allow it.
        def columns(table, param, catalog, literals)
          catalog.column_names(table.schemaname, table.relname).filter_map do |column|
            stem = column.delete_suffix("_id")
            names = class_names(stem) if column.end_with?("_id")
            next unless names && literals.holds?("$#{param} IN (#{names.map { "'#{it}'" }.join(", ")})")

            class_name = names.find { literals.holds?("$#{param} = '#{it}'") }
            [column, class_name] if referenced?(catalog, table, column, stem)
          end
        end

        # Every class name whose Rails name is stem, or nil for a stem that
        # isn't plain lowercase words or has more than MAX_WORDS.
        def class_names(stem)
          words = stem.split("_")
          return unless STEM.match?(stem) && words.size <= MAX_WORDS

          capitalized = words.map { it[0].upcase + it[1..] }
          ["", "::"].repeated_permutation(words.size - 1).map { capitalized.zip(it).flatten.compact.join }
        end

        def referenced?(catalog, table, column, stem)
          catalog.referenced_tables(table.schemaname, table.relname, column)
                 .all? { ["#{stem}s", "#{stem}es"].include?(it) }
        end

        def rewrite(parse, index, match)
          tree = Deparse.copy(parse.tree)
          select = Tree.find(tree, PgQuery::SelectStmt)[index]
          select.where_clause = Tree.all_of(Tree.conjuncts(select.where_clause) + [copy(match)])
          Rewrite.new(tree:, assumptions: [assumption(match)])
        end

        def copy(match) = Query.equality(match.join.qualifier, match.column, match.id_filter.param)

        def assumption(match)
          join = match.join
          { "kind" => "denormalized_equal", "table" => table_name(join.child), "column" => match.column,
            "join_column" => join.child_column, "references_table" => table_name(join.parent),
            "references_column" => "id", "type_column" => match.type_filter.column,
            "type_value" => match.class_name, "id_column" => match.id_filter.column }
        end

        def table_name(range) = "#{range.schemaname}.#{range.relname}"
      end
    end
  end
end
