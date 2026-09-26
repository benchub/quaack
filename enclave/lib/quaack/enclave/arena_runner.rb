# frozen_string_literal: true

require "pg_query"
require_relative "arena_fixture"

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
    # Each insert must be one INSERT and each query one SELECT. pg_query
    # checks that before anything runs.
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
      # From libpq. The runner needs the connection idle before it starts,
      # and inside its transaction after every statement. A connection
      # that's ACTIVE (1, busy with a query) or UNKNOWN (4, gone bad) can't
      # start one.
      PQTRANS_IDLE = 0
      PQTRANS_INTRANS = 2
      PQTRANS_INERROR = 3
      # PG_DIAG_SQLSTATE from libpq's postgres_ext.h: the field code for
      # PG::Result#error_field, which is 'C'.ord.
      PG_DIAG_SQLSTATE = 67
      QUERY_CANCELED = "57014"

      # Refuses a statement that its step may not run, before it runs.
      module StatementCheck
        # The one kind of statement each step may run. Anything else, such as
        # COMMIT, COMMIT AND CHAIN, SAVEPOINT, or SET, could end the
        # transaction or undo its timeout, so it's refused before it runs.
        ALLOWED = { insert: :insert_stmt, query: :select_stmt }.freeze

        module_function

        # Parses sql with pg_query and refuses it unless it's exactly one
        # statement of the kind the step allows. A parse error's message
        # quotes the SQL, so none of it is kept.
        def check(sql, step, index)
          statements = PgQuery.parse(sql).tree.stmts
        rescue PgQuery::ParseError
          raise Error.new(:statement_unparsable, step:, index:), cause: nil
        else
          return if statements.map { |s| s.stmt.node } == [ALLOWED.fetch(step)]

          raise Error.new(:statement_not_allowed, step:, index:), cause: nil
        end
      end

      DEFAULT_STATEMENT_TIMEOUT_MS = 10_000

      # What index_scans: false sets for the transaction. It's a fixed list
      # the runner owns, so no caller's SQL runs a SET.
      NO_INDEX_SCANS = %w[enable_indexscan enable_indexonlyscan enable_bitmapscan]
                       .map { |name| "SET LOCAL #{name} = off" }.freeze

      def initialize(connection, statement_timeout_ms: DEFAULT_STATEMENT_TIMEOUT_MS)
        unless statement_timeout_ms.is_a?(Integer) && statement_timeout_ms.positive?
          raise ArgumentError, "statement_timeout_ms must be a positive Integer"
        end

        @connection = connection
        @statement_timeout_ms = statement_timeout_ms
      end

      # Opens the transaction, loads rows (FixtureRows) and then inserts (raw
      # SQL INSERT statements, each run on its own with no parameters),
      # yields a Transaction, and rolls back however the block ends. The
      # inserts are for 10b, whose statements have already passed the
      # inbound check.
      #
      # index_scans: false turns off index, index-only, and bitmap scans for
      # the transaction (NO_INDEX_SCANS), so each table is read in heap
      # order. Step 9d compares results only, so the plan doesn't matter,
      # and an index would hand back tied rows in its own order however the
      # fixture was loaded (see ResultComparison.compare_in_both_orders).
      #
      # It checks the rows and inserts before it touches the connection. If
      # the connection is already inside a transaction, it raises
      # already_in_transaction and leaves that transaction alone.
      #
      # While it runs, it drops every notice on the connection, since a
      # notice can carry a real value and libpq's default receiver prints it
      # on stderr. It puts the previous receiver back when it's done.
      def with_fixture(rows = [], inserts: [], index_scans: true, &)
        check_fixture(rows, inserts, index_scans)
        refuse_unless_idle
        without_notices do
          database(:begin_failed, :begin) { @connection.exec("BEGIN") }
          in_transaction(Transaction.new(method(:run_query)), rows, inserts, index_scans ? [] : NO_INDEX_SCANS, &)
        end
      end

      private

      def check_fixture(rows, inserts, index_scans)
        raise ArgumentError, "rows must be an Array of FixtureRows" unless rows.is_a?(Array) && rows.all?(FixtureRow)
        raise ArgumentError, "inserts must be an Array of Strings" unless inserts.is_a?(Array) && inserts.all?(String)
        raise ArgumentError, "index_scans must be true or false" unless [true, false].include?(index_scans)

        inserts.each_with_index { |sql, index| StatementCheck.check(sql, :insert, index) }
      end

      def refuse_unless_idle
        status = database(:connection_unusable, :transaction) { @connection.transaction_status }
        return if status == PQTRANS_IDLE

        rule = [PQTRANS_INTRANS, PQTRANS_INERROR].include?(status) ? :already_in_transaction : :connection_unusable
        raise Error.new(rule, step: :transaction), cause: nil
      end

      # set_notice_receiver returns the previous receiver, or nil for
      # libpq's default, and with no block it puts the default back.
      # This stays local rather than using ErrorFilter.drop_notices, since it
      # must put the previous receiver back and drop_notices doesn't return it.
      def without_notices
        previous = database(:connection_unusable, :transaction) { @connection.set_notice_receiver { nil } }
        begin
          yield
        ensure
          @connection.set_notice_receiver(&previous) unless @connection.finished?
        end
      end

      # If the block or a statement raises and then the rollback fails too,
      # as when the connection dies partway through, the first error is the
      # one that goes up, and the rollback failure is dropped. The server
      # rolls back a transaction whose connection is gone, and a connection
      # that's still open but in a transaction is refused by the next
      # with_fixture.
      def in_transaction(handle, rows, inserts, settings)
        failed = false
        load(rows, inserts, settings)
        yield handle
      rescue Exception # rubocop:disable Lint/RescueException -- only noted, then raised again
        failed = true
        raise
      ensure
        finish(handle, quietly: failed)
      end

      # SET LOCAL, so the timeout ends with the transaction however it ends.
      def load(rows, inserts, settings)
        database(:begin_failed, :begin) { @connection.exec("SET LOCAL statement_timeout = #{@statement_timeout_ms}") }
        settings.each { |sql| database(:begin_failed, :begin) { @connection.exec(sql) } }
        rows.each_with_index do |row, index|
          statement(*insert_sql(row), step: :load, rule: :fixture_load_failed, index:)
        end
        inserts.each_with_index { |sql, index| statement(sql, [], step: :insert, rule: :insert_failed, index:) }
      end

      def run_query(sql, index)
        StatementCheck.check(sql, :query, index)
        statement(sql, [], step: :query, rule: :query_failed, index:)
      end

      # Runs one statement and checks that the transaction is still open. The
      # statement check should make that impossible, so this is a backstop.
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
        # A fixture row may set a GENERATED ALWAYS identity key, so its
        # parents' keys match; the override is a no-op on other tables.
        ["INSERT INTO #{table} (#{columns}) OVERRIDING SYSTEM VALUE VALUES (#{placeholders})", row.values]
      end

      def table_sql(table) = [table.schema, table.name].map { |part| quote(part) }.join(".")

      def quote(name) = @connection.quote_ident(name)

      def finish(handle, quietly:)
        handle.close
        database(:rollback_failed, :rollback) { @connection.exec("ROLLBACK") }
      rescue Error
        raise unless quietly
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
      # Any other error has no SQLSTATE.
      def sqlstate_of(error)
        error.result&.error_field(PG_DIAG_SQLSTATE) if error.respond_to?(:result)
      end
    end
  end
end
