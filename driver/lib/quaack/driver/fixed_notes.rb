# frozen_string_literal: true

require "quaack/protocol/error_rules"

module Quaack
  module Driver
    # The driver's own fixed notes, by the enclave rule they follow
    # (EnclaveError#rule_with_note). The enclave's error line holds only the
    # rule and a few shape-class fields, so the driver says what it means.
    # Every rule in Protocol::ErrorRules is in exactly one of BY_RULE,
    # INTERNAL, and CODED, or is a missing_<entry> rule (MISSING_ENTRY), and
    # a cross-gem spec checks it.
    #
    # A note never holds a value: it's fixed text. A {next} in it becomes the
    # caller's next step, such as "resume with `quaack setup --run <ID>`", so
    # the note ends with what to do next. A note without one is for a rule
    # where going on the same way can't help, such as a query QUAACK can't
    # tune, or where the caller says what to do, as teardown does.
    module FixedNotes # rubocop:disable Metrics/ModuleLength
      # What a rule whose note ends with what to do next ends with.
      GO_ON = "To go on, {next}."

      BY_RULE = {
        # The run's store and the jump server's setup.
        "run_from_older_version" => "An older version of QUAACK started this run, and this version can't " \
                                    "resume it. Start a new run with quaack start.",
        "bad_run" => "The jump server has no usable directory for this run under ~/.quaack/runs: it's missing, " \
                     "or it isn't a directory QUAACK made, such as a symlink, so QUAACK left it alone. Check " \
                     "the run ID.",
        "bad_store_base" => "QUAACK can't use its store, ~/.quaack/runs on the jump server: it's a symlink or " \
                            "sits in one, isn't a directory, or the ssh user can't create or search it. Fix it " \
                            "on the jump server. #{GO_ON}",
        "store_error" => "QUAACK couldn't read or write a file in the run's store, under ~/.quaack/runs on the " \
                         "jump server. Check the disk space there and that the ssh user owns the files. #{GO_ON}",
        "bad_config" => "QUAACK can't use ~/.quaack/config.json on the jump server: it's a symlink, not a " \
                        "regular file, unreadable, larger than QUAACK reads, not one JSON object, or a value " \
                        "in it is the wrong kind. Fix it. #{GO_ON}",

        # intake: quaack start's flags and files.
        "bad_server" => "--server must be a host name or a service name: letters, digits, dots, hyphens, and " \
                        "underscores, starting with a letter or digit, at most 253 characters. #{GO_ON}",
        "bad_port" => "--port must be a whole number from 1 to 65535, with no leading zero. #{GO_ON}",
        "bad_database" => "--database must be letters, digits, underscores, and hyphens, starting with a " \
                          "letter, digit, or underscore, at most 63 characters. #{GO_ON}",
        # intake refused quaack start's --captured-at.
        "bad_captured_at" => "--captured-at must be an ISO-8601 time with a zone, such as 2026-10-01T09:30:00Z " \
                             "or 2026-10-01T09:30:00-04:00, no earlier than 1970 and no more than one day ahead " \
                             "of the jump server's clock",
        "query_unreadable" => "QUAACK couldn't read the query file on the jump server. Check the --query path " \
                              "you gave quaack start, then {next}.",
        "plan_unreadable" => "QUAACK couldn't read the plan file on the jump server. Check the --plan path " \
                             "you gave quaack start, then {next}.",
        "query_too_large" => "The query file is larger than QUAACK reads. Check that --query names the " \
                             "query's file. #{GO_ON}",
        "plan_too_large" => "The plan file is larger than QUAACK reads. Check that --plan names the plan's " \
                            "file. #{GO_ON}",
        "query_not_text" => "The query file isn't UTF-8 text, or it holds a NUL byte. Save it as UTF-8 text. " \
                            "#{GO_ON}",
        "query_not_one_statement" => "The query file must hold exactly one SQL statement. #{GO_ON}",
        "query_has_parameters" => "The query uses $1-style parameters. QUAACK needs the query with the literal " \
                                  "values its plan ran with, so put them in. #{GO_ON}",
        "plan_not_json" => "The plan file isn't one JSON document. Run the query with EXPLAIN (ANALYZE, " \
                           "BUFFERS, SETTINGS, FORMAT JSON) and save all it prints. #{GO_ON}",
        "plan_bad_shape" => "The plan file isn't EXPLAIN's JSON for one statement. Run the query with EXPLAIN " \
                            "(ANALYZE, BUFFERS, SETTINGS, FORMAT JSON) and save all it prints. #{GO_ON}",
        "plan_not_analyzed" => "The plan has no actual row counts, so EXPLAIN ran without ANALYZE. Run the " \
                               "query with EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON). #{GO_ON}",
        "plan_no_buffers" => "The plan has no buffer counts, so EXPLAIN ran without BUFFERS. Run the query " \
                             "with EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON). #{GO_ON}",
        "plan_statement_mismatch" => "The plan file doesn't match the query file: the plan is of a statement " \
                                     "that changes data, such as an UPDATE, and the query is a SELECT. Check " \
                                     "that --plan names the plan of the query --query names. #{GO_ON}",
        # qualify refuses it, after intake started the run, so the run can't go on.
        "plan_table_mismatch" => "The plan file doesn't match the query file: the plan scans a table the query " \
                                 "doesn't read. Check that --plan names the plan of the query --query names, " \
                                 "then start a new run with `quaack start`.",

        # What the query uses that QUAACK v1 can't tune. Going on can't help,
        # since the run's query stays the same.
        "unsupported_construct" => "The query uses SQL that QUAACK v1 doesn't support, so it can't tune " \
                                   "this query.",
        "user_function_in_from" => "The query calls a function in FROM that isn't one of pg_catalog's, such " \
                                   "as a user-defined one. QUAACK v1 can't tune this query.",
        "view_relation" => "The query reads a view, or a table with an inheritance child that's one. QUAACK v1 " \
                           "tunes queries on plain tables only.",
        "matview_relation" => "The query reads a materialized view, or a table with an inheritance child " \
                              "that's one. QUAACK v1 tunes queries on plain tables only.",
        "partitioned_relation" => "The query reads a partitioned table, or a table with an inheritance child " \
                                  "that's one. QUAACK v1 tunes queries on plain tables only.",
        "foreign_relation" => "The query reads a foreign table, or a table with an inheritance child that's " \
                              "one. QUAACK v1 tunes queries on plain tables only.",
        "sequence_relation" => "The query reads a sequence as a table. QUAACK v1 tunes queries on plain " \
                               "tables only.",
        "composite_type_relation" => "The query reads a composite type as a table. QUAACK v1 tunes queries on " \
                                     "plain tables only.",
        "toast_relation" => "The query reads a TOAST table. QUAACK v1 tunes queries on plain tables only.",
        "index_relation" => "The query reads an index as a table. QUAACK v1 tunes queries on plain tables only.",
        "not_a_table" => "The query reads a relation that isn't a plain table. QUAACK v1 tunes queries on " \
                         "plain tables only.",
        "inheritance_parent" => "The query reads a table with inheritance children. QUAACK v1 can't read its " \
                                "statistics, so it can't tune this query.",
        "unknown_relation" => "The query names a table that no schema on the plan's search_path has, in the " \
                              "production database. Check the query and the plan, then start a new run with " \
                              "`quaack start`.",
        "unresolved_relation" => "The query names a table without its schema, and no schema on the plan's " \
                                 "search_path has it. Check the query and the plan, then start a new run with " \
                                 "`quaack start`.",
        "bad_search_path" => "The plan's search_path setting isn't a list of schema names QUAACK can read. " \
                             "QUAACK v1 can't tune this query.",
        "ambiguous_user_schema" => "The plan's search_path has \"$user\", and a schema named for a role could " \
                                   "change what a name in the query means. Name those tables, types, and " \
                                   "functions with their schema in the query, then start a new run with " \
                                   "`quaack start`.",
        "unsupported_reg_literal" => "The query has a regproc, regprocedure, regoper, or regoperator constant, " \
                                     "or a regclass or regtype constant that isn't one name. QUAACK v1 can't " \
                                     "tune this query.",
        "name_lookup_function" => "A rewrite calls a function that looks up a name given as text, such as " \
                                  "to_regclass, and the query doesn't make the same call. QUAACK dropped it.",
        "unknown_name" => "A rewrite uses a function, type, collation, or operator that's neither the " \
                          "query's nor a built-in one. QUAACK dropped it.",
        "untyped_literal" => "A rewrite has a string constant whose type Postgres can't work out without its " \
                             "value. QUAACK dropped it.",
        "clock_literal" => "The query has 'now', 'today', 'tomorrow', or 'yesterday' in a string Postgres " \
                           "could read as a time. QUAACK v1 can't tune this query.",
        "clock_anchor_in_query" => "The query already calls quaack.clock_anchor(), the function QUAACK puts in " \
                                   "for the clock. QUAACK can't tune this query.",
        "clock_function_search_path" => "The plan's search_path puts a schema before pg_catalog, so a clock " \
                                        "function such as now() might not be pg_catalog's. QUAACK v1 can't " \
                                        "tune this query.",
        "database_qualified_function" => "The query names a clock function with its database, such as " \
                                         "mydb.pg_catalog.now(). QUAACK v1 can't tune this query.",
        "interval_field_qualifier" => "The query has an interval constant with fields after it, such as " \
                                      "INTERVAL '1' DAY. QUAACK v1 can't tune this query.",
        "volatile_function" => "The query calls a volatile function, such as random(). QUAACK v1 can't tune " \
                               "a query that does.",
        "sql_ascii_database" => "The production database uses the SQL_ASCII encoding, whose names have no " \
                                "known encoding. QUAACK v1 can't tune queries on it.",
        "unsupported_production_version" => "The production server runs a Postgres major version older than " \
                                            "QUAACK supports.",

        # rewrite-test's refusals, when counterexamples meets one. The error
        # line's column or cycle, when it has one, comes first.
        "unsupported_type" => "A column of the query's tables has a type QUAACK can't build test rows for, so " \
                              "it can't test rewrites of this query.",
        "domain_check" => "A column's domain has a CHECK that rejects every value QUAACK tries, so it can't " \
                          "test rewrites of this query.",
        "fk_cycle" => "The query's tables have a foreign key cycle with no nullable key to break it, so QUAACK " \
                      "can't load test rows for them or test rewrites of this query.",
        "complex_check" => "A table the query reads has a CHECK that compares columns, uses OR, or calls a " \
                           "function. QUAACK v1 can't build test rows for it, so it can't test rewrites of " \
                           "this query.",
        "unsatisfiable_check" => "A table the query reads has a CHECK that rejects every value QUAACK tries " \
                                 "for a column, so it can't test rewrites of this query.",
        "exclusion_constraint" => "A table the query reads has an exclusion constraint with no column compared " \
                                  "with =. QUAACK v1 can't keep its test rows apart, so it can't test rewrites " \
                                  "of this query.",
        "expression_unique_index" => "A table the query reads has a unique index on an expression that calls " \
                                     "a function outside pg_catalog. QUAACK won't run user code, so it can't " \
                                     "test rewrites of this query.",

        # Production, from the jump server.
        "production_read_failed" => "QUAACK connected to the production server, but reading its catalog failed. " \
                                    "Check that your role there can read the system catalogs and pg_stats. " \
                                    "#{GO_ON}",
        "column_statistics_hidden" => "Your role on the production server can't read the statistics of some " \
                                      "of the query's columns, since pg_stats shows a column's statistics " \
                                      "only to a role that can SELECT it. Grant your role there SELECT on " \
                                      "the columns of the query's tables. #{GO_ON}",
        "row_security_statistics_hidden" => "A table the query reads has row-level security, and it hides every " \
                                            "column's statistics from your role on the production server. Use a " \
                                            "role there that bypasses row-level security or owns the table. " \
                                            "#{GO_ON}",
        "memory_command_failed" => "memory_command in ~/.quaack/config.json on the jump server exited with a " \
                                   "failure. Fix it, or remove it and QUAACK records the memory as unknown. " \
                                   "#{GO_ON}",
        "memory_command_timed_out" => "memory_command in ~/.quaack/config.json on the jump server ran past its " \
                                      "time limit. Fix it, or remove it and QUAACK records the memory as " \
                                      "unknown. #{GO_ON}",
        "memory_command_bad_output" => "memory_command in ~/.quaack/config.json on the jump server didn't print " \
                                       "the memory as a whole number of bytes, with or without a unit such as " \
                                       "GB or GiB. Fix it, or remove it and QUAACK records the memory as " \
                                       "unknown. #{GO_ON}",
        "pg_dump_missing" => "QUAACK couldn't run pg_dump on the jump server, or it didn't print its version. " \
                             "Install pg_dump there, on the ssh user's PATH. #{GO_ON}",
        "pg_dump_too_old" => "pg_dump on the jump server is an older major version than the production " \
                             "server. Install a pg_dump at least as new as production. #{GO_ON}",
        # The error line's tables come first.
        "dump_object_unreadable" => "Your role on the production server can't read these tables, which the " \
                                    "schema dump needs, and pg_dump locks every table it dumps. Grant your " \
                                    "role there SELECT on the tables named, or use a role that can read " \
                                    "them. #{GO_ON}",
        "pg_dump_failed" => "pg_dump failed against the production server. It also fails when it waits more " \
                            "than 30 seconds for a table's lock. Check that your role can dump the schema. " \
                            "#{GO_ON}",

        # run-server: the run server's flags, command, and checks.
        # run-server got neither all four flags nor a run_server_command.
        "run_server_unspecified" => "Name the run server with --host, --port, --racetrack-db, and --arena-db, " \
                                    "or set run_server_command in ~/.quaack/config.json on the jump server",
        "bad_run_server_host" => "The run server's host must be a host name or an IPv4 address. A Unix socket " \
                                 "path or an IPv6 address isn't supported yet. Fix --host or " \
                                 "run_server_command's output. #{GO_ON}",
        "bad_run_server_port" => "The run server's port must be a whole number from 1 to 65535, with no " \
                                 "leading zero. Fix --port or run_server_command's output. #{GO_ON}",
        "bad_run_server_database" => "The racetrack and arena database names must be plain: a letter, digit, " \
                                     "or underscore, then those or hyphens, at most 63 characters. Fix " \
                                     "--racetrack-db and --arena-db, or run_server_command's output. #{GO_ON}",
        "run_server_same_database" => "The racetrack and arena must be different databases, since QUAACK " \
                                      "rebuilds the arena from scratch. #{GO_ON}",
        "run_server_command_failed" => "run_server_command in ~/.quaack/config.json on the jump server exited " \
                                       "with a failure. Fix it, or name the run server with --host, --port, " \
                                       "--racetrack-db, and --arena-db. #{GO_ON}",
        "run_server_command_timed_out" => "run_server_command in ~/.quaack/config.json on the jump server ran " \
                                          "past its time limit. Fix it, or name the run server with --host, " \
                                          "--port, --racetrack-db, and --arena-db. #{GO_ON}",
        "run_server_command_bad_output" => "run_server_command in ~/.quaack/config.json on the jump server " \
                                           "didn't print one JSON object with exactly host, port, " \
                                           "racetrack_db, and arena_db. Fix it. #{GO_ON}",
        "run_server_not_superuser" => "The role QUAACK connects to the run server as isn't a superuser. " \
                                      "Connect as one, through your libpq setup on the jump server. #{GO_ON}",
        "run_server_major_version" => "The run server's Postgres major version isn't production's. Use a run " \
                                      "server on production's major version. #{GO_ON}",
        "run_server_extension_missing" => "An extension the production database has isn't installed in the " \
                                          "racetrack database. Install it there. #{GO_ON}",
        "run_server_extension_version" => "An extension in the racetrack database is at another version than " \
                                          "production's. Install production's version. #{GO_ON}",
        "run_server_hypopg_missing" => "HypoPG isn't installed or available on the run server. Install its " \
                                       "package there. #{GO_ON}",
        "run_server_locale_mismatch" => "The racetrack database's collation, ctype, locale provider, locale, " \
                                        "collation version, or default_text_search_config isn't production's. " \
                                        "Create it with production's. #{GO_ON}",
        "run_server_guc_mismatch" => "A planner setting on the run server isn't production's: one EXPLAIN's " \
                                     "SETTINGS lists, a query tuning setting, TimeZone, DateStyle, or " \
                                     "IntervalStyle. Set the run server's to match. #{GO_ON}",
        "run_server_tablespace_mismatch" => "A tablespace the production database's tables or indexes use " \
                                            "is missing on the run server, or its options, such as " \
                                            "random_page_cost and seq_page_cost, aren't production's. Create " \
                                            "it, or set its options to match. #{GO_ON}",
        "run_server_preload_mismatch" => "The run server's shared_preload_libraries doesn't load the same " \
                                         "plan-changing libraries as production's: pg_hint_plan, " \
                                         "pg_dbms_stats, plantuner, and aqo. Set it to match, and restart " \
                                         "the run server. #{GO_ON}",
        "run_server_other_clients" => "Another client is connected to the run server, and QUAACK must be " \
                                      "alone on it. Stop the clients, then {next}.",
        "run_server_cron_elsewhere" => "pg_cron on the run server runs its jobs from another database, so " \
                                       "QUAACK can't check them. Set cron.database_name to the racetrack " \
                                       "database. #{GO_ON}",
        "run_server_cron_active" => "pg_cron has an active job in the racetrack database. Unschedule or " \
                                    "deactivate it. #{GO_ON}",
        "run_server_autovacuum_on" => "Autovacuum is on on the run server. Turn it off there, with " \
                                      "autovacuum = off. #{GO_ON}",

        # racetrack-setup and arena-setup, on the run server.
        "racetrack_quaack_schema_foreign" => "The racetrack database's quaack schema holds objects QUAACK " \
                                             "didn't make, so QUAACK changed nothing. Remove them, or use " \
                                             "another racetrack database. #{GO_ON}",
        "arena_database_foreign" => "The run server already has a database with the arena's name that QUAACK " \
                                    "didn't make, so QUAACK left it alone. Name another --arena-db, or drop " \
                                    "that database yourself. #{GO_ON}",
        "arena_dump_load_failed" => "Production's schema didn't load into the arena database on the run " \
                                    "server. The run server's log names the statement that failed. #{GO_ON}",
        # index-search's plan gate, worded from PlanGate's details.
        "plan_gate_mismatch_likely_stale_statistics" => "The racetrack's plan for the slow literals doesn't " \
                                                        "match production's plan. The likely cause is that the " \
                                                        "racetrack's statistics don't match production's, such " \
                                                        "as a backup older than the statistics QUAACK read " \
                                                        "from production. The run server is already torn down, " \
                                                        "so make sure the backup the next run server restores " \
                                                        "from is fresh and analyzed. #{GO_ON}",
        "plan_gate_not_comparable" => "A plan has a condition QUAACK can't compare, so it can't tell whether " \
                                      "the racetrack plans the query as production did. QUAACK v1 can't tune " \
                                      "this query.",
        # index-build's guards against an orphaned build (BuildConnection).
        "index_build_orphan_running" => "A CREATE INDEX from an earlier, timed-out index-build call is still " \
                                        "running on the run server, and it didn't stop when QUAACK canceled " \
                                        "it. Wait for it to finish or stop it yourself. #{GO_ON}",
        "index_build_orphan_cancel_denied" => "A CREATE INDEX from an earlier, timed-out index-build call is " \
                                              "still running on the run server, and QUAACK's role may not " \
                                              "cancel it. Cancel that backend yourself, with pg_cancel_backend " \
                                              "as a role that may. #{GO_ON}",
        "statement_canceled" => "Something other than QUAACK's own time limit canceled one of QUAACK's queries " \
                                "on the run server: another session, or a statement_timeout set on the server, " \
                                "database, or role. Make sure nothing else uses the run server and that " \
                                "statement_timeout is off there. #{GO_ON}",

        # teardown. The driver says how to tear the run down after these.
        "teardown_failed" => "QUAACK couldn't finish deleting the run's store on the jump server, and part of " \
                             "it is still there.",
        "destroy_command_not_run" => "QUAACK couldn't read the run's production server name, so " \
                                     "destroy_command didn't run, and the run server may still be up. QUAACK " \
                                     "kept the run's store.",
        "destroy_command_failed" => "destroy_command in ~/.quaack/config.json on the jump server exited with a " \
                                    "failure, so the run server may still be up. QUAACK kept the run's store.",
        "destroy_command_timed_out" => "destroy_command in ~/.quaack/config.json on the jump server ran past " \
                                       "its time limit, so the run server may still be up. QUAACK kept the " \
                                       "run's store.",
        "destroy_command_bad_output" => "destroy_command in ~/.quaack/config.json on the jump server printed " \
                                        "more than QUAACK reads, so the run server may still be up. QUAACK " \
                                        "kept the run's store."
      }.freeze

      # Store::MissingEntry's rules, missing_<entry> (Protocol::ErrorRules's
      # MISSING_ENTRY): the run's store lacks an entry a step needs.
      MISSING_ENTRY = "The run's store on the jump server is missing an entry this step needs, so an earlier " \
                      "step didn't finish or its file was removed. #{GO_ON} If it fails the same way, start " \
                      "a new run with `quaack start`.".freeze

      # The rules whose note EnclaveError builds itself, from the driver's
      # own record of the run or pg_query's version.
      CODED = %w[query_unparsable production_connection_failed run_server_connection_failed].freeze

      # The shared line for every rule in INTERNAL.
      INTERNAL_NOTE = "QUAACK hit an internal check it can't recover from. This is a QUAACK bug: report " \
                      "the rule name and the step"

      # The rules an operator can't act on: checks of QUAACK's own work,
      # of what the driver sends, of the order the driver runs steps in,
      # and of what an LLM or rewrite rule gave, which the steps that take
      # it record rather than fail on.
      INTERNAL = %w[
        internal_error usage bad_input input_too_large volatility_not_passed
        run_server_no_inventory racetrack_setup_no_run_server arena_setup_no_run_server racetrack_bad_clock_anchor
        index_search_no_racetrack_setup index_search_unknown_search index_feedback_no_index_search
        index_feedback_unknown_search index_payload_no_index_search index_payload_unknown_search
        index_rank_no_index_search index_rank_unknown_search index_test_bad_ddls index_test_no_index_search
        index_test_unknown_round index_test_unknown_search rewrite_check_bad_rewrites rewrite_prune_no_ranking
        rewrite_prune_unknown_search rewrite_test_no_arena_setup rewrite_test_unknown_search
        counterexample_payload_unknown_search counterexample_payload_untested counterexample_round_bad_inserts
        counterexample_round_bad_round counterexample_round_decided counterexample_round_no_arena_setup
        counterexample_round_out_of_order counterexample_round_unknown_search counterexample_round_untested
        index_build_bad_index index_build_hidden_index_used
        index_build_unique index_build_unqualified index_build_wrong_set_hidden
        invalid_index_candidate indexes_hidden in_transaction session_closed hypopg_failed explain_failed
        cleanup_failed prepare_failed execute_failed bad_type not_one_select unknown_placeholder bad_placeholder
        bad_placeholder_map bad_literal bad_literal_sets bad_statistics statistics_bad_shape bad_value
        plan_gate_bad_plan
        not_a_query_parse using_column_unreplaceable natural_join_unreplaceable deparse_mismatch parse_error
        restore_mismatch unparsable
        bad_conninfo_key secret_in_conninfo
        already_in_transaction connection_unusable begin_failed statement_not_allowed statement_unparsable
        fixture_load_failed reverse_load_failed rotated_load_failed insert_failed query_failed statement_timeout
        transaction_ended
        transaction_closed rollback_failed
        not_insert missing_columns unknown_column insert_select alias with on_conflict returning not_immutable
        not_plain_value
        not_create_index concurrently unique nulls_not_distinct tablespace on_only storage_options
        unqualified_table forbidden_in_index
      ].freeze

      module_function

      # The fixed note for rule, with {next} as next_step, or nil. It has no
      # last period, as the driver's other notes don't, since a caller such
      # as Teardown.failure can add a sentence after it.
      def for(rule, next_step)
        text = BY_RULE[rule] || (MISSING_ENTRY if missing_entry?(rule))
        text&.gsub("{next}", next_step)&.delete_suffix(".")
      end

      # Whether rule's note ends with what to do next.
      def goes_on?(rule) = self.for(rule, "{next}")&.include?("{next}") || false

      def internal?(rule) = INTERNAL.include?(rule)

      # What an INTERNAL rule shows: the rule, its step when the error line
      # named one, and the shared line.
      def internal_line(rule, step) = "#{rule}#{" (step #{step})" if step}: #{INTERNAL_NOTE}"

      # A missing_<entry> rule, but not one of the rules that just start
      # that way, such as InsertCheck's missing_columns.
      def missing_entry?(rule)
        !Protocol::ErrorRules::NAMES.include?(rule) && Protocol::ErrorRules::MISSING_ENTRY.match?(rule)
      end
    end
  end
end
