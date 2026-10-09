# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctJoinToExists
        # What a select's ORDER BY reads. A name.column in it is that column.
        # A bare name is an output column's first, as in ORDER BY x for
        # SELECT a.title AS x, and only then an input column's. So a bare
        # name counts as the kept table's column of that name only if every
        # output column of that name is that column, or none has the name
        # and the kept table is the one FROM table that has it (Query.read
        # has already found that every column it reads is the kept table's). An output
        # column with no alias that isn't a column (a cast, say, which
        # Postgres may name for the column it casts) leaves every bare name
        # uncounted.
        OrderBy = Data.define(:select, :columns, :kept, :catalog) do
          def initialize(select:, columns: nil, kept: nil, catalog: nil) = super

          # The select list's and ORDER BY's expressions, less the bare
          # names in the ORDER BY that an output column has: those read
          # that output column and nothing more. A bare name no output
          # column has is an input column, which Postgres allows with
          # DISTINCT only if the select list has it.
          def inputs
            names = select.target_list.flat_map { named(it.res_target) }
            outputs = sorts.select { output?(it, names) }
            select.target_list.map { it.res_target.val } + (sorts - outputs)
          end

          # The column of each ORDER BY item that's only a column of the
          # kept table: name.column, or a bare name that's one.
          def sorted
            outputs = outputs()
            sorts.filter_map do |node|
              (ref = node.column_ref) && (Tree.qualified(ref)&.last || counted(bare(node), outputs))
            end
          end

          private

          def sorts = select.sort_clause.map { it.sort_by.node }

          def output?(node, names) = (name = bare(node)) && (names.include?(:star) || names.include?(name))

          def bare(node)
            fields = node.column_ref&.fields
            fields.first.string.sval if fields&.size == 1 && fields.first.node == :string
          end

          # The names an output column may have: its alias, its column's
          # name, or :star for a star.
          def named(target)
            return [target.name] unless target.name.empty?

            fields = target.val.column_ref&.fields
            if fields
              [fields.last.node == :string ? fields.last.string.sval : :star]
            else
              []
            end
          end

          def counted(name, outputs)
            return unless name && outputs

            named = outputs.select { it.first == name }
            name if named.all? { it.last == name }
          end

          def column(name)
            PgQuery::ColumnRef.new(fields: [PgQuery::Node.new(string: PgQuery::String.new(sval: name))])
          end

          # [output name, the kept table's column it is, or nil] for each
          # select-list item, or nil if one has a name this can't tell.
          def outputs
            outputs = select.target_list.map { output(it.res_target) }
            outputs.flatten(1) unless outputs.include?(nil)
          end

          def output(target)
            read = (ref = target.val.column_ref) && columns.resolve(ref)
            return stars if read&.last == :star

            label = target.name.empty? ? read&.last : target.name
            [[label, read&.first == kept.name ? read.last : nil]] if label
          end

          def stars = catalog.column_names(kept.table.schemaname, kept.table.relname).map { [it, it] }
        end
      end
    end
  end
end
