# frozen_string_literal: true

require_relative "intake/clock_anchor"
require_relative "intake/error"

module Quaack
  module Enclave
    # DESIGN.md's racetrack-setup: set up the restored racetrack database.
    #
    #   Racetrack.setup(store:, connection:)  # nil, or raises an Error
    #
    # connection is a superuser's connection to the racetrack database,
    # which the caller passes in, as for RunServerCheck. setup creates the hypopg extension, the quaack schema, and
    # quaack.clock_anchor(), which returns the run's clock_anchor entry (see
    # Intake::ClockAnchor). Running it again is fine: the extension and
    # schema are kept, and the function is replaced.
    #
    # The function is what clock-anchor's anchored queries call (ClockFunctions::ANCHOR):
    # no arguments, returning pg_catalog.timestamptz, STABLE. It's also
    # PARALLEL SAFE with COST 1, as now() is, so the anchored query plans
    # like the original. It's PL/pgSQL rather than SQL so the planner can't
    # inline it: an inlined body is a constant, which now() isn't, so
    # partitions would be pruned at plan time rather than at executor
    # startup, and the plan would differ from production's.
    #
    # The anchor goes into the body as a literal, so it's parsed as a time
    # first, and written in a fixed format. A stored anchor that doesn't
    # parse raises racetrack_bad_clock_anchor.
    #
    # hypopg goes in the quaack schema, unless the racetrack has it already,
    # wherever that is. The session's search_path is the plan's
    # (RunServer.connect), which can name only schemas the racetrack doesn't
    # have, and CREATE EXTENSION would then have nowhere to put it. quaack is
    # the one schema setup itself makes sure of, and it's on no
    # application's path. HypoPG is called in its own schema, wherever it is
    # (SingleCandidateTest::HypoPG).
    #
    # A quaack schema that's already there must hold nothing but
    # quaack.clock_anchor() returning timestamptz, and hypopg and its
    # objects, or setup raises
    # racetrack_quaack_schema_foreign and changes nothing. What's in the
    # schema is read from pg_depend: every object in a schema, of any kind,
    # has a dependency on it there, which is how DROP SCHEMA CASCADE finds
    # them.
    #
    # An Error's message is its rule and nothing else. Nothing goes out.
    module Racetrack
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      # How many objects in the quaack schema aren't ours. It's zero when
      # there's no such schema.
      FOREIGN_SQL = <<~SQL
        SELECT pg_catalog.count(*) FROM pg_catalog.pg_depend d
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) d.refobjid
        WHERE d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_namespace'::pg_catalog.regclass
          AND n.nspname OPERATOR(pg_catalog.=) 'quaack'
          AND NOT (d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_proc'::pg_catalog.regclass
                   AND COALESCE(d.objid OPERATOR(pg_catalog.=) (
                     SELECT oid FROM pg_catalog.pg_proc
                     WHERE oid OPERATOR(pg_catalog.=) pg_catalog.to_regprocedure('quaack.clock_anchor()')
                       AND prorettype OPERATOR(pg_catalog.=) 'pg_catalog.timestamptz'::pg_catalog.regtype), false))
          AND NOT EXISTS (
            SELECT FROM pg_catalog.pg_extension e
            WHERE e.extname OPERATOR(pg_catalog.=) 'hypopg'
              AND ((d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass
                    AND d.objid OPERATOR(pg_catalog.=) e.oid)
                   OR EXISTS (SELECT FROM pg_catalog.pg_depend m
                              WHERE m.classid OPERATOR(pg_catalog.=) d.classid
                                AND m.objid OPERATOR(pg_catalog.=) d.objid
                                AND m.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_extension'::pg_catalog.regclass
                                AND m.refobjid OPERATOR(pg_catalog.=) e.oid
                                AND m.deptype OPERATOR(pg_catalog.=) 'e')))
      SQL

      module_function

      def setup(store:, connection:)
        literal = anchor_literal(store.read("clock_anchor"))
        raise Error, "racetrack_quaack_schema_foreign" unless connection.exec(FOREIGN_SQL).getvalue(0, 0) == "0"

        create_clock_anchor(connection, literal)
        connection.exec("CREATE EXTENSION IF NOT EXISTS hypopg WITH SCHEMA quaack")
        nil
      end

      def create_clock_anchor(connection, literal)
        connection.exec("CREATE SCHEMA IF NOT EXISTS quaack")
        connection.exec(<<~SQL)
          CREATE OR REPLACE FUNCTION quaack.clock_anchor() RETURNS pg_catalog.timestamptz
          LANGUAGE plpgsql STABLE PARALLEL SAFE COST 1
          AS $$BEGIN RETURN #{literal}; END$$
        SQL
      end

      # The stored anchor as a timestamptz literal, such as
      # '2026-09-23 22:15:00.000000+00'::pg_catalog.timestamptz.
      def anchor_literal(stored)
        time = Intake::ClockAnchor.parse(stored).utc
        "'#{time.strftime("%Y-%m-%d %H:%M:%S.%6N")}+00'::pg_catalog.timestamptz"
      rescue Intake::Error
        raise Error, "racetrack_bad_clock_anchor", cause: nil
      end
    end
  end
end
