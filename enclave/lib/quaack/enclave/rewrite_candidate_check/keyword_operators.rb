# frozen_string_literal: true

require "pg_query"
require_relative "../name_qualifier"
require_relative "keyword_reach"

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
        # named in operators that the candidate's operands could pick: one
        # with an argument type the candidate can see, one Postgres casts a
        # seen type to implicitly, or a pseudo-type, such as anyelement. A
        # seen type is a column type or the row type of a relation parse
        # reads, a type it
        # casts to, the result type of a function it calls outside
        # pg_catalog, or a literal's type, each with the base types of its
        # domains and the element types of its arrays.
        def check!(operators, schemas, connection, parse)
          return if operators.empty?

          others = schemas - ["pg_catalog"]
          return if others.empty?

          found = connection.exec_params(KeywordReach::SQL, [array(operators), array(others), *seen(parse)]).ntuples
          raise Error.new(RULE, DETAIL) if found.positive?
        end

        LITERAL_TYPES = %w[pg_catalog.text pg_catalog.int4 pg_catalog.int8 pg_catalog.numeric pg_catalog.bool
                           pg_catalog.float8].freeze

        # The relations and type names parse names, each as one qualified,
        # quoted text, and the schemas and names of the functions it calls
        # outside pg_catalog, as text arrays.
        def seen(parse)
          tree = parse.tree
          functions = functions(tree)
          lists = [relations(tree), types(tree) + LITERAL_TYPES, functions.map(&:first), functions.map(&:last)]
          lists.map { array(it) }
        end

        def relations(tree)
          nodes(tree, PgQuery::RangeVar).filter_map { quoted([it.schemaname, it.relname]) unless it.schemaname.empty? }
        end

        def types(tree) = nodes(tree, PgQuery::TypeName).map { |type| quoted(type.names.map { it.string.sval }) }

        def functions(tree)
          nodes(tree, PgQuery::FuncCall).filter_map do |call|
            names = call.funcname.map { it.string.sval }
            names if names.size == 2 && names.first != "pg_catalog"
          end
        end

        def quoted(parts) = parts.map { PG::Connection.quote_ident(it) }.join(".")

        # Every node of type in the tree.
        def nodes(node, type, found = [])
          found << node if node.is_a?(type)
          case node
          when Google::Protobuf::RepeatedField then node.each { nodes(it, type, found) }
          when PgQuery::Node then nodes(node.inner, type, found)
          when Google::Protobuf::MessageExts then node.class.descriptor.each { nodes(it.get(node), type, found) }
          end
          found
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
          when PgQuery::SubLink then sub_link(node)
          end
        end

        # IN (SELECT ...) is an ANY SubLink with no operator name, so its =
        # resolves through the path (20261112-073000-1). One that names its
        # operator, as = ANY (SELECT ...) and every ALL SubLink do,
        # NameQualifier qualifies.
        def sub_link(node)
          ["="] if node.sub_link_type == :ANY_SUBLINK && node.oper_name.empty?
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

        # Every A_Expr, CaseExpr, JoinExpr, and SubLink in the tree, in tree
        # order.
        def walk(node, found = [])
          case node
          when PgQuery::A_Expr, PgQuery::CaseExpr, PgQuery::JoinExpr, PgQuery::SubLink then found << node
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
