# frozen_string_literal: true

require "quaack/protocol/database_name"
require "quaack/protocol/port"
require_relative "intake/error"
require_relative "intake/operator_file"
require_relative "intake/clock_anchor"
require_relative "intake/query"
require_relative "intake/plan"

module Quaack
  module Enclave
    # The checks on input's operator inputs (DESIGN.md's input), which
    # `quaacks intake` runs (see Steps::Intake). Each returns what the run
    # stores, or raises Intake::Error with the rule the input broke:
    #
    # - server: bad_server.
    # - production_port, from --port: bad_port, unless it's a whole number
    #   from 1 to 65535 (Protocol::Port), as run-server's --port.
    # - production_database, from --database: bad_database, unless it's a
    #   plain name (Protocol::DatabaseName), as run-server's databases.
    # - clock_anchor, from --captured-at: bad_captured_at (see ClockAnchor).
    # - query, from its file: query_unreadable, query_too_large,
    #   query_not_text, query_unparsable, query_not_one_statement,
    #   unsupported_construct, or query_has_parameters (see Query).
    # - plan, from its file: plan_unreadable, plan_too_large,
    #   plan_not_json, plan_bad_shape, plan_not_analyzed, or
    #   plan_no_buffers, or plan_statement_mismatch (see Plan).
    #
    # The files hold production literals, and a path or a server name can
    # hold anything, so an Error names only its rule, and has no cause.
    module Intake
      # A hostname or a service name: letters, digits, dots, hyphens, and
      # underscores, starting with a letter or digit, at most 253
      # characters, a DNS name's limit.
      SERVER = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z/

      module_function

      def server(name)
        raise Error, "bad_server" unless name.is_a?(String) && name.ascii_only? && SERVER.match?(name)

        name
      end

      def port(text)
        raise Error, "bad_port" unless Protocol::Port.valid?(text)

        Integer(text, 10)
      end

      def production_database(text)
        raise Error, "bad_database" unless Protocol::DatabaseName.valid?(text)

        text
      end

      def clock_anchor(captured_at) = ClockAnchor.from(captured_at)

      def query(path) = Query.check(OperatorFile.read(path, "query"))

      def plan(path) = Plan.check(OperatorFile.read(path, "plan"))
    end
  end
end
