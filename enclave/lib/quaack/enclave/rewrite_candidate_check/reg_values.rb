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
        PRIVILEGE = /\Ahas_[a-z_]+_privilege\z/

        module_function

        # What the parse alone shows, before anything reads the catalog: a
        # cast to a reg type of anything but a $n, a call to a function
        # named for a reg type, and a call to a name lookup the original
        # doesn't make, argument for argument.
        def syntactic!(parse, original_sql)
          raise Error.new("unsupported_reg_literal", REG_DETAIL) if casts?(parse) || reg_calls?(parse)

          lookup = calls(parse.tree).find { lookup?(name(it)) && !made(original_sql).include?(text(it)) }
          return unless lookup

          raise Error.new("name_lookup_function",
                          "#{name(lookup)} looks up a name, and the original doesn't make the same call")
        end

        def casts?(parse)
          walk(parse.tree, PgQuery::TypeCast).any? do |cast|
            TYPES.include?(bare(cast.type_name.names)) && !cast.arg&.param_ref
          end
        end

        def reg_calls?(parse) = calls(parse.tree).any? { TYPES.include?(name(it)) }

        def lookup?(name) = NAME_LOOKUPS.include?(name) || PRIVILEGE.match?(name.to_s)

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
