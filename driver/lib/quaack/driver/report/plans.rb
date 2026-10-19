# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A plan as a table of its steps, one row per node in the order the
      # payload sends them (depth first), in the style of explain.depesz.com
      # (DESIGN.md's report). Each step is indented by its depth, under an
      # arrow, and shows the blocks it read, the steps under it included,
      # and, when the plan has times, the time in the step itself.
      # Every node has an Integer depth of zero or more: the driver's reply
      # check refuses a report whose plans fail Protocol::PlanNodes.valid?.
      #
      # Each step's estimated and actual rows cells, not its whole row, are
      # shaded by how far its estimated rows are from its actual rows,
      # either way, both per loop as Postgres gives them: the
      # larger over the smaller, each counted as at least 1, so an estimate
      # of 1 against no rows isn't shaded. Shading starts at 2x and gets
      # redder at each of MISESTIMATE_FLOORS, and once more over
      # MISESTIMATE_OVER. A step without both counts, as in a plan Postgres
      # only estimated, or that never ran (0 loops), isn't shaded.
      #
      # Each step's blocks read and time cells are shaded amber by the
      # step's own share of the plan's (cost): its own blocks or time, less
      # the steps directly under it (own_shares), over the plan's own ones
      # added up, from each of COST_FLOORS percent. The blocks cell still
      # shows the count with the steps under it, and its title gives the
      # step's own.
      module Plans # rubocop:disable Metrics/ModuleLength -- report wording, one note per constant
        INDENT = 0.65
        STEP = 1.5
        ARROW = '<span class="arrow" aria-hidden="true">-&gt; </span>'
        MISESTIMATE_FLOORS = [2, 5, 10, 20, 50, 100, 500].freeze
        MISESTIMATE_OVER = 1000
        MISESTIMATE_LABELS = [*MISESTIMATE_FLOORS.map { "#{it}x" }, "over #{MISESTIMATE_OVER}x"].freeze
        LEGEND_LEAD = "Each step's estimated and actual rows are shaded by how far apart they were, per loop, " \
                      "either way: "
        LEGEND_TAIL = ". A count under 1 counts as 1, so an estimate of 1 row against none isn't shaded, and " \
                      "neither is a step that never ran."
        # The floors, in percent of the plan's, of each bucket of shading
        # on a step's blocks read and time, by its own share (cost).
        COST_FLOORS = [5, 10, 20, 30, 40, 50, 65, 80].freeze
        COST_LEAD = "Blocks read and time are shaded by how much of the plan's each step did itself, without the " \
                    "steps under it: "
        COST_TAIL = " or more. So a step whose blocks read are high only because of the steps under it isn't shaded."
        # What the blocks column can't say in its header: Postgres counts a
        # step's blocks over all its loops but its actual rows per loop, and
        # counts an InitPlan's blocks in the step that ran it, not the step
        # it hangs from.
        BLOCKS_NOTE = "Blocks read count every time a step ran, while actual rows are for one run, so a step that " \
                      "ran many times can show one row next to thousands of blocks. And a subquery Postgres runs " \
                      "once up front (an InitPlan) has its blocks counted in the step that used its result, which " \
                      "needn't be the step it's listed under, so those blocks can show up twice."
        # What the time column can't say in its header. A step's own time
        # is its total time over all its loops less its children's, so a
        # parallel step's adds up its workers', and a subplan's comes off
        # the step it's listed under, not the one that ran it.
        TIME_NOTE = "Time in a step is over all its loops, without the steps under it. With parallel workers, a " \
                    "step adds up each worker's time, so the steps can add up to more than the query took, and the " \
                    "Gather above them can show none. A subquery, InitPlan, or CTE's time comes off the step it's " \
                    "listed under, but Postgres counts it in the step that used its result, so one can show too " \
                    "little time and the other too much."
        # Where the winner's times come from: QUAACK's measured runs take
        # no times, since timing each step adds to the run, so the
        # enclave's winner-timing step runs the winner once more for them.
        WINNER_TIMED_NOTE = "The times come from one more run of the winner on the slow values, apart from the " \
                            "runs QUAACK measured, since timing each step slows the query down. The blocks and " \
                            "rows are from the measured runs."
        # Why the winner's plan has no times, by winner-timing's result.
        WINNER_UNTIMED = {
          "timed_out" => "Times aren't recorded for the winner: the one more run of it that times each step ran " \
                         "past the statement timeout.",
          "failed" => "Times aren't recorded for the winner: the one more run of it that times each step failed.",
          "plan_differs" => "Times aren't recorded for the winner: Postgres ran it with different steps in the one " \
                            "more run that times each step than in the runs QUAACK measured, so its times don't " \
                            "fit these steps."
        }.freeze

        # The table of plan, with a time column if it has any times. The
        # blocks and time cells are shaded by each step's own share of the
        # plan's (cost).
        def plan_table(plan)
          own = timed?(plan) ? own_times(plan) : nil
          header = "#{PLAN_HEADER}#{TIME_HEADER if own}</tr>"
          %(<table class="plan"><thead>#{header}</thead>\n<tbody>\n#{plan_rows(plan, own).join("\n")}\n</tbody></table>)
        end

        # plan's rows, with own's times if it's given.
        def plan_rows(plan, own)
          spent = own&.compact&.sum
          blocks = own_blocks(plan)
          read = blocks.compact.sum
          plan.each_with_index.map do |node, i|
            plan_row(node, blocks_cell(node, blocks[i], read), own && time_cell(own[i], spent))
          end
        end

        PLAN_HEADER = '<tr><th scope="col">Step</th><th scope="col">Table</th><th scope="col">Index</th>' \
                      '<th scope="col" class="num">Estimated rows</th><th scope="col" class="num">Actual rows</th>' \
                      '<th scope="col" class="num">Share of the table</th>' \
                      '<th scope="col" class="num">Blocks read, with the steps under it</th>'
        TIME_HEADER = '<th scope="col" class="num">Time in the step itself</th>'

        # Whether any step of plan has a time, as a plan from EXPLAIN
        # ANALYZE with TIMING does.
        def timed?(plan) = plan.any? { it["actual_total_time"] }

        # Whether any of plans has a step with actual rows, so its rows can
        # be shaded and the legend says what the shading means.
        def shaded?(*plans) = plans.compact.flatten.any? { it["actual_rows"] }

        # Whether any of plans has a step with blocks read or a time, so
        # those can be shaded by cost and the legend says what that means.
        def cost_shaded?(*plans) = plans.compact.flatten.any? { step_blocks(it) || it["actual_total_time"] }

        # The legend for the shading, with a swatch for each bucket.
        def misestimate_legend = legend(LEGEND_LEAD, "misestimate", MISESTIMATE_LABELS, LEGEND_TAIL)

        # The legend for the cost shading, with a swatch for each bucket.
        def cost_legend = legend(COST_LEAD, "cost", COST_FLOORS.map { "#{it}%" }, COST_TAIL)

        def legend(lead, kind, labels, tail)
          swatches = labels.each_with_index.map { |label, i| %(<span class="#{kind}-#{i + 1}">#{label}</span>) }
          %(<p class="note legend">#{h lead}#{swatches.join(" ")}#{h tail}</p>)
        end

        def plan_row(node, blocks, time)
          depth = node["depth"]
          step = "#{ARROW if depth.positive?}#{h node["node"]}"
          %(<tr><td class="step"#{indent(depth)}>#{step}</td>#{plan_cells(node)}#{blocks}#{time}</tr>)
        end

        # The class and title of a step's row count cells, by how far off
        # its estimate was, or nil for none.
        def shade(node)
          bucket = misestimate(node) or return
          off = MISESTIMATE_LABELS[bucket - 1]
          title = bucket > MISESTIMATE_FLOORS.size ? off : "#{off} or more"
          ["misestimate-#{bucket}", "Estimated rows off by #{title}"]
        end

        # The node's shading bucket, 1 for 2x off up to 8 for over 1000x,
        # or nil for none.
        def misestimate(node)
          est, actual, loops = node.values_at("est_rows", "actual_rows", "actual_loops")
          return unless est.is_a?(Numeric) && actual.is_a?(Numeric) && loops != 0

          low, high = [est, actual].map { [it, 1].max }.minmax
          ratio = high.fdiv(low)
          return MISESTIMATE_FLOORS.size + 1 if ratio > MISESTIMATE_OVER

          MISESTIMATE_FLOORS.rindex { ratio >= it }&.+(1)
        end

        # Each step's own time in milliseconds, over all its loops, without
        # its children's: its total time per loop times its loops, less the
        # same for each step directly under it, and never below zero. nil
        # for a step without its time and loops, or with a child without
        # them.
        def own_times(plan) = own_shares(plan) { spent(it) }

        # Each step's own blocks read, without its children's: its blocks,
        # which Postgres already counts over all its loops and with the
        # steps under it, less those of each step directly under it, and
        # never below zero. nil for a step without its blocks, or with a
        # child without them.
        def own_blocks(plan) = own_shares(plan) { step_blocks(it) }

        # Each step's own share of what whole gives for it, the steps under
        # it included: that less whole of each step directly under it, never
        # below zero, as when an InitPlan's or a CTE's cost is counted in
        # another step than the one it's listed under, or a Gather's time
        # is less than its workers' added up. nil if whole is nil for the
        # step or a child.
        def own_shares(plan, &whole)
          plan.each_index.map do |i|
            total = whole.call(plan[i])
            under = children(plan, i).map(&whole)
            [total - under.sum, 0].max if total && under.none?(nil)
          end
        end

        def spent(node)
          time, loops = node.values_at("actual_total_time", "actual_loops")
          time * loops if time && loops
        end

        # The steps directly under plan[index]: those after it, before the
        # next step at its depth or above, one deeper than it.
        def children(plan, index)
          depth = plan[index]["depth"]
          plan.drop(index + 1).take_while { it["depth"] > depth }.select { it["depth"] == depth + 1 }
        end

        # A step's own time, and its share of all the plan's, which is
        # left out when the plan took no time; "not recorded" without one.
        def time_cell(own, spent)
          return View::MISSING unless own

          time = own.positive? && own < 0.05 ? "under 0.1 ms" : Format.decimal(own, "ms")
          shaded_num(spent.positive? ? "#{time} (#{percent(own, spent).round}%)" : time, cost(own, spent, time))
        end

        # A step's blocks read, the steps under it included, shaded by its
        # own blocks' share of the plan's.
        def blocks_cell(node, own, read)
          count = step_blocks(node)
          count.nil? ? View::MISSING : shaded_num(count, cost(own, read, Words.count(own, "block")))
        end

        # The class and title for a cell whose step's own share of the
        # plan's total is own, said as said, or nil when it's under the
        # first of COST_FLOORS, unknown, or the plan's total is zero. The
        # bucket goes by the share rounded as the cells show it, so a cell
        # that reads 5% is shaded as the legend's 5% says.
        def cost(own, total, said)
          return unless own && total.positive?

          share = percent(own, total).round
          bucket = COST_FLOORS.rindex { share >= it } or return
          ["cost-#{bucket + 1}", "#{said} in the step itself, #{share}% of the plan's"]
        end

        def percent(part, whole) = part * 100.0 / whole

        # A number cell, with a class and title from shade if it's given.
        def shaded_num(value, shade)
          return num(value) unless shade

          text = h(value.is_a?(Integer) ? Format.number(value) : value)
          %(<td class="num #{shade.first}" title="#{h shade.last}">#{text}</td>)
        end

        def plan_cells(node)
          shade = shade(node)
          %(<td>#{named(node["relation"])}</td><td>#{named(node["index"])}</td>) +
            "#{row_count_cell(node["est_rows"], shade)}#{row_count_cell(node["actual_rows"], shade)}" \
            "#{num(share(node["selectivity"]))}"
        end

        def row_count_cell(count, shade) = count.nil? ? View::MISSING : shaded_num(count, shade)

        # A step's blocks read: its shared hit and read blocks together, as
        # Postgres counts them, the steps under it included. nil unless the
        # payload has both, as for a plan from a plain EXPLAIN, which has
        # neither: one alone isn't the total.
        def step_blocks(node)
          counts = node.values_at("shared_hit_blocks", "shared_read_blocks")
          counts.sum if counts.all?(Integer)
        end

        def indent(depth) = format(' style="padding-left: %.2frem"', INDENT + (STEP * depth))

        def named(name) = name ? h(Format.sql_span(name)) : ""

        # A selectivity as a share of the table, or "" if there's none.
        def share(selectivity)
          return "" unless selectivity.is_a?(Numeric)
          return "under 0.1%" if selectivity.positive? && selectivity < 0.0005

          format("%.1f%%", selectivity * 100)
        end
      end
    end
  end
end
