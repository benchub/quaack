# frozen_string_literal: true

require "pg_query"
require_relative "keyword_operators"
require_relative "names"

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # Casts Postgres applies on its own through a user function
      # (20261112-110000-1). The parse tree has no node for an implicit
      # cast's function, so Names never sees it: with CREATE CAST (citext AS
      # int) WITH FUNCTION public.ci2int AS IMPLICIT, qty = code calls
      # public.ci2int. A SELECT's expressions apply implicit casts, and
      # assignment casts only to boolean (WHERE, AND, CASE WHEN, and the
      # like) and to bigint (LIMIT and OFFSET). A cast counts when its
      # function is outside pg_catalog, or it's an I/O cast through a type
      # whose output or input function is, and that function doesn't belong
      # to an installed extension (pg_depend deptype 'e'). The user chose
      # this on 2026-11-12: only casts written by hand count, so PostGIS's
      # implicit text -> geometry through public.geometry(text) doesn't.
      #
      # Which expression picks the cast up needs the types Postgres resolves,
      # which the parse doesn't hold. So when a type the candidate sees
      # (KeywordReach) has such a cast, every expression and clause the
      # candidate writes must be one the original writes, text for text, or
      # it's refused with Names' message. Without such a cast, as with
      # citext's own casts, nothing changes.
      module ImplicitCasts
        RULE = "unknown_name"
        DETAIL = Names::DETAIL

        # KeywordReach's seen types, from $1 to $4 in its $3 to $6's place.
        SQL = <<~SQL
          WITH RECURSIVE seen(t) AS (
            SELECT a.atttypid FROM pg_catalog.pg_attribute a
            WHERE a.attrelid OPERATOR(pg_catalog.=) ANY (
                SELECT pg_catalog.to_regclass(r) FROM pg_catalog.unnest($1::pg_catalog.text[]) r)
              AND a.attnum OPERATOR(pg_catalog.>) 0
            UNION SELECT c.reltype FROM pg_catalog.pg_class c
            WHERE c.oid OPERATOR(pg_catalog.=) ANY (
                SELECT pg_catalog.to_regclass(r) FROM pg_catalog.unnest($1::pg_catalog.text[]) r)
            UNION SELECT pg_catalog.to_regtype(n) FROM pg_catalog.unnest($2::pg_catalog.text[]) n
            UNION SELECT p.prorettype FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace pn ON pn.oid OPERATOR(pg_catalog.=) p.pronamespace
            WHERE EXISTS (
              SELECT 1 FROM ROWS FROM (pg_catalog.unnest($3::pg_catalog.text[]), pg_catalog.unnest($4::pg_catalog.text[])) f(s, n)
              WHERE f.s OPERATOR(pg_catalog.=) pn.nspname AND f.n OPERATOR(pg_catalog.=) p.proname)
            UNION SELECT x FROM pg_catalog.pg_type ty JOIN seen ON ty.oid OPERATOR(pg_catalog.=) seen.t,
              LATERAL (VALUES (ty.typbasetype), (ty.typelem)) v(x)
            WHERE x OPERATOR(pg_catalog.<>) 0
          )
          SELECT 1 FROM pg_catalog.pg_cast c
            JOIN pg_catalog.pg_type s ON s.oid OPERATOR(pg_catalog.=) c.castsource
            JOIN pg_catalog.pg_type d ON d.oid OPERATOR(pg_catalog.=) c.casttarget
          WHERE c.castsource OPERATOR(pg_catalog.=) ANY (SELECT t FROM seen)
            AND (c.castcontext OPERATOR(pg_catalog.=) 'i'
              OR (c.castcontext OPERATOR(pg_catalog.=) 'a'
                AND c.casttarget OPERATOR(pg_catalog.=) ANY (ARRAY['pg_catalog.bool'::pg_catalog.regtype,
                                                                   'pg_catalog.int8'::pg_catalog.regtype]::pg_catalog.oid[])))
            AND EXISTS (
              SELECT 1 FROM pg_catalog.pg_proc p
              WHERE p.pronamespace OPERATOR(pg_catalog.<>) 'pg_catalog'::pg_catalog.regnamespace
                AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_depend dep
                  WHERE dep.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_proc'::pg_catalog.regclass
                    AND dep.objid OPERATOR(pg_catalog.=) p.oid
                    AND dep.deptype OPERATOR(pg_catalog.=) 'e')
                AND (p.oid OPERATOR(pg_catalog.=) c.castfunc
                  OR (c.castmethod OPERATOR(pg_catalog.=) 'i'
                    AND p.oid OPERATOR(pg_catalog.=) ANY (ARRAY[s.typoutput, d.typinput]::pg_catalog.oid[]))))
          LIMIT 1
        SQL

        EXPRESSIONS = [PgQuery::A_Expr, PgQuery::FuncCall, PgQuery::CaseExpr, PgQuery::CoalesceExpr,
                       PgQuery::MinMaxExpr, PgQuery::SubLink, PgQuery::A_ArrayExpr, PgQuery::BoolExpr,
                       PgQuery::BooleanTest, PgQuery::RowExpr, PgQuery::TypeCast, PgQuery::JoinExpr].freeze
        CLAUSES = {
          PgQuery::SelectStmt => %i[where_clause having_clause limit_count limit_offset],
          PgQuery::JoinExpr => %i[quals], PgQuery::CaseWhen => %i[expr], PgQuery::FuncCall => %i[agg_filter],
          PgQuery::WindowDef => %i[start_offset end_offset]
        }.freeze

        module_function

        def check!(parse, original_sql, connection)
          original = original_sql ? keys(PgQuery.parse(original_sql).tree) : Set.new
          return if keys(parse.tree).subset?(original)

          found = connection.exec_params(SQL, KeywordOperators.seen(parse)).ntuples
          raise Error.new(RULE, DETAIL) if found.positive?
        end

        # Each expression and clause in tree, as [label, deparsed text].
        def keys(tree)
          found = Set.new
          walk(tree) do |node|
            found << [:expression, text(node)] if EXPRESSIONS.include?(node.class)
            found << [:statement, statement(node)] if set_or_values?(node)
            CLAUSES.fetch(node.class, []).each do |field|
              value = node.public_send(field)
              found << [field, text(value.inner)] if value
            end
          end
          found
        end

        def set_or_values?(node)
          node.is_a?(PgQuery::SelectStmt) && (node.op != :SETOP_NONE || !node.values_lists.empty?)
        end

        def text(node) = KeywordOperators.text(node)

        def statement(node)
          stmt = PgQuery::RawStmt.new(stmt: PgQuery::Node.new(select_stmt: node))
          PgQuery.deparse(PgQuery::ParseResult.new(version: PgQuery::PG_VERSION_NUM, stmts: [stmt]))
        end

        def walk(node, &)
          yield node if node.is_a?(Google::Protobuf::MessageExts) && !node.is_a?(PgQuery::Node)
          case node
          when Google::Protobuf::RepeatedField then node.each { walk(it, &) }
          when PgQuery::Node then walk(node.inner, &)
          when Google::Protobuf::MessageExts then node.class.descriptor.each { walk(it.get(node), &) }
          end
        end
      end
    end
  end
end
