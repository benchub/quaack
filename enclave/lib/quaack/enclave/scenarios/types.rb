# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # What the catalog says about a column's type, for Values: its
      # category, an array's element type or a range's subtype, the type a
      # domain is built on, and an enum's labels. Each is looked up once.
      class Types
        INFO_SQL = <<~SQL
          SELECT t.typcategory, NULLIF(t.typelem, 0)::int, r.rngsubtype::int, format_type(r.rngsubtype, NULL),
                 NULLIF(t.typbasetype, 0)::int, format_type(NULLIF(t.typbasetype, 0), t.typtypmod), t.typnotnull
          FROM pg_type t LEFT JOIN pg_range r ON r.rngtypid = t.oid
          WHERE t.oid = $1
        SQL

        # A type's category, its element type (an array's) or subtype (a
        # range's) as a Column, if any, the type a domain is built on, as
        # a Column, or nil for any other type, and whether it or any domain
        # under it is NOT NULL.
        Info = Data.define(:category, :inner, :base, :not_null)

        def initialize(conn)
          @conn = conn
          @infos = {}
        end

        def category(col) = info(col).category

        # The type under any domains.
        def underlying(col) = info(col).base ? underlying(info(col).base) : col

        # A domain's element type or subtype is its base type's.
        def info(col)
          @infos[[col.oid, col.type]] ||= build(col, @conn.exec_params(INFO_SQL, [col.oid]).values.first)
        end

        def labels(col)
          @conn.exec_params("SELECT enumlabel FROM pg_enum WHERE enumtypid = $1 ORDER BY enumsortorder",
                            [col.oid]).column_values(0)
        end

        private

        def build(col, row)
          category, element, subtype, subtype_name, base, base_name, not_null = row
          base &&= col.with(type: base_name, oid: Integer(base))
          inner = base ? info(base).inner : inner(col, category, element, subtype, subtype_name)
          Info.new(category:, base:, inner:, not_null: not_null == "t" || (base ? info(base).not_null : false))
        end

        # An array's element type, with the column's typmod, or a range's
        # subtype.
        def inner(col, category, element, subtype, subtype_name)
          if category == "A" && element && col.type.end_with?("[]")
            col.with(type: col.type.sub(/(\[\])+\z/, ""), oid: Integer(element))
          elsif category == "R" && subtype
            col.with(type: subtype_name, oid: Integer(subtype))
          end
        end
      end
    end
  end
end
