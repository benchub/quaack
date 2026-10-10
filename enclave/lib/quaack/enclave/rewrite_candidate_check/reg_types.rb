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
      # The original's $n get its types. A literal whose $n Postgres can't
      # type, as in an "any" argument (concat('a', name), json_build_object),
      # reads as text there, so it's declared text and tried again
      # (20261008-39). If it still doesn't prepare, it's refused with one
      # fixed rule.
      module RegTypes
        STATEMENT = "quaack_reg_types"
        TEXT_OID = 25
        # SQLSTATE indeterminate_datatype.
        INDETERMINATE = "42P18"

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

          types = typed(connection, PgQuery.deparse(tree), declared(parse.tree, original, count), original.placeholders)
          raise Error.new("untyped_literal", UNTYPED) unless types
          raise Error.new("unsupported_reg_literal", RegValues::REG_DETAIL) if reg?(connection, types.last(count))
        end

        # IndexDdlCheck's: RegValues' parse checks, with no original to make
        # the same call, then this check on probe, a SELECT of the index's
        # key expressions and predicate, FROM the index's table so a column
        # has its type. The DDL has no $n.
        def check_index!(probe, relation, connection)
          RegValues.syntactic!(probe, nil)
          probe.tree.stmts.first.stmt.select_stmt.from_clause << PgQuery::Node.from(relation)
          check!(probe, Original.new(relations: [], placeholders: 0), connection)
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

        # The parameter types, or nil if it doesn't prepare. A literal whose
        # $n Postgres can't type, as in an "any" argument such as
        # concat('a', name), where the literal itself reads as text, is
        # declared text and tried again. The original's $n are never
        # declared this way, so one with no known type still fails.
        def typed(connection, sql, types, own)
          types = types.dup
          types.size.times do
            found = prepare(connection, sql, types)
            return found unless found.is_a?(PG::Error)

            number = untyped_number(found)
            return nil unless number&.between?(own + 1, types.size) && types[number - 1].zero?

            types[number - 1] = TEXT_OID
          end
          nil
        end

        # The $n a "could not determine data type" error names, or nil for
        # any other error.
        def untyped_number(error)
          return nil unless error.result&.error_field(PG::PG_DIAG_SQLSTATE) == INDETERMINATE

          error.message[/\$(\d+)/, 1]&.then { Integer(it, 10) }
        end

        # The parameter types, or the PG::Error if it doesn't prepare. Inside
        # a transaction, a savepoint keeps a failure from ending it.
        def prepare(connection, sql, types)
          saved = connection.transaction_status == PG::PQTRANS_INTRANS
          connection.exec("SAVEPOINT #{STATEMENT}") if saved
          found = described(connection, sql, types)
          connection.exec("#{found.is_a?(PG::Error) ? "ROLLBACK TO" : "RELEASE"} SAVEPOINT #{STATEMENT}") if saved
          found
        end

        def described(connection, sql, types)
          connection.prepare(STATEMENT, sql, types)
          begin
            described = connection.describe_prepared(STATEMENT)
            Array.new(described.nparams) { described.paramtype(it) }
          ensure
            connection.exec("DEALLOCATE #{STATEMENT}")
          end
        rescue PG::Error => e
          e
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
