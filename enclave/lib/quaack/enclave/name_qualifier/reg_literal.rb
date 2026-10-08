# frozen_string_literal: true

require "pg_query"
require "strscan"
require_relative "error"

module Quaack
  module Enclave
    module NameQualifier
      # A string literal cast to a reg type, for NameQualifier.
      #
      # - 'name'::regclass gets the schema of the first relation of the name
      #   on the path, as a relation does, and one that's nowhere is refused
      #   as unknown_relation. 'name'::regtype gets the type's schema, as a
      #   type does. A literal that already names its schema is kept.
      # - Unsupported in v1, refused as unsupported_reg_literal: a regproc,
      #   regprocedure, regoper, or regoperator literal; a regclass or
      #   regtype literal that's an oid, an array, or doesn't read as one
      #   name or type.
      #
      # Other reg types, such as regconfig, are left as written, and resolve
      # through the plan's search path in later steps.
      module RegLiteral
        UNSUPPORTED = "unsupported_reg_literal"
        REFUSED = %w[regproc regprocedure regoper regoperator].freeze
        HANDLED = %w[regclass regtype].freeze
        PLAIN = /\A[a-z_][a-z0-9_$]*\z/
        MAX_IDENTIFIER_BYTES = 63
        # What a regtype literal's text is read after, as a cast's type.
        CAST_PREFIX = "SELECT NULL::"

        module_function

        def qualify!(cast, catalog)
          type = reg_type(cast.type_name)
          constant = cast.arg&.a_const
          return unless type && constant&.val == :sval

          text = constant.sval.sval
          check!(type, cast.type_name, text)
          # Only regclass and regtype get past check!.
          rewritten = public_send(type, text, catalog)
          constant.sval.sval = rewritten if rewritten
        end

        def check!(type, type_name, text)
          refuse!("a #{type} literal") if REFUSED.include?(type) || !type_name.array_bounds.empty?
          refuse!("a #{type} literal that's an oid") if text.match?(/\A(?:\d+|-)\z/)
        end

        # The type's name, if it's a reg type handled or refused here.
        def reg_type(type_name)
          names = type_name.names.map { it.string.sval }
          name = names.last if names.size == 1 || (names.size == 2 && names.first == "pg_catalog")
          name if (REFUSED + HANDLED).include?(name)
        end

        # The literal with its relation's schema, or nil to keep it.
        def regclass(text, catalog)
          names = identifiers(text)
          return nil unless names.size == 1

          schema = catalog.schemas(:relation, names.first).first
          unless schema
            raise Error.new("unknown_relation", "no schema in the search path has a regclass literal's relation")
          end

          [schema, names.first].map { ident(it) }.join(".")
        end

        # Postgres's SplitIdentifierString with "." between names.
        def identifiers(text)
          scanner = StringScanner.new(text)
          names = []
          loop do
            names << identifier(scanner.tap { it.skip(/\s*/) })
            break if scanner.tap { it.skip(/\s*/) }.eos?

            refuse!("a regclass literal that isn't a name") unless scanner.skip(/\./)
          end
          names
        end

        def identifier(scanner)
          name = if scanner.skip(/"/)
                   quoted = scanner.scan(/(?:[^"]|"")*/)
                   refuse!("a regclass literal that isn't a name") unless scanner.skip(/"/)
                   quoted.gsub('""', '"')
                 else
                   scanner.scan(/[^."\s]+/)&.tr("A-Z", "a-z")
                 end
          refuse!("a regclass literal that isn't a name") if name.nil? || name.empty?
          name.bytesize > MAX_IDENTIFIER_BYTES ? name.byteslice(0, MAX_IDENTIFIER_BYTES).scrub("") : name
        end

        def ident(name) = name.match?(PLAIN) ? name : %("#{name.gsub('"', '""')}")

        # The literal with its type's schema, or nil to keep it. The text,
        # with the schema in front, must read as the same type in it.
        def regtype(text, catalog)
          type_name = type_name(text)
          return nil unless type_name.names.size == 1

          schema = catalog.schema(:type, type_name.names.first.string.sval, :first)
          return nil unless schema

          "#{ident(schema)}.#{text.lstrip}".tap { refuse!("a regtype literal") unless same?(it, type_name, schema) }
        end

        # Whether the rewritten text reads as the type, with the schema.
        def same?(rewritten, type_name, schema)
          expected = copy(type_name)
          expected.names.replace([PgQuery::Node.new(string: PgQuery::String.new(sval: schema)), *expected.names.to_a])
          copy(type_name(rewritten)) == expected
        end

        # The one type the text reads as, the way a cast reads it.
        def type_name(text)
          select = bare_select(PgQuery.parse(CAST_PREFIX + text).tree.stmts)
          cast = select.target_list.first.res_target.val.type_cast if select
          refuse!("a regtype literal that isn't a type") unless cast && cast.arg.a_const&.isnull
          cast.type_name
        rescue PgQuery::ParseError
          refuse!("a regtype literal that isn't a type")
        end

        # The one SELECT, if it has nothing but one unnamed target.
        def bare_select(stmts)
          select = stmts.first.stmt.select_stmt if stmts.size == 1
          return nil unless select&.target_list&.size == 1 && select.target_list.first.res_target.name.empty?

          only = PgQuery::SelectStmt.new(target_list: select.target_list.to_a, limit_option: :LIMIT_OPTION_DEFAULT,
                                         op: :SETOP_NONE)
          select if select == only
        end

        # A copy of the type name, without where it was in the text.
        def copy(type_name) = PgQuery::TypeName.decode(PgQuery::TypeName.encode(type_name)).tap { it.location = 0 }

        def refuse!(what) = raise(Error.new(UNSUPPORTED, "#{what} can't be qualified in v1"), cause: nil)
      end
    end
  end
end
