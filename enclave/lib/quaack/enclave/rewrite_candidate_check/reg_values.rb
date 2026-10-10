# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # Where a rewrite candidate could get a reg type's value, or look up a
      # name given as text, other than from the original's $n (20261008-31).
      # Postgres reads a reg type's text through the catalog, so whether a
      # candidate that does either plans, or what it returns, would say
      # whether a relation, type, or other name exists. Each check raises
      # RewriteCandidateCheck's Error, and its message never depends on
      # what the name is or whether it exists.
      module RegValues
        # The types whose input reads the catalog.
        TYPES = %w[regclass regtype regproc regprocedure regoper regoperator regnamespace regrole regcollation
                   regconfig regdictionary].freeze

        REG_DETAIL = "a reg type's value can come only from the original's $n in v1"

        # pg_catalog's functions, on Postgres 18, that aren't volatile and
        # look up a catalog name, or a setting, given as text or name.
        NAME_LOOKUPS = %w[
          to_regclass to_regcollation to_regnamespace to_regoper to_regoperator to_regproc to_regprocedure
          to_regrole to_regtype to_regtypemod pg_has_role pg_get_serial_sequence pg_get_viewdef
          pg_get_object_address pg_input_is_valid pg_input_error_info row_security_active schema_to_xml
          schema_to_xml_and_xmlschema schema_to_xmlschema obj_description shobj_description
          pg_extension_update_paths pg_replication_origin_oid ts_parse ts_token_type current_setting
          pg_settings_get_flags
        ].to_set.freeze
        # pg_catalog's functions, on Postgres 18, that aren't volatile and give
        # back what a catalog object is, or how it's used, from its oid, which
        # a literal integer supplies (20261008-39). Whether one answers would
        # say whether an object exists, or what it holds, on the racetrack.
        # A spec checks this list and NAME_LOOKUPS against the catalog's own
        # functions with an oid or reg type argument.
        OID_LOOKUPS = %w[
          col_description format_type pg_basetype pg_collation_is_visible pg_column_is_updatable
          pg_conversion_is_visible pg_describe_object pg_filenode_relation pg_function_is_visible pg_get_acl
          pg_get_constraintdef pg_get_expr pg_get_function_arg_default pg_get_function_arguments
          pg_get_function_identity_arguments pg_get_function_result pg_get_function_sqlbody pg_get_functiondef
          pg_get_indexdef pg_get_partition_constraintdef pg_get_partkeydef pg_get_replica_identity_index
          pg_get_ruledef pg_get_statisticsobjdef pg_get_statisticsobjdef_columns pg_get_statisticsobjdef_expressions
          pg_get_triggerdef pg_get_userbyid pg_identify_object pg_identify_object_as_address
          pg_index_column_has_property pg_index_has_property pg_indexam_has_property pg_indexam_progress_phasename
          pg_is_other_temp_schema pg_opclass_is_visible pg_operator_is_visible pg_opfamily_is_visible
          pg_partition_root pg_relation_filenode pg_relation_filepath pg_relation_is_publishable
          pg_relation_is_updatable pg_sequence_parameters pg_statistics_obj_is_visible pg_table_is_visible
          pg_tablespace_databases pg_tablespace_location pg_ts_config_is_visible pg_ts_dict_is_visible
          pg_ts_parser_is_visible pg_ts_template_is_visible pg_type_is_visible table_to_xml
          table_to_xml_and_xmlschema table_to_xmlschema satisfies_hash_partition acldefault makeaclitem
          fmgr_c_validator fmgr_internal_validator fmgr_sql_validator postgresql_fdw_validator
        ].to_set.freeze

        # Each reg type's input and binary input function, which look a name
        # up from text and are stable. Written as a call, they're name
        # lookups.
        INPUT_FUNCTIONS = TYPES.flat_map { ["#{it}in", "#{it}recv"] }.to_set.freeze

        # The text search functions whose first argument is a regconfig or
        # regdictionary. Postgres reads an integer there as an oid and
        # raises "cache lookup failed" for one that names nothing.
        TS_CONFIG = %w[
          to_tsvector to_tsquery plainto_tsquery phraseto_tsquery websearch_to_tsquery json_to_tsvector
          jsonb_to_tsvector ts_debug ts_headline ts_lexize
        ].to_set.freeze
        PRIVILEGE = /\Ahas_[a-z_]+_privilege\z/
        STATS = /\Apg_stat_get_/

        module_function

        # What the parse alone shows, before anything reads the catalog: a
        # cast to a reg type of anything but a $n, a call to a function
        # named for a reg type, and a call to a name lookup the original
        # doesn't make, argument for argument.
        def syntactic!(parse, original_sql)
          raise Error.new("unsupported_reg_literal", REG_DETAIL) if casts?(parse) || reg_calls?(parse)

          lookup = unmade_lookup(parse, original_sql)
          return unless lookup

          raise Error.new("name_lookup_function",
                          "#{name(lookup)} looks up a name, and the original doesn't make the same call")
        end

        # The first name lookup the original doesn't make, or nil.
        def unmade_lookup(parse, original_sql)
          made = made(original_sql)
          calls(parse.tree).find { |call| (lookup?(name(call)) || integer_config?(call)) && !made.include?(text(call)) }
        end

        def casts?(parse)
          walk(parse.tree, PgQuery::TypeCast).any? do |cast|
            TYPES.include?(bare(cast.type_name.names)) && !cast.arg&.param_ref
          end
        end

        def reg_calls?(parse) = calls(parse.tree).any? { TYPES.include?(name(it)) }

        # Whether a text search call's first argument holds an integer
        # constant anywhere in it, such as 16384, 16384::regconfig, or
        # 16000 + 384: an oid for a config or dictionary.
        def integer_config?(call)
          TS_CONFIG.include?(name(call)) && walk(call.args.first, PgQuery::A_Const).any? { it.val == :ival }
        end

        def lookup?(name)
          NAME_LOOKUPS.include?(name) || OID_LOOKUPS.include?(name) || INPUT_FUNCTIONS.include?(name) ||
            PRIVILEGE.match?(name.to_s) ||
            STATS.match?(name.to_s)
        end

        # The name of a function, bare or in pg_catalog, or nil.
        def name(call) = bare(call.funcname)

        def bare(names)
          names = names.map { it.string.sval }
          names.last if names.size == 1 || names == ["pg_catalog", names.last]
        end

        def calls(tree) = walk(tree, PgQuery::FuncCall)

        # The deparsed calls the original makes, without where they were.
        def made(sql)
          sql ? calls(PgQuery.parse(sql).tree).map { text(it) } : []
        rescue PgQuery::ParseError
          []
        end

        def text(call)
          target = PgQuery::Node.new(res_target: PgQuery::ResTarget.new(val: PgQuery::Node.new(func_call: call)))
          select = PgQuery::SelectStmt.new(target_list: [target], limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
          stmt = PgQuery::RawStmt.new(stmt: PgQuery::Node.new(select_stmt: select))
          PgQuery.deparse(PgQuery::ParseResult.new(version: PgQuery::PG_VERSION_NUM, stmts: [stmt]))
        end

        # Every node of type in the tree, in tree order.
        def walk(node, type, found = [])
          case node
          when type then found << node
          end
          case node
          when Google::Protobuf::RepeatedField then node.each { walk(it, type, found) }
          when PgQuery::Node then walk(node.inner, type, found)
          when Google::Protobuf::MessageExts then node.class.descriptor.each { walk(it.get(node), type, found) }
          end
          found
        end
      end
    end
  end
end
