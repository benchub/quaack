# frozen_string_literal: true

require "pg_query"
require_relative "relation_qualifier"
require_relative "structured_literal"

module Quaack
  module Enclave
    # InsertCheck's clock_literal rule (task 20260925-2): a counterexample's
    # value mustn't hold 'now', 'today', 'tomorrow', or 'yesterday' where
    # Postgres would read it as a date, time, or timestamp, since that
    # reads the clock, and the fixture would change from run to run.
    #
    #   InsertClockWords.check(cols, rows, column_types, settings, connection)
    #   # => nil, or raises Error "clock_literal: a value for column shipped could read the clock"
    #   InsertClockWords.clock_params(cols, rows, column_types, settings, connection) { |number| value }
    #   # => the locations of the $n whose value the block gives would read the clock
    #
    # cols is the insert's column list, rows its VALUES rows, and
    # column_types each column's type OID by name. check takes rows
    # InsertValues has checked; clock_params takes them unbound, before
    # Counterexamples binds each $n, so it can bind the clock anchor's
    # value instead where the word would read the clock.
    #
    # Each string constant (or $n) is read as every type it could become
    # on its way into its column, and each one it could become is checked:
    # - its column's type, and the type of each cast between it and the
    #   column, as '{today}'::text::date[] is text and date[];
    # - for an ARRAY[] element, the element type of each of those, except
    #   that a nested ARRAY[], or a cast to an array type, is a sub-array
    #   of the same type;
    # - for a function's argument, the type of that parameter in each
    #   function the call could resolve to (every function of that name
    #   that could take that many arguments, in the named schema or else
    #   every schema of the plan's search path, as the volatility check
    #   finds them), and also every type the call's result could become,
    #   since a function such as lower can pass a word on.
    # A cast's type is looked up by name in the same way, and any type of
    # that name counts. A bad search path is bad_search_path.
    #
    # A date, time, timetz, timestamp, or timestamptz reads the clock if
    # the text holds a clock word as a word of its own, in any case: not
    # next to another letter. Postgres's date and time input reads 'Today',
    # ' now ', 'today 10:00', '10:00,tomorrow', and '"today"' alike. The
    # deterministic special inputs, 'epoch', 'infinity', '-infinity', and
    # 'allballs', are fine. A domain is read as its base type. An array,
    # range, multirange, or composite is split into its elements, bounds,
    # ranges, or fields, quotes and backslash escapes undone, as Postgres
    # splits it (StructuredLiteral), and each part is read as its own type,
    # so '{to\day}' is refused for a date[], and '(2024-01-01,now)' is fine
    # for a composite whose second field is text. Text that can't be split
    # that way, and a polymorphic or other pseudo-type parameter, are
    # refused if a clock word is there once backslashes and double quotes
    # are dropped. Any other type reads no clock.
    #
    # The message names the rule and the column, never the constant.
    module InsertClockWords
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      WORD = /(?<![a-z])(?:now|today|tomorrow|yesterday)(?![a-z])/i

      # The types of that name in the schemas, or their array types.
      TYPES_SQL = <<~SQL
        SELECT CASE WHEN $3 THEN t.typarray ELSE t.oid END FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = ANY ($1::text[]) AND t.typname = $2
      SQL

      # The type of argument $4 (from 0) of each function the call could
      # resolve to, as InsertValues finds them.
      PARAMETER_TYPES_SQL = <<~SQL
        SELECT CASE WHEN p.provariadic <> 0 AND $4::int >= p.pronargs - 1 THEN p.provariadic
                    ELSE p.proargtypes[$4::int] END
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY ($1::text[]) AND p.proname = $2
          AND $3::int >= p.pronargs - p.pronargdefaults
          AND ($3::int <= p.pronargs OR p.provariadic <> 0)
      SQL

      # What a type is: whether it's a date or time type, its kind, its
      # domain's base type, its array's element type, its range's subtype,
      # its multirange's range type, and its composite's field types.
      TYPE_SQL = <<~SQL
        SELECT t.oid IN ('pg_catalog.date'::pg_catalog.regtype, 'pg_catalog.time'::pg_catalog.regtype,
                         'pg_catalog.timetz'::pg_catalog.regtype, 'pg_catalog.timestamp'::pg_catalog.regtype,
                         'pg_catalog.timestamptz'::pg_catalog.regtype),
               t.typtype::text, t.typbasetype,
               CASE WHEN t.typsubscript = 'pg_catalog.array_subscript_handler'::pg_catalog.regproc
                    THEN t.typelem ELSE 0 END,
               (SELECT r.rngsubtype FROM pg_catalog.pg_range r WHERE r.rngtypid = t.oid),
               (SELECT r.rngtypid FROM pg_catalog.pg_range r WHERE r.rngmultitypid = t.oid),
               (SELECT pg_catalog.array_agg(a.atttypid ORDER BY a.attnum) FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped)
        FROM pg_catalog.pg_type t WHERE t.oid = $1
      SQL

      TypeInfo = Data.define(:clock, :kind, :base, :element, :subtype, :range, :fields)

      # Where a constant could be read as a type: its column's type, a
      # cast's, an ARRAY[] element of another target, or a function's
      # parameter.
      Column = Data.define(:name)
      Cast = Data.define(:type_name)
      Element = Data.define(:of)
      Parameter = Data.define(:func, :position, :open)

      # A string constant or $n, its value's column, and where it could be
      # read as a type.
      Value = Data.define(:node, :column, :targets)

      module_function

      def check(cols, rows, column_types, settings, connection)
        types = Types.new(column_types, settings, connection)
        refused = values(cols, rows).find { (text = constant(it.node)) && types.reads_clock?(text, it.targets) }
        raise Error.new("clock_literal", "a value for column #{refused.column} could read the clock") if refused

        nil
      end

      def clock_params(cols, rows, column_types, settings, connection)
        types = Types.new(column_types, settings, connection)
        values(cols, rows).filter_map do |value|
          param = value.node.param_ref or next
          text = yield param.number
          param.location if text && types.reads_clock?(text, value.targets)
        end
      end

      def constant(node) = node.a_const&.sval&.sval

      def values(cols, rows)
        rows.flat_map do |row|
          cols.zip(row).flat_map { |col, value| walk(value, col.res_target.name, [Column.new(col.res_target.name)]) }
        end
      end

      def walk(node, column, targets)
        inner = node.inner
        case inner
        when PgQuery::A_Const then constant(node) ? [Value.new(node:, column:, targets:)] : []
        when PgQuery::ParamRef then [Value.new(node:, column:, targets:)]
        when PgQuery::TypeCast then walk(inner.arg, column, [*closed(targets), Cast.new(inner.type_name)])
        when PgQuery::A_ArrayExpr then inner.elements.flat_map { walk(it, column, element_targets(it, targets)) }
        when PgQuery::FuncCall then arguments(inner, column, targets)
        else []
        end
      end

      def arguments(func, column, targets)
        open = func.args.size > 1
        func.args.each_with_index.flat_map { |arg, i| walk(arg, column, [*targets, Parameter.new(func, i, open)]) }
      end

      # The targets of an ARRAY[] element. One that's an array itself, a
      # nested ARRAY[] or a cast to an array type, is a sub-array: it
      # becomes part of the same array, of the same type, not an element.
      def element_targets(element, targets)
        cast = element.type_cast
        return targets if element.a_array_expr || (cast && !cast.type_name.array_bounds.empty?)

        targets.map { Element.new(it) }
      end

      # The targets once a cast gives the constant its type, so a
      # polymorphic parameter no longer decides it.
      def closed(targets) = targets.map { it.is_a?(Parameter) ? it.with(open: false) : it }

      # The types the targets could be, looked up in arena's catalog, and
      # whether text read as any of them reads the clock.
      class Types
        def initialize(column_types, settings, connection)
          @column_types = column_types
          @settings = settings
          @connection = connection
          @infos = {}
        end

        def reads_clock?(text, targets)
          return false unless loose?(text)

          targets.flat_map { oids(it) }.uniq.any? { reads?(text, it) }
        end

        private

        # Whether a clock word could be in the text once quotes and escapes
        # are undone. Nothing without one can read the clock.
        def loose?(text) = WORD.match?(text) || WORD.match?(text.gsub(/[\\"]/, ""))

        def oids(target)
          case target
          when Column then [@column_types[target.name]].compact.map { Integer(it.to_s, 10) }
          when Cast then cast_types(target.type_name)
          when Element then oids(target.of).filter_map { element(it) }
          when Parameter then parameter_types(target)
          end
        end

        def element(oid)
          info = info(oid)
          return element(info.base) if info.kind == "d"

          info.kind == "p" ? oid : info.element
        end

        def reads?(text, oid)
          return false unless text && loose?(text)

          info = info(oid)
          return WORD.match?(text) if info.clock

          parts(text, info)
        rescue ArgumentError
          true
        end

        def parts(text, info)
          case info.kind
          when "d" then reads?(text, info.base)
          when "p" then true
          when "c" then fields(text, info)
          else split(text, info).any? { |part, oid| reads?(part, oid) }
          end
        end

        # Each part of a range, multirange, or array, and its type.
        def split(text, info)
          if info.kind == "r" then StructuredLiteral.range(text).map { [it, info.subtype] }
          elsif info.kind == "m" then StructuredLiteral.multirange(text).map { [it, info.range] }
          elsif info.element then StructuredLiteral.array(text).map { [it, info.element] }
          else []
          end
        end

        def fields(text, info)
          values = StructuredLiteral.record(text)
          raise ArgumentError, "field count" unless values.size == info.fields.size

          values.zip(info.fields).any? { |value, oid| reads?(value, oid) }
        end

        def info(oid)
          @infos[oid] ||= begin
            row = @connection.exec_params(TYPE_SQL, [oid]).values.first || []
            clock, kind, base, element, subtype, range, fields = row
            TypeInfo.new(clock: clock == "t", kind:, base: nonzero(base), element: nonzero(element),
                         subtype: nonzero(subtype), range: nonzero(range),
                         fields: fields ? fields.delete("{}").split(",").map { Integer(it, 10) } : [])
          end
        end

        def nonzero(oid) = oid && oid != "0" ? Integer(oid, 10) : nil

        def cast_types(type_name)
          schemas, name = lookup(type_name.names)
          catalog_oids(TYPES_SQL, [schemas, name, !type_name.array_bounds.empty?]).reject(&:zero?)
        end

        # A polymorphic or other pseudo-type parameter counts only when the
        # constant reaches it uncast and another argument could decide its
        # type: Postgres can't resolve one from an unknown alone.
        def parameter_types(target)
          types = candidate_types(target.func, target.position)
          target.open ? types : types.reject { info(it).kind == "p" }
        end

        def candidate_types(func, position)
          schemas, name = lookup(func.funcname)
          catalog_oids(PARAMETER_TYPES_SQL, [schemas, name, func.args.size.to_s, position.to_s])
        end

        # The schemas to look a name up in, as a text array, and the name.
        def lookup(names)
          *qualifier, name = names.map { it.string.sval }
          [RelationQualifier.text_array(qualifier.empty? ? search_path : [qualifier.last]), name]
        end

        def catalog_oids(sql, params)
          @connection.exec_params(sql, params).column_values(0).compact.map { Integer(it, 10) }
        end

        def search_path
          @search_path ||= RelationQualifier.search_path(@settings, @connection)
        rescue RelationQualifier::Error => e
          raise Error.new("bad_search_path", e.message), cause: nil
        end
      end
    end
  end
end
