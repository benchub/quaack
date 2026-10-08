# frozen_string_literal: true

module Quaack
  module Protocol
    # Every rule an enclave error line can carry (DESIGN.md's "Where QUAACK
    # runs"), so the driver can give each one words for the operator
    # without loading the enclave. An enclave spec checks the list against
    # the enclave's source. Each is QUAACK's own constant, never a value.
    module ErrorRules
      NAMES = %w[alias already_in_transaction ambiguous_user_schema arena_database_foreign arena_dump_load_failed
                 arena_setup_no_run_server bad_captured_at bad_config bad_conninfo_key bad_input bad_literal
                 bad_literal_sets bad_placeholder bad_placeholder_map bad_port bad_run bad_run_server_database
                 bad_run_server_host bad_run_server_port bad_search_path bad_server bad_statistics bad_store_base
                 bad_type bad_value begin_failed cleanup_failed clock_anchor_in_query clock_function_search_path
                 clock_literal column_statistics_hidden complex_check composite_type_relation concurrently
                 connection_unusable
                 counterexample_payload_unknown_search counterexample_payload_untested
                 counterexample_round_bad_inserts counterexample_round_bad_round counterexample_round_decided
                 counterexample_round_no_arena_setup counterexample_round_out_of_order
                 counterexample_round_unknown_search counterexample_round_untested database_qualified_function
                 deparse_mismatch destroy_command_bad_output destroy_command_failed destroy_command_not_run
                 destroy_command_timed_out domain_check exclusion_constraint execute_failed explain_failed
                 expression_unique_index
                 fixture_load_failed fk_cycle forbidden_in_index foreign_relation hypopg_failed in_transaction
                 index_build_bad_index index_build_hidden_index_used index_build_orphan_cancel_denied
                 index_build_orphan_running index_build_unique index_build_unqualified index_build_wrong_set_hidden
                 index_feedback_no_index_search index_feedback_unknown_search index_payload_no_index_search
                 index_payload_unknown_search index_rank_no_index_search index_rank_unknown_search index_relation
                 index_search_no_racetrack_setup index_search_unknown_search index_test_bad_ddls
                 index_test_no_index_search index_test_unknown_round index_test_unknown_search indexes_hidden
                 inheritance_parent input_too_large insert_failed insert_select internal_error
                 interval_field_qualifier invalid_index_candidate matview_relation memory_command_bad_output
                 memory_command_failed memory_command_timed_out missing_columns name_lookup_function
                 natural_join_unreplaceable
                 not_a_query_parse not_a_table
                 not_create_index not_immutable not_insert not_one_select not_plain_value nulls_not_distinct
                 on_conflict on_only parse_error partitioned_relation pg_dump_failed pg_dump_missing pg_dump_too_old
                 plan_bad_shape plan_gate_bad_plan plan_gate_mismatch_likely_stale_statistics
                 plan_gate_not_comparable plan_no_buffers plan_not_analyzed plan_not_json plan_statement_mismatch
                 plan_table_mismatch plan_too_large
                 plan_unreadable prepare_failed production_connection_failed production_read_failed query_failed
                 query_has_parameters query_not_one_statement query_not_text query_too_large query_unparsable
                 query_unreadable racetrack_bad_clock_anchor racetrack_quaack_schema_foreign
                 racetrack_setup_no_run_server restore_mismatch returning reverse_load_failed rotated_load_failed
                 row_security_statistics_hidden
                 rewrite_check_bad_rewrites rewrite_prune_no_ranking rewrite_prune_unknown_search
                 rewrite_test_no_arena_setup rewrite_test_unknown_search rollback_failed run_from_older_version
                 run_server_autovacuum_on run_server_command_bad_output run_server_command_failed
                 run_server_command_timed_out run_server_connection_failed run_server_cron_active
                 run_server_cron_elsewhere run_server_extension_missing run_server_extension_version
                 run_server_guc_mismatch run_server_hypopg_missing run_server_locale_mismatch
                 run_server_major_version run_server_no_inventory run_server_not_superuser run_server_other_clients
                 run_server_preload_mismatch run_server_same_database run_server_tablespace_mismatch
                 run_server_unspecified secret_in_conninfo sequence_relation session_closed
                 sql_ascii_database statement_canceled statement_not_allowed statement_timeout statement_unparsable
                 statistics_bad_shape storage_options store_error tablespace teardown_failed toast_relation
                 transaction_closed transaction_ended unique unknown_column unknown_name
                 unknown_placeholder unknown_relation
                 unparsable unqualified_table unresolved_relation unsatisfiable_check unsupported_construct
                 unsupported_production_version unsupported_reg_literal unsupported_type untyped_literal usage
                 user_function_in_from
                 using_column_unreplaceable view_relation volatile_function volatility_not_passed
                 with].map(&:freeze).freeze

      # Store::MissingEntry's rule for an entry the store doesn't hold: missing_
      # and the entry's name, such as missing_inventory or
      # missing_index_search_rewrite_3. An entry's name is QUAACK's own, and
      # many are built from a search's name, so the family is a pattern.
      MISSING_ENTRY = /\Amissing_[a-z][a-z0-9_]*\z/

      module_function

      # Whether rule is one an error line can carry: one of NAMES, or of
      # the MISSING_ENTRY family.
      def known?(rule) = NAMES.include?(rule) || MISSING_ENTRY.match?(rule)
    end
  end
end
