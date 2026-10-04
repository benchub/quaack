# frozen_string_literal: true

module Quaack
  module Driver
    module Transport
      # An error line's fields, for Reply, checked for the shapes the
      # enclave's ErrorFilter gives them. The driver can't load the enclave,
      # so the patterns are repeated here. A field that isn't of its shape is
      # dropped, and a rule that isn't is unexpected_output.
      module ErrorFields
        RULE = /\A[a-z][a-z0-9_]{0,62}\z/
        STEP = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
        SQLSTATE = /\A[0-9A-Z]{5}\z/
        FUNCTION = /\A[a-z_][a-z0-9_$]{0,62}\.[a-z_][a-z0-9_$]{0,62}\z/
        # An intake refusal's reason (DESIGN.md's input), one fixed cause.
        REASON_RULES = %w[query_unreadable plan_unreadable].freeze
        REASONS = %w[missing symlink not_regular_file permission_denied].freeze
        # A run_server_other_clients failure's clients (DESIGN.md's run-server), as
        # the enclave's ErrorFilter shapes them: 1 to MAX_CLIENTS entries, each
        # exactly a positive Integer pid and a UTC backend_start.
        CLIENTS_RULE = "run_server_other_clients"
        CLIENT_KEYS = %w[pid backend_start].freeze
        BACKEND_START = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
        MAX_CLIENTS = 20
        # A rewrite-test refusal's column (DESIGN.md's rewrite-test), as the enclave's
        # ErrorFilter shapes it: exactly a qualified table, a column name,
        # and a type as format_type prints it.
        COLUMN_RULES = %w[unsupported_type domain_check].freeze
        COLUMN_KEYS = %w[table column type].freeze
        IDENTIFIER = /\A[a-z_][a-z0-9_$]{0,62}\z/
        TYPE = /\A[a-z_][a-z0-9_ $.,()\[\]]{0,127}\z/
        # An fk_cycle refusal's tables (DESIGN.md's rewrite-test), as the enclave's
        # ErrorFilter shapes them: 3 to 64 plain schema.name Strings, the
        # last the first again.
        CYCLE_RULE = "fk_cycle"
        CYCLE_SIZES = (3..64)

        module_function

        # The EnclaveError keywords for the error line error, a Hash.
        def call(error)
          rule = shaped(error["rule"], RULE) || "unexpected_output"
          { rule:, step: shaped(error["step"], STEP), sqlstate: shaped(error["sqlstate"], SQLSTATE),
            reason: reason(rule, error["reason"]), function: shaped(error["function"], FUNCTION),
            **named(rule, error) }
        end

        # The fields only one rule's error line has.
        def named(rule, error)
          { column: (column(error["column"]) if COLUMN_RULES.include?(rule)),
            clients: (clients(error["clients"]) if rule == CLIENTS_RULE),
            cycle: (cycle(error["cycle"]) if rule == CYCLE_RULE) }
        end

        def reason(rule, reason) = (reason if REASON_RULES.include?(rule) && REASONS.include?(reason))

        def cycle(cycle)
          return unless cycle.instance_of?(Array) && CYCLE_SIZES.cover?(cycle.size) && cycle.first == cycle.last

          cycle if cycle.all? { shaped(it, FUNCTION) }
        end

        def column(column)
          return unless column.instance_of?(Hash) && column.keys == COLUMN_KEYS

          column if shaped(column["table"], FUNCTION) && shaped(column["column"], IDENTIFIER) &&
                    shaped(column["type"], TYPE)
        end

        def clients(clients)
          return unless clients.instance_of?(Array) && (1..MAX_CLIENTS).cover?(clients.size)

          clients if clients.all? { client?(it) }
        end

        def client?(client)
          client.instance_of?(Hash) && client.keys == CLIENT_KEYS &&
            client["pid"].instance_of?(Integer) && client["pid"].positive? &&
            shaped(client["backend_start"], BACKEND_START)
        end

        def shaped(value, pattern) = (value if value.instance_of?(String) && value.match?(pattern))
      end
    end
  end
end
