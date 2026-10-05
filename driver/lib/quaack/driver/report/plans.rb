# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A plan as a table of its steps, one row per node in the order the
      # payload sends them (depth first), in the style of explain.depesz.com
      # (DESIGN.md's report). Each step is indented by its depth, under an
      # arrow. A plan whose nodes don't all carry a whole-number depth from
      # zero up, such as one from a payload older than depths, is laid out
      # flat.
      #
      # The steps one plan has and the other doesn't are marked, by class
      # and in words. Two steps are the same when their depth, type, table,
      # and index are; row counts differ between any two runs, so they
      # don't count.
      module Plans
        INDENT = 0.65
        STEP = 1.5
        ARROW = '<span class="arrow" aria-hidden="true">-&gt; </span>'
        MARK = ' <strong class="mark">differs</strong>'
        MARKED = "A step marked “differs”, and shaded, is one the other plan doesn't have in the same place."

        # The table of plan, marking the steps not in other. other is nil
        # when there is no plan to compare with, and nothing is marked.
        def plan_table(plan, other = nil)
          shared = other ? shared_steps(plan, other) : (0...plan.size).to_a
          tree = tree?(plan)
          rows = plan.each_with_index.map { |node, i| plan_row(node, tree, !shared.include?(i)) }
          %(<table class="plan"><thead>#{PLAN_HEADER}</thead>\n<tbody>\n#{rows.join("\n")}\n</tbody></table>)
        end

        PLAN_HEADER = '<tr><th scope="col">Step</th><th scope="col">Table</th><th scope="col">Index</th>' \
                      '<th scope="col" class="num">Estimated rows</th><th scope="col" class="num">Actual rows</th>' \
                      '<th scope="col" class="num">Share of the table</th></tr>'

        # Whether either plan has a step the other doesn't.
        def plans_differ?(plan, other) = [plan.size, other.size].uniq != [shared_steps(plan, other).size]

        def tree?(plan) = plan.all? { it["depth"].is_a?(Integer) && !it["depth"].negative? }

        def plan_row(node, tree, differs)
          depth = tree ? node["depth"] : nil
          step = "#{ARROW if depth&.positive?}#{h node["node"]}#{MARK if differs}"
          %(<tr#{' class="differs"' if differs}><td class="step"#{indent(depth)}>#{step}</td>#{plan_cells(node)}</tr>)
        end

        def plan_cells(node)
          %(<td>#{named(node["relation"])}</td><td>#{named(node["index"])}</td>) +
            "#{count_cell(node["est_rows"])}#{count_cell(node["actual_rows"])}#{num(share(node["selectivity"]))}"
        end

        def indent(depth) = depth ? format(' style="padding-left: %.2frem"', INDENT + (STEP * depth)) : ""

        def named(name) = name ? h(Format.sql_span(name)) : ""

        # A selectivity as a share of the table, or "" if there's none.
        def share(selectivity)
          return "" unless selectivity.is_a?(Numeric)
          return "under 0.1%" if selectivity.positive? && selectivity < 0.0005

          format("%.1f%%", selectivity * 100)
        end

        # The positions in plan of the steps it shares with other: a longest
        # common subsequence of their shapes.
        def shared_steps(plan, other)
          mine, theirs = [plan, other].map { |steps| steps.map { step_shape(it) } }
          lengths = lcs_lengths(mine, theirs)
          row = col = 0
          [].tap do |shared|
            while row < mine.size && col < theirs.size
              same = mine[row] == theirs[col]
              shared << row if same
              row, col = advance(lengths, same, row, col)
            end
          end
        end

        def advance(lengths, same, row, col)
          return [row + 1, col + 1] if same

          lengths[row + 1][col] >= lengths[row][col + 1] ? [row + 1, col] : [row, col + 1]
        end

        def step_shape(node) = node.values_at("node", "relation", "index")

        # lengths[row][col] is the length of the longest common subsequence
        # of mine[row..] and theirs[col..].
        def lcs_lengths(mine, theirs)
          lengths = Array.new(mine.size + 1) { Array.new(theirs.size + 1, 0) }
          (mine.size - 1).downto(0) { |row| fill_row(lengths, row, mine[row], theirs) }
          lengths
        end

        def fill_row(lengths, row, step, theirs)
          below = lengths[row + 1]
          (theirs.size - 1).downto(0) do |col|
            lengths[row][col] = step == theirs[col] ? below[col + 1] + 1 : [below[col], lengths[row][col + 1]].max
          end
        end
      end
    end
  end
end
