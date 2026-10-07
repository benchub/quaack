# frozen_string_literal: true

require "digest"
require "json"
require "pg_query"
require_relative "build_connection"
require_relative "build_order"
require_relative "index_build_sql"
require_relative "index_store"

module Quaack
  module Enclave
    # DESIGN.md's index-build: builds every distinct index QUAACK proposed and ranked,
    # records its size, and hides it.
    #
    #   IndexBuild.build(store, connection)  # writes index_build
    #   IndexBuild.show_only(connection, build, "original:top:1", sql:)
    #   IndexBuild.confirm(connection, build, visible_names, sql:)
    #
    # The indexes come from each index_ranking_<search> ("original" and each
    # rewrite_<n>): its top entries and its combination, plus the GIN, GiST,
    # and SP-GiST candidates index-dedupe set aside in index_search_<search>, and the
    # unused low-cardinality B-tree candidates index-test set aside there. Unique
    # candidates are never built, so only proposed non-unique indexes are
    # ever hidden. index_build is:
    #   "indexes"      { name => { "ddl", "size" } }
    #   "combinations" { "<search>:top:<n>" | "<search>:combination" |
    #                    "<search>:set_aside:<n>" => [name] }
    # Each name is quaack_ and a hash of the DDL, in the table's schema, so a
    # rerun finds and skips an index it already built. The DDL can hold a
    # literal, so index_build stays in the store. An Error's message is its
    # rule, which ErrorFilter sends out.
    module IndexBuild
      Error = Class.new(StandardError) { def rule = message }

      SETTINGS = { "maintenance_work_mem" => "1GB", "max_parallel_maintenance_workers" => "4" }.freeze

      module_function

      # starting, if given, is called before each index is built with its
      # 1-based position, the total, and its stored DDL, which can hold a
      # literal, so the caller must redact it before it leaves. built, if
      # given, is called with the built indexes before index_build is written.
      def build(store, connection, starting: nil, built: nil)
        BuildConnection.configure(connection)
        combinations = combinations(store)
        indexes = create_all(connection, BuildOrder.ddls(combinations), starting)
        hide_all(connection, "indexes" => indexes)
        built&.call(indexes)
        store.write("index_build", "indexes" => indexes,
                                   "combinations" => combinations.transform_values { it.map { name(it) } })
      end

      # Builds each of ddls, telling starting first, and returns
      # { name => { "ddl", "size" } }.
      def create_all(connection, ddls, starting)
        ddls.each_with_index.to_h do |ddl, i|
          starting&.call(i + 1, ddls.size, ddl)
          [name(ddl), { "ddl" => ddl, "size" => create(connection, name(ddl), ddl) }]
        end
      end

      # Every search's combinations, as DDL lists.
      def combinations(store)
        searches(store).each_with_object({}) do |search, out|
          ranked(store.read("index_ranking_#{search}")).each { |key, ddl| out["#{search}:#{key}"] = ddl }
          set_aside(store, search).each_with_index { |ddl, i| out["#{search}:set_aside:#{i + 1}"] = [ddl] }
        end
      end

      def ranked(ranking)
        top = ranking["top"].each_with_index.to_h { |e, i| ["top:#{i + 1}", e["ddl"]] }
        ranking["combination"] ? top.merge("combination" => ranking["combination"]["ddl"]) : top
      end

      def searches(store)
        rewrites = (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.map { "rewrite_#{it}" }.to_a
        (["original"] + rewrites).select { store.entry?("index_ranking_#{it}") }
      end

      # index-dedupe's GIN, GiST, and SP-GiST candidates, then the unused
      # low-cardinality B-tree ones index-test set aside (index_search's
      # "set_aside", absent from entries written before 20260927-11).
      def set_aside(store, search)
        entry = store.read("index_search_#{search}")
        (entry["dedupe"]["set_aside"] + entry.fetch("set_aside", []))
          .map { IndexStore.candidate(it) }.reject(&:unique).map(&:to_ddl)
      end

      def index_stmt(ddl) = PgQuery.parse(ddl).tree.stmts.first.stmt.index_stmt

      def name(ddl) = "quaack_#{Digest::SHA256.hexdigest(ddl)[0, 20]}"

      # Builds the index unless it's there, and returns its size in bytes.
      def create(connection, name, ddl)
        stmt = index_stmt(ddl)
        raise Error, "index_build_unique" if stmt.unique

        schema = stmt.relation.schemaname
        raise Error, "index_build_unqualified" if schema.empty?

        BuildConnection.cancel_orphans(connection, name)
        unless oid(connection, schema, name)
          stmt.idxname = name
          connection.exec(PgQuery.deparse_stmt(stmt))
        end
        size(connection, oid(connection, schema, name))
      end

      def size(connection, oid) = connection.exec_params(SIZE_SQL, [oid]).getvalue(0, 0).to_i

      def oid(connection, schema, name) = connection.exec_params(OID_SQL, [schema, name]).values.dig(0, 0)

      # Each of build's index names, mapped to its table's schema.
      def schemas(build) = build["indexes"].transform_values { index_stmt(it["ddl"]).relation.schemaname }

      # Sets indisvalid for QUAACK's own non-unique indexes only, matched on
      # schema and name. schemas is one schema for every name, or a name =>
      # schema hash (see schemas).
      def set_valid(connection, names, valid, schemas:)
        pairs = names.map { [schemas.is_a?(Hash) ? schemas.fetch(it) : schemas, it] }
        enc = PG::TextEncoder::Array.new
        connection.exec_params(SET_VALID_SQL, [valid, enc.encode(pairs.map(&:first)), enc.encode(pairs.map(&:last))])
      end

      def hide(connection, names, schemas:) = set_valid(connection, names, false, schemas:)

      def hide_all(connection, build) = hide(connection, build["indexes"].keys, schemas: schemas(build))

      # Unhides the combination named key and hides every other index in
      # build, then confirms with EXPLAIN. Returns the combination's names.
      def show_only(connection, build, key, sql:, params: [])
        visible = build["combinations"].fetch(key)
        hide(connection, build["indexes"].keys - visible, schemas: schemas(build))
        set_valid(connection, visible, true, schemas: schemas(build))
        confirm(connection, build, visible, sql:, params:)
        visible
      end

      # Raises unless the catalog shows exactly visible as valid among
      # build's indexes, and a plain EXPLAIN of sql uses none of the rest.
      def confirm(connection, build, visible, sql:, params: [])
        hidden = build["indexes"].keys - visible
        used = index_names(JSON.parse(connection.exec_params("EXPLAIN (FORMAT JSON) #{sql}", params).getvalue(0, 0)))
        raise Error, "index_build_hidden_index_used" if used.intersect?(hidden)

        raise Error, "index_build_wrong_set_hidden" unless valid_names(connection, build) == visible.sort
      end

      # The names of build's indexes that are valid, matched on schema and name.
      def valid_names(connection, build)
        pairs = schemas(build).to_a
        enc = PG::TextEncoder::Array.new
        connection.exec_params(VALID_NAMES_SQL, [enc.encode(pairs.map(&:last)), enc.encode(pairs.map(&:first))])
                  .column_values(0)
      end

      def index_names(node)
        return node.flat_map { index_names(it) } if node.is_a?(Array)
        return [] unless node.is_a?(Hash)

        node.flat_map { |k, v| k == "Index Name" ? [v] : index_names(v) }
      end
    end
  end
end
