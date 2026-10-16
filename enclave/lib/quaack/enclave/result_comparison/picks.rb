# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparison
      # Arbitrary picks, and the query with each one forced one way or the
      # other (task 20261008-67). A pick keeps one of several answers
      # Postgres is free to choose between, and the fixture shows only the
      # one it chose:
      #
      # - DISTINCT ON keeps one row of each group, the first by its ORDER
      #   BY, and any of the rows that tie on that.
      # - An aggregate whose value follows the order its rows arrive in
      #   (AGGREGATES): any_value keeps one, array_agg, string_agg and the
      #   json ones list them, in an order their own ORDER BY fixes only as
      #   far as it goes.
      # - DISTINCT, and a UNION, INTERSECT, or EXCEPT without ALL, keeps one
      #   of several rows Postgres calls equal, such as jsonb's {"a": 1.0}
      #   for {"a": 1.00}.
      #
      # forced writes each pick so it keeps the first, or the last, by the
      # text of what it keeps:
      #
      # - DISTINCT ON sorts its ties by the text of each output column, or
      #   of each whole row a * stands for.
      # - An aggregate sorts its rows by the text of its arguments, after
      #   its own ORDER BY.
      # - DISTINCT becomes DISTINCT ON the whole row of a subquery that
      #   keeps duplicates (PICK), sorted by the row and then its text. A
      #   UNION does the same over its UNION ALL. EXCEPT and INTERSECT keep
      #   their left arm's row of each group, so that arm alone is made
      #   distinct that way.
      #
      # Each forced pick is one Postgres could make, so a forced query
      # gives one of the query's answers. Two rows whose texts are the same
      # in every column look the same to the comparator, so when the
      # first and the last are the same, so is every row in between.
      #
      # DISTINCT and set operations are forced only below the top level,
      # and at the top level of a query with no ORDER BY, LIMIT, or OFFSET,
      # since the subquery drops the order the rows come out in. At an
      # ordered top level, ResultComparison's tiebreaker already refuses
      # them when they can keep either of two rows. An aggregate with
      # DISTINCT keeps its values sorted and isn't forced, nor is one in a
      # window (OVER), whose picks are a known gap.
      #
      # verdict runs the forced queries: the original's, which must match
      # the original, and, once the candidate matches, the candidate's.
      #
      # It works on the parse tree's hash (PgQuery's to_h) and returns a
      # new one, with nothing shared with the tree it was given.
      module Picks # rubocop:disable Metrics/ModuleLength -- one rewrite per kind of pick
        AGGREGATES = %w[
          any_value array_agg string_agg xmlagg json_agg jsonb_agg json_agg_strict jsonb_agg_strict
          json_object_agg jsonb_object_agg json_object_agg_strict jsonb_object_agg_strict
          json_object_agg_unique jsonb_object_agg_unique json_object_agg_unique_strict
          jsonb_object_agg_unique_strict
        ].to_set.freeze

        # The alias of the subquery a forced DISTINCT or set operation
        # reads, and the name of its whole row.
        PICK = "quaack_pick"

        # A DISTINCT ON whose * can't be named, since a FROM item has no
        # name, as an unaliased subquery doesn't.
        class Unforceable < StandardError; end

        module_function

        # The verdict of original against candidate, with their picks
        # checked. compare yields the verdict of the original against a
        # Shape. When either forced run of the original doesn't match it,
        # its answer turns on how Postgres picks, and that's
        # unsupported_order. A matching candidate's forced runs are answers
        # it could give, so each must match too.
        def verdict(original, candidate, &compare)
          if picks?(original) && forced_runs(original, &compare).any? { !it.match? }
            return ResultComparator::Verdict.for(original.mode, :unsupported_order)
          end

          verdict = compare.call(candidate)
          return verdict unless verdict.match? && picks?(candidate)

          forced_runs(candidate, &compare).find { !it.match? } || verdict
        end

        # Lazily, compare's verdict for shape forced each way.
        def forced_runs(shape, &compare)
          [false, true].lazy.map { compare.call(forced(shape, it)) }
        end

        # Whether shape's query has a pick to force.
        def picks?(shape) = force(shape.tree, descending: false, top: shape.mode == :multiset).last.positive?

        # The Shape of shape's query with its picks forced (force). Raises
        # Error deparse_mismatch when it doesn't round-trip.
        def forced(shape, descending)
          tree = force(shape.tree, descending:, top: shape.mode == :multiset).first
          Shape.parse(Deparse.faithfully(PgQuery::ParseResult.new(tree)), shape.query)
        rescue Deparse::Error
          raise Error.new(:deparse_mismatch, query: shape.query), cause: nil
        end

        # tree with each pick forced to keep the first (or, descending, the
        # last) by text, and how many picks it forced. top is whether the
        # top level's DISTINCT or set operation can be forced too. Raises
        # Unforceable.
        def force(tree, descending:, top:)
          tree = Marshal.load(Marshal.dump(tree))
          root = tree[:stmts].first[:stmt][:select_stmt]
          forced = aggregates(root).each { force_aggregate!(it, descending) }.size
          [tree, forced + force_selects(root, descending, top)]
        end

        def force_selects(root, descending, top)
          ([root] + InnerCuts.selects(root)).reverse.sum do |select|
            force_distinct_on!(select, descending) +
              (top || !select.equal?(root) ? force_dedup!(select, descending) : 0)
          end
        end

        def aggregates(node)
          case node
          when Hash
            own = node[:func_call] && aggregate?(node[:func_call]) ? [node[:func_call]] : []
            own + node.values.flat_map { aggregates(it) }
          when Array then node.flat_map { aggregates(it) }
          else []
          end
        end

        def aggregate?(call)
          catalog_aggregate?(call[:funcname].map { it.dig(:string, :sval) }) && !call[:over] && !call[:agg_distinct]
        end

        def catalog_aggregate?(names)
          (names.size == 1 || (names.size == 2 && names.first == "pg_catalog")) && AGGREGATES.include?(names.last)
        end

        def force_aggregate!(call, descending)
          call[:agg_order] = Array(call[:agg_order]) + call[:args].map { sort(text(copy(it)), descending) }
        end

        # Sorts a DISTINCT ON's ties by the text of each output column, and
        # returns how many it forced.
        def force_distinct_on!(select, descending)
          return 0 unless Array(select[:distinct_clause]).any? { !it.empty? }

          select[:sort_clause] = Array(select[:sort_clause]) + output_keys(select).map { sort(it, descending) }
          1
        end

        def output_keys(select)
          Array(select[:target_list]).flat_map { output_texts(select, it[:res_target][:val]) }
        end

        def output_texts(select, value)
          fields = value.dig(:column_ref, :fields)
          return [text(copy(value))] unless fields&.last&.key?(:a_star)
          return [text(copy(value))] if fields.size > 1

          Array(select[:from_clause]).flat_map { item_names(it) }.map { text(star(*it)) }
        end

        # The names that qualify each relation a FROM item reads, for a *.
        def item_names(item)
          return join_names(item[:join_expr]) if item[:join_expr]

          aliased = item.values.first[:alias]&.fetch(:aliasname)
          return [[aliased]] if aliased

          relation = item[:range_var] or raise Unforceable
          [[relation[:schemaname], relation[:relname]].compact]
        end

        def join_names(join)
          return [[join.dig(:alias, :aliasname)]] if join[:alias]

          item_names(join[:larg]) + item_names(join[:rarg])
        end

        # Forces a DISTINCT or a set operation without ALL, and returns how
        # many it forced.
        def force_dedup!(select, descending)
          if Array(select[:distinct_clause]) == [{}]
            select.replace(distinct_whole_rows(select.except(:distinct_clause), descending))
            return 1
          end
          return 0 if select[:all]

          force_set_operation!(select, descending)
        end

        def force_set_operation!(select, descending)
          case select[:op]
          when :SETOP_UNION then select.replace(distinct_whole_rows(select.merge(all: true), descending))
          # EXCEPT and INTERSECT keep the left arm's row of each group.
          when :SETOP_EXCEPT, :SETOP_INTERSECT then select[:larg] = distinct_whole_rows(select[:larg], descending)
          else return 0
          end
          1
        end

        # SELECT DISTINCT ON (PICK) PICK.* FROM (inner) PICK ORDER BY PICK,
        # PICK::text, the last DESC when descending.
        def distinct_whole_rows(inner, descending)
          row = { column_ref: { fields: [name(PICK)] } }
          {
            target_list: [{ res_target: { val: star(PICK) } }],
            from_clause: [{ range_subselect: { subquery: { select_stmt: inner }, alias: { aliasname: PICK } } }],
            distinct_clause: [copy(row)],
            sort_clause: [sort(copy(row), false), sort(text(row), descending)],
            limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE
          }
        end

        def star(*qualifiers) = { column_ref: { fields: qualifiers.map { name(it) } + [{ a_star: {} }] } }
        def name(sval) = { string: { sval: } }
        def text(node) = { type_cast: { arg: node, type_name: { names: [name("text")], typemod: -1 } } }

        def sort(node, descending)
          { sort_by: { node:, sortby_dir: descending ? :SORTBY_DESC : :SORTBY_DEFAULT,
                       sortby_nulls: :SORTBY_NULLS_DEFAULT } }
        end

        def copy(node) = Marshal.load(Marshal.dump(node))
      end
    end
  end
end
