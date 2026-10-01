# frozen_string_literal: true

require "pg_query"
require_relative "arena"

module Quaack
  module Enclave
    # The schema that the 5a-5 and 6a payloads send (DESIGN.md 5a-5): 3b's
    # subset trimmed to the query's own tables, not their FK parents, with
    # pg_dump's noise left out.
    #
    #   SchemaPayload.subset(store.read("schema_subset"), store.read("relations"))
    #   # => { "tables" => [["public", "orders"]], "ddl" => "CREATE TABLE public.orders ..." }
    #
    # pg_query splits and classifies the DDL. It drops SET and set_config
    # lines, comments, COMMENT ON, ownership, grants, and sequence
    # statements, and each CREATE TABLE, CREATE INDEX, or ALTER TABLE on a
    # table outside the query's own. It keeps types, enums, domains, and any
    # statement it can't classify, each as pg_dump wrote it, one blank line
    # apart. Trimming only removes: every kept statement is the subset's own
    # text, and the subset is schema, which v1 assumes holds no PII.
    module SchemaPayload
      NOISE = %i[variable_set_stmt comment_stmt grant_stmt grant_role_stmt alter_owner_stmt
                 alter_default_privileges_stmt create_seq_stmt alter_seq_stmt].freeze
      NOISE_FUNCTIONS = %w[set_config setval].freeze

      module_function

      def subset(subset, relations)
        tables = relations.map { [it["schema"], it["name"]] }
        { "tables" => subset["tables"].select { tables.include?(it) }, "ddl" => ddl(subset["ddl"], tables) }
      end

      # tables are [schema, name] pairs.
      def ddl(ddl, tables)
        text = ddl.gsub(Arena::RESTRICT, "")
        kept = PgQuery.parse(text).tree.stmts.filter_map do |raw|
          statement_text(text, raw) if keep?(raw.stmt, tables)
        end
        kept.empty? ? "" : "#{kept.join("\n\n")}\n"
      end

      # The statement's own text, without the blank and comment lines
      # pg_query counts as its start.
      def statement_text(text, raw)
        length = raw.stmt_len.zero? ? text.bytesize : raw.stmt_len
        slice = text.byteslice(raw.stmt_location, length).force_encoding(text.encoding)
        "#{slice.lines.drop_while { lead?(it) }.join.rstrip.delete_suffix(";")};"
      end

      def lead?(line) = line.strip.empty? || line.lstrip.start_with?("--")

      def keep?(stmt, tables)
        node = stmt.node
        return false if NOISE.include?(node)

        inner = stmt.public_send(node)
        case node
        when :select_stmt then !noise_select?(inner)
        when :create_stmt, :index_stmt then tables.include?(relation(inner.relation))
        when :alter_table_stmt then table_alter?(inner, tables)
        else true
        end
      end

      def table_alter?(alter, tables)
        return false if alter.cmds.all? { it.alter_table_cmd&.subtype == :AT_ChangeOwner }

        tables.include?(relation(alter.relation))
      end

      # pg_dump's SELECT pg_catalog.set_config(...) and pg_catalog.setval(...).
      def noise_select?(select)
        select.target_list.size == 1 && (call = select.target_list.first.res_target&.val&.func_call) &&
          NOISE_FUNCTIONS.include?(call.funcname.last&.string&.sval)
      end

      def relation(range_var) = [range_var.schemaname, range_var.relname]
    end
  end
end
