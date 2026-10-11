# frozen_string_literal: true

require "pg_query"
require_relative "../name_qualifier"

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # Operators written as keywords (20261011-12). IN, LIKE, ILIKE,
      # SIMILAR TO, BETWEEN, IS DISTINCT FROM, NULLIF, simple CASE, USING,
      # and NATURAL have no qualified spelling, so Postgres finds their
      # operators through the search path, and a user schema's operator of
      # the same name can win: one ahead of pg_catalog with the same
      # signature, or one anywhere on the path with a closer one, such as
      # citext's. The original's keyword forms resolve on the run server as
      # in production, under the same path. A candidate's keyword form the
      # original doesn't write, argument for argument, is refused when a
      # schema on the path other than pg_catalog has an operator of its name.
      module KeywordOperators
        RULE = "unknown_name"
        DETAIL = "a rewrite may use IN, LIKE, BETWEEN, or another keyword form the original doesn't " \
                 "only when no schema on the search path but pg_catalog has an operator of its name"
        BETWEEN = %w[>= <=].freeze
        NOT_BETWEEN = %w[< >].freeze

        module_function

        # The operator names of the candidate's keyword forms the original
        # doesn't write, from the parse alone.
        def unmade(parse, original_sql)
          made = forms(original_sql ? PgQuery.parse(original_sql).tree : nil).to_set(&:first)
          forms(parse.tree).reject { made.include?(it.first) }.flat_map(&:last).uniq
        rescue PgQuery::ParseError
          forms(parse.tree).flat_map(&:last).uniq
        end

        # Raises Error if a schema in schemas but pg_catalog has an operator
        # named in operators.
        def check!(operators, schemas, connection)
          return if operators.empty?

          others = schemas - ["pg_catalog"]
          return if others.empty?

          found = connection.exec_params(<<~SQL, [array(operators), array(others)]).ntuples
            SELECT 1 FROM pg_catalog.pg_operator o JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) o.oprnamespace
            WHERE o.oprname OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.text[])
              AND n.nspname OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.text[]) LIMIT 1
          SQL
          raise Error.new(RULE, DETAIL) if found.positive?
        end

        def array(strings) = PG::TextEncoder::Array.new.encode(strings)

        # Each keyword form in tree, as [its deparsed text, its operator names].
        def forms(tree)
          walk(tree).filter_map do |node|
            operators = operators(node)
            [text(node), operators] if operators
          end
        end

        def operators(node)
          case node
          when PgQuery::A_Expr then a_expr(node)
          when PgQuery::CaseExpr then ["="] if node.arg
          when PgQuery::JoinExpr then ["="] if node.is_natural || !node.using_clause.empty?
          end
        end

        # Every A_Expr kind but those NameQualifier qualifies is a keyword
        # form. BETWEEN's name is the keyword, not an operator.
        def a_expr(node)
          return if NameQualifier::OPERATOR_KINDS.include?(node.kind)

          case node.kind
          when :AEXPR_BETWEEN, :AEXPR_BETWEEN_SYM then BETWEEN
          when :AEXPR_NOT_BETWEEN, :AEXPR_NOT_BETWEEN_SYM then NOT_BETWEEN
          else node.name.map { it.string.sval }.then { it.empty? ? ["="] : it }
          end
        end

        def text(node)
          if node.is_a?(PgQuery::JoinExpr)
            from = PgQuery::Node.new(join_expr: node)
            select = PgQuery::SelectStmt.new(from_clause: [from], limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
          else
            target = PgQuery::Node.new(res_target: PgQuery::ResTarget.new(val: PgQuery::Node.from(node)))
            select = PgQuery::SelectStmt.new(target_list: [target], limit_option: :LIMIT_OPTION_DEFAULT,
                                             op: :SETOP_NONE)
          end
          stmt = PgQuery::RawStmt.new(stmt: PgQuery::Node.new(select_stmt: select))
          PgQuery.deparse(PgQuery::ParseResult.new(version: PgQuery::PG_VERSION_NUM, stmts: [stmt]))
        end

        # Every A_Expr, CaseExpr, and JoinExpr in the tree, in tree order.
        def walk(node, found = [])
          case node
          when PgQuery::A_Expr, PgQuery::CaseExpr, PgQuery::JoinExpr then found << node
          end
          case node
          when Google::Protobuf::RepeatedField then node.each { walk(it, found) }
          when PgQuery::Node then walk(node.inner, found)
          when Google::Protobuf::MessageExts then node.class.descriptor.each { walk(it.get(node), found) }
          end
          found
        end
      end
    end
  end
end
