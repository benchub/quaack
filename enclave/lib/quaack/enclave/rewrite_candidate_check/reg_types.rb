# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "reg_values"

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # RegValues' last check, which Postgres's types show (20261008-31).
      # Each string literal becomes a $n with no type, the candidate is
      # prepared, which evaluates nothing, and it's refused if any comes
      # back as a reg type, an array of one, or a domain over either, as
      # pg_relation_filenode('s.t') or COALESCE($1::regclass, 's.t') would.
      # The original's $n get its types. If it doesn't prepare, such as
      # when a literal's type can't be worked out, it's refused with one
      # fixed rule.
      module RegTypes
        STATEMENT = "quaack_reg_types"
        TEXT_OID = 25

        # Whether any of the types, through domains and array elements, is
        # a reg type.
        REG_SQL = <<~SQL
          WITH RECURSIVE t(oid) AS (
            SELECT * FROM pg_catalog.unnest($1::pg_catalog.oid[])
            UNION
            SELECT v.x FROM t JOIN pg_catalog.pg_type y ON y.oid OPERATOR(pg_catalog.=) t.oid
            CROSS JOIN LATERAL (VALUES (y.typbasetype), (y.typelem)) AS v(x)
            WHERE v.x OPERATOR(pg_catalog.<>) 0
          )
          SELECT EXISTS (
            SELECT 1 FROM t JOIN pg_catalog.pg_type y ON y.oid OPERATOR(pg_catalog.=) t.oid
            WHERE y.typnamespace OPERATOR(pg_catalog.=) 'pg_catalog'::pg_catalog.regnamespace
              AND y.typname OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.name[])
          )
        SQL

        UNTYPED = "the candidate doesn't prepare with its string literals as parameters"

        module_function

        def check!(parse, original, connection)
          tree, count = literals_as_params(parse.tree, original.placeholders)
          return if count.zero?

          types = prepare(connection, PgQuery.deparse(tree), declared(parse.tree, original, count))
          raise Error.new("untyped_literal", UNTYPED) unless types
          raise Error.new("unsupported_reg_literal", RegValues::REG_DETAIL) if reg?(connection, types.last(count))
        end

        def reg?(connection, types)
          encoder = PG::TextEncoder::Array.new
          found = connection.exec_params(REG_SQL, [encoder.encode(types), encoder.encode(RegValues::TYPES)])
          found.getvalue(0, 0) == "t"
        end

        # The original's $n get its types, or none if they aren't known, and
        # text if the candidate doesn't use them, so they needn't be worked
        # out. The literals' $n get none.
        def declared(tree, original, count)
          used = RegValues.walk(tree, PgQuery::ParamRef).to_set(&:number)
          own = Array.new(original.placeholders) do |i|
            used.include?(i + 1) ? original.param_types&.[](i) || 0 : TEXT_OID
          end
          own + Array.new(count, 0)
        end

        # The parameter types, or nil if it doesn't prepare. Inside a
        # transaction, a savepoint keeps a failure from ending it.
        def prepare(connection, sql, types)
          saved = connection.transaction_status == PG::PQTRANS_INTRANS
          connection.exec("SAVEPOINT #{STATEMENT}") if saved
          described(connection, sql, types).tap do |found|
            connection.exec("#{found ? "RELEASE" : "ROLLBACK TO"} SAVEPOINT #{STATEMENT}") if saved
          end
        end

        def described(connection, sql, types)
          connection.prepare(STATEMENT, sql, types)
          begin
            described = connection.describe_prepared(STATEMENT)
            Array.new(described.nparams) { described.paramtype(it) }
          ensure
            connection.exec("DEALLOCATE #{STATEMENT}")
          end
        rescue PG::Error
          nil
        end

        # A copy of the tree with each string literal a $n after the
        # original's, and how many there were. EXTRACT's field stays.
        def literals_as_params(tree, after)
          copy = tree.class.decode(tree.class.encode(tree))
          numbers = ((after + 1)..).each
          replace(copy, numbers)
          [copy, numbers.peek - after - 1]
        end

        def replace(node, numbers)
          case node
          when Array, Google::Protobuf::RepeatedField then node.each { replace(it, numbers) }
          when PgQuery::Node then replace_node(node, numbers)
          when Google::Protobuf::MessageExts then fields(node).each { replace(it, numbers) }
          end
        end

        def replace_node(node, numbers)
          return replace(node.inner, numbers) unless node.a_const&.val == :sval

          node.param_ref = PgQuery::ParamRef.new(number: numbers.next)
        end

        # The message's fields, but EXTRACT's field.
        def fields(message)
          extract = message.is_a?(PgQuery::FuncCall) && RegValues.name(message) == "extract" &&
                    message.funcformat == :COERCE_SQL_SYNTAX
          message.class.descriptor.map do |field|
            extract && field.name == "args" ? message.args.to_a.drop(1) : field.get(message)
          end
        end
      end
    end
  end
end
