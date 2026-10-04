# frozen_string_literal: true

require_relative "table_name"

module Quaack
  module Enclave
    # The plain shapes ArenaRunner takes and gives back: its errors, the
    # fixture rows it loads, the handle its block gets, and the query
    # results it returns. The runner
    # itself is in arena_runner.rb.
    class ArenaRunner
      # A failure in the arena transaction. It carries only a fixed message
      # and these fields, never Postgres's message, DETAIL, HINT, or context,
      # and it has no cause.
      #
      # - rule: what went wrong, one of RULES.
      # - sqlstate: the five-character SQLSTATE, or nil when there's none,
      #   such as for a lost connection.
      # - step: the phase, one of :transaction (checking and preparing the
      #   connection), :begin, :load, :insert, :query, or :rollback.
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
        connection_unusable: "the arena connection can't start a transaction",
        statement_not_allowed: "a statement isn't one the arena transaction allows",
        statement_unparsable: "a statement for the arena transaction couldn't be parsed",
        begin_failed: "the arena transaction couldn't start",
        fixture_load_failed: "a fixture row failed to load in the arena transaction",
        # Raised by ResultComparison.compare_in_both_orders, not the runner
        # itself, for a failure in its reverse load. index is the row's
        # position in the fixture as given, not in the reversed list.
        reverse_load_failed: "a fixture row failed to load when the fixture was loaded in reverse",
        insert_failed: "an INSERT statement failed in the arena transaction",
        query_failed: "a query failed in the arena transaction",
        statement_timeout: "a statement in the arena transaction hit statement_timeout",
        # A cancel that came before the timeout could have fired, such as
        # an operator's pg_cancel_backend.
        statement_canceled: "a statement in the arena transaction was canceled",
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

      # An INSERT whose rows leave some columns NULL until every insert has
      # loaded, for a foreign-key cycle (Counterexamples). sql is one
      # INSERT. updates has one Hash per row it inserts, in VALUES order:
      # each column to set afterward, with its value in Postgres text input
      # form, or no columns. The runner keys each UPDATE to the exact row
      # by the tableoid and ctid the INSERT returns.
      DeferredInsert = Data.define(:sql, :updates) do
        def self.updates?(updates)
          updates.is_a?(Array) && updates.all? { |u| u.is_a?(Hash) && u.all? { |k, v| [k, v].all?(String) } }
        end

        def self.frozen(updates) = updates.map { |u| u.to_h { |k, v| [k.dup.freeze, v.dup.freeze] }.freeze }.freeze

        def initialize(sql:, updates:)
          raise ArgumentError, "a deferred insert's sql must be a String" unless sql.is_a?(String)
          raise ArgumentError, "a deferred insert's updates must be String Hashes" unless self.class.updates?(updates)

          super(sql: sql.dup.freeze, updates: self.class.frozen(updates))
        end

        def inspect = "#<data #{self.class} sql=<redacted> updates=<redacted>>"

        alias_method :to_s, :inspect
      end

      # One query's result, for the 9d comparator (task 20260922-47).
      # columns are the output column names. types are their type OIDs, from
      # ftype, so the comparator can find the float columns. rows are Arrays
      # of Postgres text output, with nil for NULL.
      Result = Data.define(:columns, :types, :rows)

      # The handle a with_fixture block gets. It runs queries inside the
      # transaction and stops working once the transaction is rolled back.
      class Transaction
        def initialize(run)
          @run = run
          @queries = 0
          @open = true
        end

        # Runs one SELECT, with no parameters, and returns its Result.
        def query(sql)
          raise Error.new(:transaction_closed, step: :query), cause: nil unless @open
          raise ArgumentError, "a query must be a String" unless sql.is_a?(String)

          index = @queries
          @queries += 1
          @run.call(sql, index)
        end

        def close = @open = false
      end
    end
  end
end
