# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "tree"
require_relative "distinct_key_removal/keys"
require_relative "union_to_union_all/arm"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' union_to_union_all. An activity feed often
      # merges several tables' rows with a UNION, and tags each arm's rows
      # with a constant that names their kind, which intake made a
      # placeholder:
      #
      #   SELECT $1 AS kind, posts.id, posts.created_at FROM posts WHERE posts.group_id = $2
      #   UNION SELECT $3, comments.id, comments.created_at FROM comments WHERE comments.group_id = $4
      #
      # UNION sorts or hashes every row to find duplicates that can't be
      # there. posts.id is unique and not null, so no two rows of the first
      # arm are equal, and comments.id does the same for the second. A row
      # of one arm has another tag than every row of the other, when $1 and
      # $3 hold different values. So it's the same as UNION ALL, which
      # Postgres can also flatten, so that a filter or an ORDER BY with a
      # LIMIT around it can use each table's indexes.
      #
      # Why that's sound. UNION keeps one of each set of rows that are
      # equal in every column, NULL equal to NULL, compared in each
      # column's type and collation. Two rows of one arm differ in a key
      # column. The unique assumption says the key's index compares each of
      # its columns as the column's own = does, and not_null that neither
      # value is NULL. Every arm outputs a column of that same type where
      # the key column stands, though maybe with another typmod, as
      # varchar(10) beside varchar(20), so the UNION changes none of their
      # values and compares them by that same =. Two rows of different arms
      # differ in the tag, which the literal oracle checks by asking
      # Postgres for the UNION of the tags alone, in a tree of the same
      # shape: it has a row for every arm only if no two of them are equal.
      # Postgres types each tag there as it does in the query, since a set
      # operation types a column from that column of its arms alone.
      #
      # The oracle answers for the slow literals, and result-comparison runs
      # the rewrite with every literal set (DESIGN.md's literals). literals
      # gives a placeholder another value only where it feeds a comparison
      # with a column, and a tag is a whole select-list item, so every set
      # keeps the tags' slow literals. The rule also refuses a tag
      # placeholder that the query holds anywhere else, which could type it
      # otherwise or feed a comparison.
      #
      # It fires only when all of this holds, and otherwise gives nothing:
      #
      # - Every set operation in the tree is a UNION without ALL.
      # - Each arm is a SELECT of one plain table (see Arm).
      # - Each arm's select list holds every column of a unique, not-null
      #   key of its table (Catalog#keys, best first, as
      #   DistinctKeyRemoval::Keys picks one), each written name.column or
      #   bare, or under a star. Each key column is comparable (see
      #   Catalog#columns): an enum or a built-in type that hashes and
      #   sorts, with no collation or a deterministic one. Where it stands,
      #   every arm outputs a column of its table of the same base type.
      # - In one position, every arm's select list has a tag: a
      #   placeholder, cast or not, that the query holds nowhere else. The
      #   oracle says the UNION finds them all different.
      #
      # It states each arm's key unique and each of its columns not null.
      # It gives one rewrite for each UNION it can take, each made from the
      # original, so the generator's second pass takes two.
      class UnionToUnionAll
        Keys = DistinctKeyRemoval::Keys

        def name = "union_to_union_all"

        def description
          "A UNION becomes UNION ALL when each arm selects a unique, not-null key of its one table and a tag " \
            "placeholder that differs from every other arm's, so no two of its rows can be equal."
        end

        def rewrites(parse, catalog, literals = nil)
          return [] unless literals

          counts = Tree.find(parse.tree, PgQuery::ParamRef).map(&:number).tally
          roots(parse.tree).each_with_index.filter_map do |root, i|
            assumptions = assumptions(root, counts, catalog, literals)
            next unless assumptions

            tree = Deparse.copy(parse.tree)
            all!(roots(tree)[i])
            Rewrite.new(tree:, assumptions:)
          end
        end

        private

        # Every SELECT in tree that's a UNION and not an arm of another set
        # operation, in tree order.
        def roots(tree)
          selects = Tree.find_all(tree, PgQuery::SelectStmt)
          arms = selects.flat_map { [it.larg, it.rarg] }.compact
          selects.select { |select| select.op == :SETOP_UNION && arms.none? { it.equal?(select) } }
        end

        def all!(select)
          return if select.op == :SETOP_NONE

          select.all = true
          all!(select.larg)
          all!(select.rarg)
        end

        # The assumptions that state every arm's key, each once, or nil
        # unless the UNION can't give two equal rows.
        def assumptions(root, counts, catalog, literals)
          arms = arms(root, catalog)
          return unless arms

          keys = arms.map { key(it, arms, catalog) }
          return unless keys.all?

          keys.flatten(1).uniq if tag_positions(arms, counts).any? { tagged_apart?(root, arms, it, literals) }
        end

        # The Arms under root, left to right, or nil unless each SELECT
        # there is one, and all of them output as many columns.
        def arms(root, catalog)
          arms = leaves(root)&.map { Arm.read(it, catalog) }
          arms if arms&.all? && arms.map { it.outputs.size }.uniq.size == 1
        end

        # The SELECTs under select, left to right, or nil unless every set
        # operation there is a UNION without ALL.
        def leaves(select)
          case select.op
          when :SETOP_NONE then [select]
          when :SETOP_UNION
            left = leaves(select.larg) unless select.all
            right = leaves(select.rarg) if left
            left + right if right
          end
        end

        # unique and not_null for a key of the arm's table that its select
        # list holds, or nil.
        def key(arm, arms, catalog)
          columns = arm.outputs.each_index.filter_map { key_column(arm, arms, it, catalog) }.uniq
          key = Keys.candidates(catalog, arm.table, columns).find do |candidate|
            Keys.unique_not_null(arm.table, candidate).all? { catalog.met?(it) }
          end
          Keys.unique_not_null(arm.table, key) if key
        end

        # The column of the arm's table that it outputs at position, if it's
        # comparable and every arm outputs a column of its base type there.
        def key_column(arm, arms, position, catalog)
          column = arm.outputs[position].column
          return unless column && comparable?(arm.table, column, catalog)

          column if arms.map { base_type(it, position, catalog) }.uniq.size == 1
        end

        def comparable?(table, column, catalog)
          catalog.columns(table.schemaname, table.relname).find { it.name == column }&.comparable
        end

        def base_type(arm, position, catalog)
          column = arm.outputs[position].column
          catalog.column_info(arm.table.schemaname, arm.table.relname, column)&.base_type if column
        end

        # The positions where every arm outputs a tag that the query holds
        # only there.
        def tag_positions(arms, counts)
          arms.first.outputs.each_index.select do |position|
            arms.all? { counts[tag(it.outputs[position].node)] == 1 }
          end
        end

        # The number of a placeholder, cast or not, or nil.
        def tag(node)
          node = node.type_cast.arg while node&.node == :type_cast
          node.param_ref.number if node&.node == :param_ref
        end

        # Whether the UNION of the arms' tags at position alone has a row
        # for every arm.
        def tagged_apart?(root, arms, position, literals)
          tags = tags(root, arms.map { it.outputs[position].node })
          literals.holds?("(SELECT pg_catalog.count(*) FROM (#{tags}) quaack_tags) " \
                          "OPERATOR(pg_catalog.=) #{arms.size}")
        rescue Deparse::Error
          false
        end

        # A UNION of the shape of select's, of one SELECT of each tag in
        # nodes, which it takes in order.
        def tags(select, nodes)
          return "SELECT #{Deparse.expression(nodes.shift)}" if select.op == :SETOP_NONE

          "(#{tags(select.larg, nodes)}) UNION (#{tags(select.rarg, nodes)})"
        end
      end
    end
  end
end
