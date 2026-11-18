# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "pick_checks"

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
      # gives one of the query's answers. But forcing every pick first,
      # then every pick last, doesn't stand for the rest, so checked adds
      # PickChecks to each pick, which fail the query when it has a real
      # choice.
      #
      # DISTINCT and set operations are forced only below the top level,
      # and at the top level of a query with no ORDER BY, LIMIT, or OFFSET,
      # since the subquery drops the order the rows come out in. At an
      # ordered top level, ResultComparison's tiebreaker already refuses
      # them when they can keep either of two rows. An aggregate with
      # DISTINCT keeps its values sorted and isn't forced.
      #
      # A window function (task 20261015-5) that numbers or reads rows in
      # its window's order, whatever its frame (ORDERED_WINDOWS), picks
      # among rows that tie on that order. It's forced by adding the text
      # of each of its select's input rows to its ORDER BY: each FROM item's
      # whole row, or in a grouped select its GROUP BY keys. rank and its
      # kin (TIED_WINDOWS), and an ordinary aggregate over its default
      # frame (PEER_AGGREGATES), give tied rows one value and pick nothing.
      # So is any window function over a frame of ROWS without EXCLUDE GROUP
      # or TIES, whose frame an added key only orders. Any other window
      # function, such as first_value over the default frame, or one over a
      # named window, is Unforceable, since adding a key would change which
      # rows its frame holds.
      #
      # verdict runs the original's checked query and, once the candidate
      # matches, the candidate's forced and checked queries.
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

        # Aggregates that keep one of several values Postgres calls equal,
        # which can print differently, as numeric's 10 and 10.0 do.
        EXTREMES = %w[min max].to_set.freeze

        # Window functions whose value turns on the order of tied rows but
        # not on the frame, so a forced ORDER BY keeps their answer one
        # Postgres could give.
        ORDERED_WINDOWS = %w[row_number ntile lag lead].to_set.freeze

        # Window functions that give rows tied on the window's order one value.
        TIED_WINDOWS = %w[rank dense_rank percent_rank cume_dist].to_set.freeze

        # Aggregates whose window value over the default frame, which holds
        # every row tied with the current one, doesn't turn on their order.
        PEER_AGGREGATES = %w[
          count sum avg min max bool_and bool_or every bit_and bit_or
          stddev stddev_pop stddev_samp variance var_pop var_samp
        ].to_set.freeze

        # Postgres's frame_options for a window with no frame clause.
        DEFAULT_FRAME = 1058

        # frame_options bits: ROWS, and EXCLUDE GROUP or EXCLUDE TIES.
        FRAME_ROWS = 0x4
        FRAME_EXCLUDE_PEERS = 0x30000

        # The alias of the subquery a forced DISTINCT or set operation
        # reads, and the name of its whole row.
        PICK = "quaack_pick"

        # A DISTINCT ON whose * can't be named, since a FROM item has no
        # name, as an unaliased subquery doesn't.
        class Unforceable < StandardError; end

        module_function

        # The verdict of original against candidate, with their picks
        # checked. compare yields the verdict of the original against a
        # Shape, and run runs one SQL query. Forcing every pick first, then
        # every pick last, can't stand for every answer, since picks can go
        # different ways: two sites, two groups of one site, or a pick
        # between the first and the last. So each pick must have no real
        # choice on the data: its values, or for an aggregate the values in
        # each run of rows its own ORDER BY ties, all print the same
        # (checked). The original's must, or its answer can turn on how
        # Postgres picks, and that's unsupported_order. A matching
        # candidate's forced runs are answers it could give, so each must
        # match too, and then its picks must have no choice either, or it's
        # unsupported_order. Postgres failing a forced or checked run, as
        # when a forced arm resolves a literal on its own, is
        # unsupported_order too, and nothing runs after it, since the
        # failure ends the transaction.
        #
        # The two queries run as written first, so a query that fails on the
        # data fails as it would with no picks.
        def verdict(original, candidate, run, &compare)
          verdict = compare.call(candidate)
          original_refusal(original, run) || candidate_verdict(original, candidate, verdict, run, &compare)
        end

        # unsupported_order when the original's checked run fails, or nil.
        def original_refusal(original, run)
          guarded(original, :original_pick) do
            run.call(checked(original)) if checks?(original)
            nil
          end
        end

        def candidate_verdict(original, candidate, verdict, run, &)
          return verdict unless verdict.match? && checks?(candidate)

          guarded(original, :rewrite_pick) do
            (picks?(candidate) && forced_runs(candidate, &).find { !it.match? }) ||
              (run.call(checked(candidate)) && verdict)
          end
        end

        # The block's value, or unsupported_order when a run in it fails: a
        # checked run's check failing (PickChecks' division by zero) refuses
        # for pick, the side whose pick had a choice, and any other failure
        # for pick_run_failed. A cancel QUAACK didn't send goes up.
        def guarded(original, pick)
          yield
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)

          reason = e.sqlstate == PickChecks::FAILED ? pick : :pick_run_failed
          ResultComparator::Verdict.for(original.mode, :unsupported_order, reason:)
        end

        # Lazily, compare's verdict for shape forced each way.
        def forced_runs(shape, &compare)
          [false, true].lazy.map { compare.call(forced(shape, it)) }
        end

        # Whether shape's query has a pick to force.
        def picks?(shape)
          shape.kept(%i[picks any]) do
            force(shape.tree, descending: false, top: shape.mode == :multiset).last.positive?
          end
        end

        # Whether shape's query has a pick to check: one to force, or a
        # GROUP BY or a min or max, which keep one of the values Postgres
        # calls equal (EXTREMES) but need no forcing, since the check alone
        # proves they had no choice.
        def checks?(shape)
          shape.kept(%i[picks checks]) { picks?(shape) || printed?(shape.tree) }
        end

        def printed?(node)
          case node
          when Hash
            node[:group_clause]&.any? ||
              (node[:func_call] && checked_extreme?(node[:func_call])) ||
              node.values.any? { printed?(it) }
          when Array then node.any? { printed?(it) }
          else false
          end
        end

        def checked_extreme?(call) = extreme?(call) || window_extreme?(call)

        # Whether the original or the candidate SQL has a pick, or one
        # compare can't parse or force, so that equal results aren't yet a
        # match.
        def any?(original, candidate, binding: nil)
          checks?(Shape.parse(original, :original, binding:)) || checks?(Shape.parse(candidate, :candidate, binding:))
        rescue Unforceable, Error
          true
        end

        # The Shape of shape's query with its picks forced (force). Raises
        # Error deparse_mismatch when it doesn't round-trip.
        def forced(shape, descending) = Shape.parse(forced_sql(shape, descending:), shape.query, binding: shape.binding)

        # The SQL of shape's query with its picks forced first and checked
        # (force), which fails on the data when a pick has a choice.
        def checked(shape) = forced_sql(shape, descending: false, check: true)

        def forced_sql(shape, descending:, check: false)
          shape.kept([:picks, descending, check]) do
            tree = force(shape.tree, descending:, top: shape.mode == :multiset, check:).first
            Deparse.faithfully(PgQuery::ParseResult.new(tree))
          end
        rescue Deparse::Error
          raise Error.new(:deparse_mismatch, query: shape.query), cause: nil
        end

        # tree with each pick forced to keep the first (or, descending, the
        # last) by text, and how many picks it forced. top is whether the
        # top level's DISTINCT or set operation can be forced too. check
        # adds to each pick a check that divides by zero when it has a
        # choice (CHECKS). Raises Unforceable.
        def force(tree, descending:, top:, check: false)
          tree = copy(tree)
          root = tree[:stmts].first[:stmt][:select_stmt]
          # Innermost first, so an aggregate's copies of its arguments carry
          # the aggregates inside them already forced.
          [tree, force_aggregates!(root, descending, check) + force_selects(root, descending, top, check)]
        end

        # Forces each aggregate pick, and checks each min or max when
        # check, and returns how many it forced.
        def force_aggregates!(root, descending, check)
          aggregates(root).reverse.count do |node|
            next force_aggregate!(node, descending, check) || true unless extreme?(node[:func_call])

            check && node.replace(PickChecks.extreme(node[:func_call])) && false
          end
        end

        def force_selects(root, descending, top, check)
          ([root] + InnerCuts.selects(root)).reverse.sum do |select|
            windows = force_windows!(select, descending, check)
            check_groups!(select) if check
            windows + force_distinct_on!(select, descending, check) +
              (top || !select.equal?(root) ? force_dedup!(select, descending, check) : 0)
          end
        end

        # Forces each window function pick in select's own level, and
        # returns how many it forced. Raises Unforceable for a window it
        # can't force.
        def force_windows!(select, descending, check)
          windows(select).count do |node|
            call = node[:func_call]
            picked = window_pick?(call) && (force_window!(select, node, descending, check) || true)
            node.replace(PickChecks.window_extreme(call, copy(node))) if check && window_extreme?(call)
            picked
          end
        end

        # A min or max over one argument in a window, which keeps one of the
        # values in its frame that Postgres calls equal (EXTREMES).
        def window_extreme?(call)
          names = call[:funcname].map { it.dig(:string, :sval) }
          (names.size == 1 || (names.size == 2 && names.first == "pg_catalog")) && EXTREMES.include?(names.last) &&
            call[:args]&.size == 1 && call[:over]
        end

        def force_window!(select, node, descending, check)
          parts = input_texts(select)
          return if parts.empty?

          call = node[:func_call]
          forced = { func_call: copy(call).merge(over: window_forced(call[:over], parts, descending)) }
          node.replace(check ? PickChecks.window(call, parts, forced) : forced)
        end

        def window_forced(over, parts, descending)
          copy(over).merge(order_clause: Array(copy(over[:order_clause])) + parts.map { sort(copy(it), descending) })
        end

        # Whether call is a window pick to force, false for one that picks
        # nothing, raising Unforceable for one it can't force.
        def window_pick?(call)
          name = window_name(call)
          return true if ORDERED_WINDOWS.include?(name) || rows_frame?(call[:over])
          return false if TIED_WINDOWS.include?(name) || peer_aggregate?(call, name)

          raise Unforceable
        end

        # call's function name, raising Unforceable for a named window or a
        # function outside pg_catalog.
        def window_name(call)
          over = call[:over]
          raise Unforceable if over[:name] || over[:refname]

          names = call[:funcname].map { it.dig(:string, :sval) }
          raise Unforceable unless names.size == 1 || (names.size == 2 && names.first == "pg_catalog")

          names.last
        end

        # Whether over's frame counts rows, which an added sort key only
        # orders, without EXCLUDE GROUP or TIES, which read the peers.
        def rows_frame?(over)
          options = over[:frame_options]
          options.anybits?(FRAME_ROWS) && options.nobits?(FRAME_EXCLUDE_PEERS)
        end

        def peer_aggregate?(call, name)
          PEER_AGGREGATES.include?(name) && call[:over][:frame_options] == DEFAULT_FRAME &&
            !call[:agg_distinct] && !call[:agg_order]
        end

        # The texts that tell select's input rows apart: its GROUP BY keys
        # when grouped, none when it aggregates with no GROUP BY, since it
        # then has one row, or else its FROM items' whole rows, none with no
        # FROM.
        def input_texts(select)
          if Array(select[:group_clause]).any?
            select[:group_clause].map { text(PickChecks.resolved(select, it)) }
          elsif own_aggregate?(select)
            []
          else
            Array(select[:from_clause]).flat_map { item_names(it) }.map { text(star(*it)) }
          end
        end

        # The window function calls in select's own level, not in its
        # subqueries, set operation arms, or WINDOW clause.
        def windows(node)
          case node
          when Hash
            own = node[:func_call]&.dig(:over) ? [node] : []
            own + node.except(:select_stmt, :larg, :rarg, :window_clause).values.flat_map { windows(it) }
          when Array then node.flat_map { windows(it) }
          else []
          end
        end

        # Whether node's own level, outside its subqueries, set operation
        # arms, and WINDOW clause, calls a catalog aggregate outside a window.
        def own_aggregate?(node)
          case node
          when Hash
            call = node[:func_call]
            (call && !call[:over] && (call[:agg_star] || known_aggregate?(call))) ||
              node.except(:select_stmt, :larg, :rarg, :window_clause).values.any? { own_aggregate?(it) }
          when Array then node.any? { own_aggregate?(it) }
          else false
          end
        end

        def known_aggregate?(call)
          names = call[:funcname].map { it.dig(:string, :sval) }
          (names.size == 1 || (names.size == 2 && names.first == "pg_catalog")) &&
            (AGGREGATES | EXTREMES | PEER_AGGREGATES).include?(names.last)
        end

        # Adds to select's HAVING the check that its GROUP BY keys print one
        # way in each group.
        def check_groups!(select)
          check = PickChecks.grouped(select) or return
          having = select[:having_clause]
          select[:having_clause] = having ? PickChecks.both(having, check) : check
        end

        # Each aggregate's node, min and max among them, outermost first.
        def aggregates(node)
          case node
          when Hash
            call = node[:func_call]
            own = call && (aggregate?(call) || extreme?(call)) ? [node] : []
            own + node.values.flat_map { aggregates(it) }
          when Array then node.flat_map { aggregates(it) }
          else []
          end
        end

        def aggregate?(call)
          catalog_aggregate?(call[:funcname].map { it.dig(:string, :sval) }) && !call[:over] && !call[:agg_distinct]
        end

        # A min or max over one argument, outside a window.
        def extreme?(call)
          names = call[:funcname].map { it.dig(:string, :sval) }
          (names.size == 1 || (names.size == 2 && names.first == "pg_catalog")) && EXTREMES.include?(names.last) &&
            call[:args]&.size == 1 && !call[:over]
        end

        def catalog_aggregate?(names)
          (names.size == 1 || (names.size == 2 && names.first == "pg_catalog")) && AGGREGATES.include?(names.last)
        end

        def force_aggregate!(node, descending, check)
          call = node[:func_call]
          forced = { func_call: copy(call).merge(agg_order: Array(copy(call[:agg_order])) +
                                                            call[:args].map { sort(text(copy(it)), descending) }) }
          node.replace(check ? PickChecks.aggregate(call, forced) : forced)
        end

        # Sorts a DISTINCT ON's ties by the text of each output column, and
        # returns how many it forced. With no ORDER BY, it sorts by the
        # DISTINCT ON keys first, as Postgres requires.
        def force_distinct_on!(select, descending, check)
          keys = Array(select[:distinct_clause])
          return 0 unless keys.any? { !it.empty? }

          sorts = distinct_on_sorts(select, keys)
          select[:sort_clause] = sorts + output_keys(select).map { sort(it, descending) } +
                                 distinct_on_checks(select, keys, sorts, check)
          1
        end

        def distinct_on_sorts(select, keys)
          sorts = Array(select[:sort_clause])
          sorts.empty? ? keys.map { sort(copy(it), false) } : sorts
        end

        def distinct_on_checks(select, keys, sorts, check)
          check ? [sort(PickChecks.distinct_on(select, keys, sorts), false)] : []
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
        def force_dedup!(select, descending, check)
          if Array(select[:distinct_clause]) == [{}]
            select.replace(distinct_whole_rows(select.except(:distinct_clause), descending, check))
            return 1
          end
          return 0 if select[:all]

          force_set_operation!(select, descending, check)
        end

        def force_set_operation!(select, descending, check)
          case select[:op]
          when :SETOP_UNION then select.replace(distinct_whole_rows(select.merge(all: true), descending, check))
          # EXCEPT and INTERSECT keep the left arm's row of each group.
          when :SETOP_EXCEPT, :SETOP_INTERSECT
            select[:larg] = distinct_whole_rows(select[:larg], descending, check)
          else return 0
          end
          1
        end

        # SELECT DISTINCT ON (PICK) PICK.* FROM (inner) PICK ORDER BY PICK,
        # PICK::text, the last DESC when descending, and when checked, a
        # check that divides by zero when equal rows don't all print the
        # same.
        def distinct_whole_rows(inner, descending, check)
          row = { column_ref: { fields: [name(PICK)] } }
          checks = check ? [sort(PickChecks.dedup(row), false)] : []
          {
            target_list: [{ res_target: { val: star(PICK) } }],
            from_clause: [{ range_subselect: { subquery: { select_stmt: inner }, alias: { aliasname: PICK } } }],
            distinct_clause: [copy(row)],
            sort_clause: [sort(copy(row), false), sort(text(row), descending)] + checks,
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
