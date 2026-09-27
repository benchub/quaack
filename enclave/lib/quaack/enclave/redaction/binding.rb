# frozen_string_literal: true

require "pg_query"
require_relative "../supported_sql"

module Quaack
  module Enclave
    module Redaction
      # A prepared statement's name: a lowercase word.
      STATEMENT_NAME = /\A[a-z_][a-z0-9_]*\z/

      # A declared type: lowercase words, such as integer or bit varying.
      TYPE_NAME = /\A[a-z_][a-z0-9_]*( [a-z_][a-z0-9_]*)*\z/

      # A query written with the placeholders, such as the redacted query
      # or a rewrite candidate, with the real literals to run it with
      # (README 3g: bind them with PREPARE, never splice them in). See
      # Redaction.binding.
      #
      #   bound = Redaction.binding(sql, placeholder_map)
      #   bound.prepare(connection, "quaack_q")    # => the types it declared
      #   bound.execute(connection, "quaack_q")    # => the PG::Result
      #
      # prepare declares every placeholder's type, $1 through $N of the map,
      # so each $n is typed just as its literal was: an integer as integer,
      # a bit string as bit varying, and an untyped string (or NULL) as
      # unknown, which Postgres then types from where it sits. A literal
      # that nothing types, such as the 'a' of concat('a', x), becomes
      # text, but Postgres won't prepare an unknown parameter that nothing
      # types. So when Postgres says it can't type a parameter (SQLSTATE
      # 42P18, which names it), prepare declares that one text and tries
      # again. A placeholder the SQL doesn't use is declared text from the
      # start, as when a rewrite candidate drops a condition. The one
      # difference that leaves is pg_typeof, which sees text, where the
      # literal was unknown. Where the literal fails, as json_agg('x') does,
      # prepare fails too. Inside a transaction, each try runs in a
      # savepoint, so a failed one doesn't end the transaction.
      #
      # execute runs the prepared statement with exec_prepared, so the
      # values go to Postgres as parameters, never in the SQL's text.
      # values, in parameter order, is also what SingleCandidateTest takes
      # as one literal set.
      #
      # A Postgres error becomes Error prepare_failed or execute_failed,
      # with its SQLSTATE and no cause, since Postgres's message can quote
      # a value.
      #
      # A type that isn't lowercase words (TYPE_NAME) is Error bad_type,
      # since the types go into the PREPARE's text.
      #
      # Trust boundary: values are the literals. inspect leaves them out,
      # and the PREPARE holds only the SQL and the types.
      Binding = Data.define(:sql, :types, :values) do
        def prepare(connection, name) = Prepare.new(self, connection, checked(name)).types

        def execute(connection, name)
          Bind.guarded("execute_failed") { connection.exec_prepared(checked(name), values) }
        end

        def prepare_sql(name, declared)
          raise Error, "bad_type" unless declared.all? { TYPE_NAME.match?(it) }

          list = declared.empty? ? "" : " (#{declared.join(", ")})"
          "PREPARE #{checked(name)}#{list} AS #{sql}"
        end

        def checked(name)
          raise ArgumentError, "a prepared statement's name must be a lowercase word" unless STATEMENT_NAME.match?(name)

          name
        end

        def inspect = "#<data #{self.class} sql=#{sql.inspect}, types=#{types}, values=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      # Builds a Binding. The SQL must be exactly one SELECT (Error
      # not_one_select), use only what SupportedSql lists (Error
      # unsupported_construct), and each $n in it must be in the map
      # (Error unknown_placeholder).
      module Bind
        # libpq's PG_DIAG_SQLSTATE and PG_DIAG_MESSAGE_PRIMARY field codes.
        SQLSTATE = "C".ord
        MESSAGE = "M".ord

        module_function

        def for(sql, map)
          used = numbers(parse(sql))
          raise Error, "unknown_placeholder" unless used.all? { |n| map.key?("$#{n}") }

          entries = (1..map.size).map { |n| map.fetch("$#{n}") }
          Binding.new(sql:, types: declared(entries, used).freeze, values: entries.map { it["value"] }.freeze)
        end

        # Each placeholder's type, with an untyped one the SQL doesn't use
        # declared text, since Postgres can't type it from anywhere.
        def declared(entries, used)
          entries.each_with_index.map do |entry, i|
            entry["type"] == "unknown" && !used.include?(i + 1) ? "text" : entry["type"]
          end
        end

        def parse(sql)
          parse = PgQuery.parse(sql)
          stmts = parse.tree.stmts
          raise Error, "not_one_select" unless stmts.size == 1 && stmts.first.stmt.select_stmt

          supported!(parse)
        rescue PgQuery::ParseError
          raise Error, "not_one_select", cause: nil
        end

        # SupportedSql's refusals, such as a data-modifying CTE or FOR
        # UPDATE, as Error unsupported_construct. The message names only
        # the construct, which is shape, but it's left behind all the same.
        def supported!(parse)
          SupportedSql.check!(parse)
          parse
        rescue SupportedSql::Error
          raise Error, "unsupported_construct", cause: nil
        end

        def numbers(parse)
          found = []
          parse.walk! { |_parent, _field, node, _location| found << node.number if node.is_a?(PgQuery::ParamRef) }
          found.uniq
        end

        # Runs the block, turning a Postgres error into Error rule, with only
        # its SQLSTATE.
        def guarded(rule)
          yield
        rescue StandardError => e
          raise unless postgres_error?(e)

          raise Error.new(rule, sqlstate(e)), cause: nil
        end

        def postgres_error?(error) = !error.is_a?(Error) && error.respond_to?(:result)

        def sqlstate(error) = error.result&.error_field(SQLSTATE)

        # The parameter Postgres says it can't type, or nil. Its message is
        # a fixed form with only the parameter's number, and nothing else
        # of it is kept.
        def untyped_parameter(error)
          return nil unless sqlstate(error) == "42P18"

          error.result&.error_field(MESSAGE).to_s[/\Acould not determine data type of parameter \$(\d+)\z/, 1]&.to_i
        end
      end

      # One Binding#prepare: the tries until Postgres takes the types.
      class Prepare
        SAVEPOINT = "quaack_prepare"

        attr_reader :types

        def initialize(binding, connection, name)
          @binding = binding
          @connection = connection
          @name = name
          @types = binding.types.dup
          @savepoint = connection.transaction_status != 0
          nil while (number = attempt) && retype(number)
          @types.freeze
        end

        private

        # nil once it's prepared, or the number of the parameter Postgres
        # couldn't type.
        def attempt
          @connection.exec("SAVEPOINT #{SAVEPOINT}") if @savepoint
          @connection.exec(@binding.prepare_sql(@name, @types))
          @connection.exec("RELEASE SAVEPOINT #{SAVEPOINT}") if @savepoint
          nil
        rescue StandardError => e
          raise unless Bind.postgres_error?(e)

          failed(e)
        end

        def failed(error)
          Bind.guarded("prepare_failed") { roll_back } if @savepoint
          number = Bind.untyped_parameter(error)
          return number if number && @types[number - 1] == "unknown"

          raise Error.new("prepare_failed", Bind.sqlstate(error)), cause: nil
        end

        # ROLLBACK TO keeps the savepoint, so it's released too, or the next
        # try's savepoint would nest inside it and outlive the prepare.
        def roll_back
          @connection.exec("ROLLBACK TO SAVEPOINT #{SAVEPOINT}")
          @connection.exec("RELEASE SAVEPOINT #{SAVEPOINT}")
        end

        def retype(number)
          @types[number - 1] = "text"
        end
      end

      private_constant :Bind, :Prepare

      # Prepares sql as name, each $n declared the type in types, by
      # Binding#prepare's rules, so Postgres doesn't infer a different one
      # from context. PREPARE goes by the simple protocol, which would run
      # a second statement, so sql must be exactly one SELECT, with no
      # data-modifying CTE and no SELECT ... INTO (Error not_one_select). With nil types, it prepares with the extended
      # protocol and Postgres infers every type, raising its own error.
      def self.prepare(connection, name, sql, types)
        return connection.prepare(name, sql) unless types
        raise Error, "not_one_select" unless one_statement?(sql)

        Binding.new(sql:, types:, values: []).prepare(connection, name)
      end

      def self.one_statement?(sql)
        stmts = PgQuery.parse(sql).tree.stmts
        stmts.size == 1 && !stmts.first.stmt.select_stmt.nil? && !writes?(stmts.first.stmt)
      rescue PgQuery::ParseError
        false
      end

      # A data-modifying CTE or SELECT ... INTO, anywhere in the tree. Both
      # parse as a SELECT.
      def self.writes?(node)
        return true if write_node?(node)

        case node
        when Google::Protobuf::RepeatedField then node.any? { |child| writes?(child) }
        when Google::Protobuf::MessageExts then node.class.descriptor.any? { |f| writes?(f.get(node)) }
        else false
        end
      end

      def self.write_node?(node)
        case node
        when PgQuery::SelectStmt then !node.into_clause.nil?
        when PgQuery::CommonTableExpr then node.ctequery.select_stmt.nil?
        else false
        end
      end
    end
  end
end
