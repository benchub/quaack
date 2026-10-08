# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # Mixed into Router: the fan-out entry point (DESIGN.md, "Several LLM
      # providers": Routing, Limits). A fan-out step, one llm_routing.steps
      # gives "fan_out": true, runs its unit once on every healthy provider
      # in its pool, one after another, never at the same time, and never
      # failing over, since every healthy provider already has a branch.
      #
      #   router.branches(step: "llm-rewrites", ...)
      #   # => [[session, reply], ...], one per branch that answered
      #
      # Each session keeps its branch's later asks on its provider, as any
      # unit's does. A step that doesn't fan out gets one unit, picked by the
      # mode, so a step calls branches either way.
      module FanOut
        # A fan-out step's union of lists, each [branch, items], interleaved:
        # each list's first item, then each list's second, and so on,
        # keeping only the first item with each key, such as a rewrite's
        # SQL text: [[branch, item], ...]. So a cap per call holds for the
        # step in all, and every provider gets its best in.
        def self.union(lists, &key)
          longest = lists.map { it.last.size }.max || 0
          (0...longest).flat_map { |i| lists.filter_map { |branch, items| [branch, items[i]] if i < items.size } }
                       .uniq { key.call(it.last) }
        end

        # Whether step fans out.
        def fan_out?(step) = @routing.steps.dig(step, "fan_out") == true

        # A unit's first ask, on each branch: a branch that fails with a rule
        # that fails over is dropped, its provider marked down or dropped as
        # the rule says, and the rest go on. llm_bad_request fails the step.
        # With no branch left, the step fails as a unit with no provider left
        # does, listing what was down already, then each branch's failure.
        def branches(**ask)
          step = ask.fetch(:step)
          return [session.then { [it, it.ask(**ask)] }] unless fan_out?(step)

          tried = prior(step, {})
          answered = branch_asks(ask, healthy(step, {}), tried)
          answered.empty? ? raise(exhausted(ask, tried)) : answered
        end

        private

        # Asks each of names in turn, adding each failure to tried.
        def branch_asks(ask, names, tried)
          names.each_with_index.with_object([]) do |(name, i), answered|
            answered << [Router::Session.new(self, provider: name), call(name, ask)]
          rescue Error => e
            tried << [name, branch_failed(e, name, ask.fetch(:step), last: answered.empty? && i == names.size - 1)]
          end
        end

        # A branch's error, once its provider, name, is marked down or
        # dropped as its rule says, and the line says the step goes on with
        # the others, unless last says none is left. Raises error, named, for
        # a rule that doesn't fail over.
        def branch_failed(error, name, step, last:)
          raise named(error, name) unless Router::FAILS_OVER.include?(error.rule)

          failed(name, error)
          @progress&.note(branch_line(name, error.rule, "going on with the others (#{step})")) unless last
          error
        end

        # Whether name is a copilot command, whose llm_auth means it isn't
        # logged in (Router#line).
        def copilot?(name) = @kinds[name] == "copilot_cli"

        # llm_auth's line stands out, starting with the rule.
        def branch_line(name, rule, rest)
          rule == "llm_auth" ? line(name, rule, rest) : "#{name} failed with #{rule}; #{rest}"
        end
      end
    end
  end
end
