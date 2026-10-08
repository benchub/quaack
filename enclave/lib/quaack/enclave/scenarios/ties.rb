# frozen_string_literal: true

require "pg_query"
require_relative "../predicate_atoms"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # Column values that tie a pooled keyset row comparison on its
      # leading columns, so the later columns decide it. For each k, the
      # first k columns at their literals, and column k + 1 at its literal
      # or one unit either side.
      #
      #   Ties.overrides(conn, parse, atom, schema)
      #   # => [{"qty" => "7", "id" => "900"}, {"qty" => "7", "id" => "901"}, ...]
      #
      # None when the atom isn't a pooled row comparison, its columns span
      # tables, or an element has no literal. The values are real, so they
      # stay in the enclave.
      module Ties
        EQUALS = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))].freeze

        module_function

        # [table, overrides] for each tie of each atom.
        def all(conn, parse, atoms, schema)
          atoms.flat_map { |atom| overrides(conn, parse, atom, schema).map { |o| [atom.columns[0].table, o] } }
        end

        # rows with table's row given the overrides, or nil when the row
        # leaves one of their columns out and it isn't an identity (a
        # generated column). An omitted identity column is set explicitly,
        # since the runner overrides identities.
        def apply(rows, table, overrides, schema)
          row = rows.find { |r| r.table == table }
          missing = overrides.keys - row.columns
          return nil unless missing.all? { |name| schema.column(table, name).default == "identity" }

          tied = tie(row, row.columns + missing, overrides)
          rows.map { |other| other.equal?(row) ? tied : other }
        end

        def tie(row, columns, overrides)
          row.with(columns:, values: columns.zip(row.values).map { |name, v| overrides.fetch(name, v) })
        end

        # Whether table's row may take the overrides: none sets a join key
        # or generated column, or breaks a CHECK.
        def allowed?(table, overrides, topology, checks, schema)
          overrides.none? do |name, v|
            topology.keyed?(table, name) || !checks.allows?(table, schema.column(table, name), v)
          end
        end

        def overrides(conn, parse, atom, schema)
          return [] unless eligible?(atom)

          cols = atom.columns.map { |c| schema.column(c.table, c.name) }
          literals = literals(conn, PredicateAtoms.node(parse, atom).a_expr, cols)
          return [] unless literals

          (1...cols.size).flat_map { |k| level(conn, cols, literals, k) }
        end

        def eligible?(atom)
          atom.kind == :row_comparison && ValuePools.pooled?(atom) && atom.columns.size > 1 &&
            atom.columns.map(&:table).uniq.size == 1
        end

        # Each element's literal, cast to its column's type, or nil when one
        # has none.
        def literals(conn, expr, cols)
          pairs = elements(expr)
          return nil unless pairs.size == cols.size

          found = pairs.zip(cols).map do |(left, right), col|
            ValuePools::Sides.literals(conn, ValuePools.a_expr(:AEXPR_OP, EQUALS.dup, left, right), col).first
          end
          found unless found.any?(&:nil?)
        end

        def elements(expr) = [expr.lexpr, expr.rexpr].map { |side| side.row_expr.args.to_a }.transpose

        def level(conn, cols, literals, index)
          col = cols[index]
          category = ValuePools::Category.of(conn, col)
          prefix = cols.first(index).map(&:name).zip(literals.first(index)).to_h
          values = [literals[index]] + ValuePools.steps(conn, literals[index], col, category)
          values.map { |v| prefix.merge(col.name => v) }
        end
      end
    end
  end
end
