# frozen_string_literal: true

require_relative "table_name"

module Quaack
  module Enclave
    # Steps 9a, 9b, and 9e, reused by 10b and 10c: open a transaction on
    # arena with statement_timeout, load a fixture, run queries, and always
    # roll back, so arena stays empty between tests.
    #
    #   runner = ArenaRunner.new(arena_connection, statement_timeout_ms: 10_000)
    #   runner.with_fixture(rows, inserts: statements) do |tx|
    #     [tx.query(original), tx.query(candidate)]
    #   end
    #
    # with_fixture returns the block's value. A block can run any number of
    # queries against the one loaded fixture, which 9c needs to run the
    # original twice. Retrying with rebuilt rows is another with_fixture call.
    #
    # The connection is a live PG::Connection to arena, passed in. Arena setup
    # (4b, task 20260922-27) isn't built yet. pg isn't an enclave dependency
    # yet either, so this uses only the methods of the connection it's handed
    # and never names a PG constant.
    #
    # Results and fixture values stay in the enclave. Nothing here goes
    # through egress. Postgres errors can carry real values, such as a unique
    # violation's key or a check violation's whole row, so every database
    # error becomes an ArenaRunner::Error that keeps none of Postgres's text.
    class ArenaRunner
      # A failure in the arena transaction. It carries only a fixed message
      # and these fields, never Postgres's message, DETAIL, HINT, or context,
      # and it has no cause.
      #
      # - rule: what went wrong, one of RULES.
      # - sqlstate: the five-character SQLSTATE, or nil when there's none,
      #   such as for a lost connection.
      # - step: the phase, one of :transaction, :begin, :load, :insert,
      #   :query, or :rollback.
      # - index: the position of the failing fixture row, INSERT statement,
      #   or query in its own list, counting from zero, or nil.
      class Error < StandardError
        attr_reader :rule, :sqlstate, :step, :index

        def initialize(rule, step:, sqlstate: nil, index: nil)
          @rule = rule
          @sqlstate = sqlstate
          @step = step
          @index = index
          super(RULES.fetch(rule))
        end
      end

      RULES = {
        already_in_transaction: "the arena connection is already inside a transaction",
        begin_failed: "the arena transaction couldn't start",
        fixture_load_failed: "a fixture row failed to load in the arena transaction",
        insert_failed: "an INSERT statement failed in the arena transaction",
        query_failed: "a query failed in the arena transaction",
        statement_timeout: "a statement in the arena transaction hit statement_timeout",
        transaction_ended: "a statement ended the arena transaction early",
        transaction_closed: "the arena transaction has already been rolled back",
        rollback_failed: "the arena transaction couldn't be rolled back"
      }.freeze

      # A fixture row, the stand-in for what scenario building (task
      # 20260922-45) will produce. A fixture is an Array of these, loaded in
      # order, so parents must come before the rows that reference them.
      # columns are the real column names, unquoted. values are in Postgres
      # text input form, one per column, with nil for NULL. No columns means
      # INSERT ... DEFAULT VALUES.
      FixtureRow = Data.define(:table, :columns, :values) do
        def initialize(table:, columns:, values:)
          problem, = FIXTURE_ROW_CHECKS.find { |_, ok| !ok.call(table, columns, values) }
          raise ArgumentError, problem if problem

          # nil.dup is nil, so a NULL stays nil.
          super(table:, columns: columns.map { |c| c.dup.freeze }.freeze,
                values: values.map { |v| v.dup.freeze }.freeze)
        end
      end

      # Each FixtureRow check in order, with the message for a row that fails
      # it. The messages never name a value.
      FIXTURE_ROW_CHECKS = {
        "a fixture row's table must be a TableName" => ->(table, _, _) { table.is_a?(TableName) },
        "fixture row columns must be non-empty Strings" =>
          ->(_, columns, _) { columns.is_a?(Array) && columns.all? { |c| c.is_a?(String) && !c.empty? } },
        "a fixture row needs one value per column" =>
          ->(_, columns, values) { values.is_a?(Array) && values.size == columns.size },
        "fixture row values must be Strings or nil" =>
          ->(_, _, values) { values.all? { |v| v.nil? || v.is_a?(String) } }
      }.freeze

      # One query's result, for the 9d comparator (task 20260922-47).
      # columns are the output column names. types are their type OIDs, from
      # ftype, so the comparator can find the float columns. rows are Arrays
      # of Postgres text output, with nil for NULL.
      Result = Data.define(:columns, :types, :rows)

      # From libpq. The runner needs the connection idle before it starts,
      # and inside its transaction after every statement.
      PQTRANS_IDLE = 0
      PQTRANS_INTRANS = 2
      # PG_DIAG_SQLSTATE from libpq's postgres_ext.h: the field code for
      # PG::Result#error_field, which is 'C'.ord.
      PG_DIAG_SQLSTATE = 67
      QUERY_CANCELED = "57014"

      DEFAULT_STATEMENT_TIMEOUT_MS = 10_000

      # The handle a with_fixture block gets. It runs queries inside the
      # transaction and stops working once the transaction is rolled back.
      class Transaction
        def initialize(statement)
          @statement = statement
          @queries = 0
          @open = true
        end

        # Runs one SQL statement, with no parameters, and returns its
        # Result. More than one statement is a syntax error, since it goes
        # through exec_params.
        def query(sql)
          raise Error.new(:transaction_closed, step: :query), cause: nil unless @open

          index = @queries
          @queries += 1
          @statement.call(sql, [], step: :query, rule: :query_failed, index:)
        end

        def close = @open = false
      end

      def initialize(connection, statement_timeout_ms: DEFAULT_STATEMENT_TIMEOUT_MS)
        unless statement_timeout_ms.is_a?(Integer) && statement_timeout_ms.positive?
          raise ArgumentError, "statement_timeout_ms must be a positive Integer"
        end

        @connection = connection
        @statement_timeout_ms = statement_timeout_ms
      end

      # Opens the transaction, loads rows (FixtureRows) and then inserts (raw
      # SQL statements, each run on its own with no parameters), yields a
      # Transaction, and rolls back however the block ends. The inserts are
      # for 10b, whose statements have already passed the inbound check.
      #
      # If the connection is already inside a transaction, it raises
      # already_in_transaction and doesn't touch it.
      def with_fixture(rows = [], inserts: [])
        refuse_unless_idle
        database(:begin_failed, :begin) { @connection.exec("BEGIN") }
        tx = Transaction.new(method(:statement))
        begin
          load(rows, inserts)
          yield tx
        ensure
          tx.close
          rollback
        end
      end

      private

      # SET LOCAL, so the timeout ends with the transaction, even one that a
      # stray COMMIT ended.
      def load(rows, inserts)
        database(:begin_failed, :begin) { @connection.exec("SET LOCAL statement_timeout = #{@statement_timeout_ms}") }
        rows.each_with_index do |row, index|
          statement(*insert_sql(row), step: :load, rule: :fixture_load_failed, index:)
        end
        inserts.each_with_index { |sql, index| statement(sql, [], step: :insert, rule: :insert_failed, index:) }
      end

      def refuse_unless_idle
        status = database(:already_in_transaction, :transaction) { @connection.transaction_status }
        raise Error.new(:already_in_transaction, step: :transaction), cause: nil unless status == PQTRANS_IDLE
      end

      # Runs one statement and checks that the transaction is still open,
      # since a COMMIT or ROLLBACK among the statements would end it early.
      def statement(sql, params, step:, rule:, index:)
        result = database(rule, step, index) { @connection.exec_params(sql, params) }
        ended = database(rule, step, index) { @connection.transaction_status } != PQTRANS_INTRANS
        raise Error.new(:transaction_ended, step:, index:), cause: nil if ended

        types = Array.new(result.nfields) { |i| result.ftype(i) }
        Result.new(columns: result.fields, types:, rows: result.values)
      end

      def insert_sql(row)
        table = table_sql(row.table)
        return ["INSERT INTO #{table} DEFAULT VALUES", []] if row.columns.empty?

        columns = row.columns.map { |c| quote(c) }.join(", ")
        placeholders = Array.new(row.columns.size) { |i| "$#{i + 1}" }.join(", ")
        ["INSERT INTO #{table} (#{columns}) VALUES (#{placeholders})", row.values]
      end

      def table_sql(table) = [table.schema, table.name].map { |part| quote(part) }.join(".")

      def quote(name) = @connection.quote_ident(name)

      def rollback
        database(:rollback_failed, :rollback) { @connection.exec("ROLLBACK") }
      end

      # Runs a connection call and turns anything it raises into an Error
      # that keeps only the SQLSTATE. A statement_timeout cancel becomes its
      # own rule, whatever the step.
      def database(rule, step, index = nil)
        yield
      rescue StandardError => e
        sqlstate = sqlstate_of(e)
        rule = :statement_timeout if sqlstate == QUERY_CANCELED
        raise Error.new(rule, step:, sqlstate:, index:), cause: nil
      end

      # PG::Error#result is the failed PG::Result, or nil when there's none.
      def sqlstate_of(error)
        return unless error.respond_to?(:result)

        state = error.result&.error_field(PG_DIAG_SQLSTATE)
        state if state.is_a?(String) && state.match?(/\A[0-9A-Z]{5}\z/)
      end
    end
  end
end
