# frozen_string_literal: true

require_relative "../burndown"
require_relative "error"
require_relative "request_sizes"
require_relative "router_lines"

module Quaack
  module Driver
    module LLM
      # The front every LLM caller asks through, over one Client per
      # provider of the run (DESIGN.md, "Several LLM providers": Asks, units,
      # and sessions; Routing).
      #
      #   router = Router.for(LLM.providers(config), clients)
      #   router.ask(step: "llm-rewrites", ...)   # a unit of one
      #   session = router.session                # a multi-turn unit
      #   session.ask(step: "llm-index-ideas", ...)
      #   session.ask(step: "llm-index-ideas", ...)   # on the same provider
      #   session.provider                        # => "groq", the entry that answered
      #
      # A session picks its provider at its first ask, from the step's pool
      # (Routing#pool), under the step's mode: round_robin starts with the
      # next healthy provider after the one the last round_robin unit
      # started on, by one cursor across the whole list; failover starts with
      # the pool's first healthy provider. When that first ask fails with a
      # rule that fails over, it starts again on the next healthy provider
      # in the pool: llm_rate_limited and llm_unavailable mark the provider
      # down, llm_auth drops it, both for the rest of the process, and
      # llm_bad_response marks nothing. llm_bad_request fails the step. A
      # unit with no provider left fails the step with the last failure's
      # rule and what was tried. A later ask that fails marks or drops its
      # provider the same way. For a rule that fails over, it raises a
      # LaterError, which the step may catch to go on without the provider
      # (going_on) or to start its remaining asks fresh on another (fresh).
      # Otherwise it fails the step.
      #
      # Each Client keeps everything it owns: JSON, the re-ask, the error
      # rules, its adapter's retries, and the burndown count, which the
      # router has it make under the provider too.
      #
      # When the providers are named, from an llms list, progress lines and
      # messages name the entry. From an llm block, or none, they read as
      # they always have. Names come from the operator's own config, and none
      # goes into a prompt.
      class Router
        FAILS_OVER = %w[llm_rate_limited llm_unavailable llm_auth llm_bad_response].freeze
        MARKS_DOWN = %w[llm_rate_limited llm_unavailable llm_auth].freeze

        # A later ask in a unit that failed with a rule that fails over,
        # once its provider is marked down or dropped: provider is the
        # entry's name and step the ask's.
        class LaterError < Error
          attr_reader :provider, :step

          def initialize(rule, detail, provider:, step:)
            @provider = provider
            @step = step
            super(rule, detail)
          end
        end

        # One unit: every ask goes to the provider its first ask went to.
        class Session
          # The name of the entry that answered the unit's first ask, or nil
          # before one has.
          attr_reader :provider

          # Each provider this unit failed on, by name, with its Error.
          attr_reader :failures

          # skip holds providers the unit mustn't use, by name, with the
          # Error each failed with; fresh is the note for a unit started
          # fresh, given the provider it starts on.
          def initialize(router, skip: {}, fresh: nil)
            @router = router
            @skip = skip
            @fresh = fresh
            @failures = {}
          end

          # Asks as Client#ask does.
          def ask(**ask)
            return @router.later(@provider, ask, @failures) if @provider

            @provider, reply = @router.first(ask, skip: @skip, fresh: @fresh, failures: @failures)
            reply
          end
        end

        # The router over providers, an LLM::Providers, with clients, one
        # Client per entry, in its order.
        def self.for(providers, clients)
          new(clients: providers.entries.map(&:name).zip(clients).to_h, routing: providers.routing,
              named: providers.named, kinds: providers.entries.to_h { [it.name, it.settings&.provider] })
        end

        # The router over one client, as from an llm block, named name.
        def self.one(client, name: "anthropic")
          self.for(Providers.new(entries: [Entry.new(name:, settings: nil)],
                                 routing: RoutingChecks.routing(nil, [], [name]), named: false), [client])
        end

        def initialize(clients:, routing:, named:, kinds: {})
          @clients = clients
          @routing = routing
          @named = named
          @kinds = kinds
          @down = {}
          @cursor = nil
        end

        # Gives progress to every client, and is told each failover.
        def progress=(progress)
          @progress = progress
          @clients.each_value { it.progress = progress }
        end

        # Every client's counts, added up, by step and by provider.
        def burndown = Burndown.sum(@clients.values.map(&:burndown).uniq(&:object_id))

        def session = Session.new(self)

        # A new unit for the asks left after error, a LaterError, started
        # fresh: it skips skip, each provider this work already failed on,
        # by name with its Error, and its first ask says it's starting fresh,
        # for label, such as "Rewrite Silver Fox". With no provider left,
        # its first ask fails the step with the last failure's rule.
        def fresh(error, skip:, label:)
          Session.new(self, skip:, fresh: lambda { |name|
            note(error.provider, error.rule, "asking #{name} for the remaining rounds, starting fresh " \
                                             "(#{[error.step, label].compact.join(", ")})")
          })
        end

        # Says the step goes on without error's provider, error a
        # LaterError, doing what: "going on without replacement ideas".
        def going_on(error, what) = note(error.provider, error.rule, "#{what} (#{error.step})")

        # Asks as a unit of one.
        def ask(**) = session.ask(**)

        # A unit's first ask: the name of the provider that answered, and its
        # reply. Session calls it, with the providers to skip, the note for
        # a fresh start, and failures to add each provider that fails to,
        # with its Error. With none left, the failure lists what it couldn't
        # try (prior), then failures.
        def first(ask, skip: {}, fresh: nil, failures: {})
          step = ask.fetch(:step)
          prior = prior(step, skip)
          order = start(step, skip, fresh)
          order.each_with_index do |name, i|
            return [name, call(name, ask)]
          rescue Error => e
            failures[name] = failover(e, name, order[i + 1], step)
          end
          raise exhausted(ask, prior + failures.to_a)
        end

        # A later ask in name's unit, adding a failure to failures. Session
        # calls it.
        def later(name, ask, failures = {})
          call(name, ask)
        rescue Error => e
          failed(name, e.rule)
          failures[name] = e
          raise named(e, name) unless FAILS_OVER.include?(e.rule)

          raise LaterError.new(e.rule, named(e, name).message.delete_prefix("#{e.rule}: "),
                               provider: name, step: ask.fetch(:step))
        end

        private

        # The order, saying a fresh unit is starting fresh on the first.
        def start(step, skip, fresh) = order(step, skip).tap { fresh&.call(it.first) if it.any? }

        # What step's unit, skipping skip, can't try: each pool provider
        # already down, with its rule, then each in skip, with its Error.
        def prior(step, skip) = @down.slice(*@routing.pool(step)).except(*skip.keys).to_a + skip.to_a

        def call(name, ask) = @clients.fetch(name).ask(**ask, provider: name, shown: (name if @named))

        # The healthy providers of step's pool, in the order its unit tries
        # them. A round_robin unit turns the cursor to where it starts.
        def order(step, skip = {})
          healthy = healthy(step, skip)
          return healthy if (@routing.steps.dig(step, "mode") || @routing.mode) == "failover"

          names = @routing.names
          start = @cursor ? names.index(@cursor) + 1 : 0
          names.rotate(start).select { healthy.include?(it) }.tap { @cursor = it.first if it.any? }
        end

        # step's pool, less what's down and what's in skip.
        def healthy(step, skip) = @routing.pool(step).reject { @down.key?(it) || skip.key?(it) }

        # error, once its provider, name, is marked down or dropped as its
        # rule says, and the line says why the unit tries next_name, if
        # there's one. Raises error, named, for a rule that doesn't fail
        # over.
        def failover(error, name, next_name, step)
          raise named(error, name) unless FAILS_OVER.include?(error.rule)

          failed(name, error.rule)
          note(name, error.rule, "trying #{next_name} (#{step})") if next_name
          error
        end

        def failed(name, rule)
          @down[name] = rule if MARKS_DOWN.include?(rule) && !@down.key?(name)
        end

        # The line saying why name was left, by rule, then what happens
        # next, rest: "trying groq (llm-rewrites)" (RouterLines).
        def note(name, rule, rest)
          @progress&.note(RouterLines.line(name, rule, rest, named: @named, copilot: @kinds[name] == "copilot_cli"))
        end

        # error, naming the provider after its rule, when the providers are
        # named.
        def named(error, name)
          @named ? Error.new(error.rule, "#{name}: #{error.message.delete_prefix("#{error.rule}: ")}") : error
        end

        # The step's failure when its unit has no provider left: the last
        # rule of tried, with each provider and its rule, and the request's
        # sizes. From an llm block, it's the unit's one failure as it is.
        def exhausted(ask, tried)
          return tried.last.last if !@named && tried.last.last.is_a?(Error)

          rules = tried.map { |name, why| [name, rule(why)] }
          list = rules.map { |name, rule| "#{name} (#{rule})" }.join(", ")
          Error.new(rules.last.last, "every LLM provider #{ask[:step]} may use failed: #{list}. #{sizes(ask)}")
        end

        def rule(why) = why.is_a?(Error) ? why.rule : why

        def sizes(ask)
          RequestSizes.new(step: ask[:step], system: Client.system(ask[:system], ask[:schema]),
                           messages: ask[:messages], max_tokens: ask[:max_tokens])
        end
      end
    end
  end
end
