# frozen_string_literal: true

require_relative "../burndown"
require_relative "error"
require_relative "fan_out"
require_relative "pairing"
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

        include FanOut

        # A later ask in a unit that failed with a rule that fails over,
        # once its provider is marked down or dropped: provider is the
        # entry's name and step the ask's.
        class LaterError < Error
          attr_reader :provider, :step

          def initialize(rule, detail, provider:, step:, reason: detail)
            @provider = provider
            @step = step
            super(rule, detail, reason:)
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
          # fresh, given the provider it starts on; pairing, a Pairing or
          # nil, keeps the unit off a rewrite's author. provider pins a
          # fan-out branch's unit to that entry from the start.
          def initialize(router, skip: {}, fresh: nil, pairing: nil, provider: nil)
            @router = router
            @provider = provider
            @skip = skip
            @fresh = fresh
            @pairing = pairing
            @failures = {}
          end

          # The pairing's outcome for this unit (Pairing#outcome), or nil
          # for a unit without pairing or before its first ask answered.
          def pairing = (@pairing.outcome(@provider) if @pairing && @provider)

          # Asks as Client#ask does.
          def ask(**ask)
            return @router.later(@provider, ask, @failures, @router.reviewing(@pairing)) if @provider

            @provider, reply = @router.first(ask, skip: @skip, fresh: @fresh, failures: @failures,
                                                  pairing: @pairing)
            reply
          end
        end

        # The router over providers, an LLM::Providers, with clients, one
        # Client per entry, in its order.
        def self.for(providers, clients)
          new(clients: providers.entries.map(&:name).zip(clients).to_h, routing: providers.routing,
              named: providers.named, settings: providers.entries.to_h { [it.name, it.settings] })
        end

        # The router over one client, as from an llm block, named name.
        def self.one(client, name: "anthropic")
          self.for(Providers.new(entries: [Entry.new(name:, settings: nil)],
                                 routing: RoutingChecks.routing(nil, [], [name]), named: false), [client])
        end

        # settings holds each entry's LLM::Settings, by name, or nil.
        def initialize(clients:, routing:, named:, settings: {})
          @clients = clients
          @routing = routing
          @named = named
          @kinds = settings.transform_values { it&.provider }
          @models = settings.transform_values { it&.model }
          @down = {}
          @cursor = nil
        end

        # Gives progress to every client, and is told each failover.
        def progress=(progress)
          @progress = progress
          @clients.each_value { it.progress = progress }
        end

        # Every client's counts, added up, by step and by provider.
        def burndown = Burndown.sum(@clients.values.map(&:burndown))

        def session(pairing: nil) = Session.new(self, pairing:)

        # The Pairing for a rewrite whose recorded author is author, a Hash
        # with its name and model, or nil; label names the rewrite.
        def pairing(author, label: nil) = LLM::Pairing.for(@routing.counterexample_pairing, author, @models, label:)

        # Each entry's name, provider type, and model, in order, for the
        # provenance record. Router.one's has neither type nor model.
        def entries
          @clients.keys.map { { "name" => it, "provider" => @kinds[it], "model" => @models[it] } }
        end

        # Each provider marked down or dropped so far, by name, with its rule.
        def down = @down.transform_values(&:rule)

        # A new unit for the asks left after error, a LaterError, started
        # fresh: it skips skip, each provider this work already failed on,
        # by name with its Error, and its first ask says it's starting fresh,
        # for label, such as "Rewrite Silver Fox". With no provider left,
        # its first ask fails the step with the last failure's rule.
        def fresh(error, skip:, label:, pairing: nil)
          Session.new(self, skip:, pairing:, fresh: lambda { |name|
            note(error.provider, error, "asking #{name} for the remaining rounds, starting fresh " \
                                        "(#{[error.step, label].compact.join(", ")})")
          })
        end

        # Says the step goes on without error's provider, error a
        # LaterError, doing what: "going on without replacement ideas".
        def going_on(error, what) = note(error.provider, error, "#{what} (#{error.step})")

        # Asks as a unit of one.
        def ask(**) = session.ask(**)

        # A unit's first ask: the name of the provider that answered, and its
        # reply. Session calls it, with the providers to skip, the note for
        # a fresh start, and failures to add each provider that fails to,
        # with its Error. With none left, the failure lists what it couldn't
        # try (prior), then failures. pairing, a Pairing or nil, keeps the
        # unit off a rewrite's author: under require_different, a unit left
        # only the author fails as llm_unavailable.
        def first(ask, skip: {}, fresh: nil, failures: {}, pairing: nil)
          step = ask.fetch(:step)
          prior = prior(step, skip)
          order = start(step, skip, fresh, pairing)
          order.each_with_index do |name, i|
            return [name, call(name, ask, reviewing(pairing))]
          rescue Error => e
            failures[name] = failover(e, name, order[i + 1], step)
          end
          raise left(ask, pairing, prior + failures.to_a)
        end

        # A later ask in name's unit, adding a failure to failures. Session
        # calls it, with what its line adds after the step (reviewing).
        def later(name, ask, failures = {}, context = nil)
          call(name, ask, context)
        rescue Error => e
          failed(name, e)
          failures[name] = e
          raise named(e, name), cause: nil unless FAILS_OVER.include?(e.rule)

          raise LaterError.new(e.rule, named(e, name).message.delete_prefix("#{e.rule}: "),
                               provider: name, step: ask.fetch(:step), reason: e.reason), cause: nil
        end

        private

        # The order, saying a fresh unit is starting fresh on the first.
        def start(step, skip, fresh, pairing) = order(step, skip, pairing).tap { fresh&.call(it.first) if it.any? }

        # What step's unit, skipping skip, can't try: each pool provider
        # already down, then each in skip, each with its Error.
        def prior(step, skip) = @down.slice(*@routing.pool(step)).except(*skip.keys).to_a + skip.to_a

        # Asks name's client, which names the entry in its progress line
        # (label), with context after the step.
        def call(name, ask, context = nil)
          @clients.fetch(name).ask(**ask, provider: name, shown: label(name), context:)
        end

        # The healthy providers of step's pool, in the order its unit tries
        # them, paired by pairing. A round_robin unit turns the cursor to
        # where it starts.
        def order(step, skip, pairing)
          healthy = healthy(step, skip)
          return paired(healthy, pairing) if (@routing.steps.dig(step, "mode") || @routing.mode) == "failover"

          names = @routing.names
          start = @cursor ? names.index(@cursor) + 1 : 0
          paired(names.rotate(start).select { healthy.include?(it) }, pairing).tap { @cursor = it.first if it.any? }
        end

        # order, as pairing orders it (Pairing#order), if there's one.
        def paired(order, pairing) = pairing ? pairing.order(order) : order

        # step's pool, less what's down and what's in skip.
        def healthy(step, skip) = @routing.pool(step).reject { @down.key?(it) || skip.key?(it) }

        # error, once its provider, name, is marked down or dropped as its
        # rule says, and the line says why the unit tries next_name, if
        # there's one. With none, only a dropped provider gets a line, so
        # llm_auth always stands out. Raises error, named, for a rule that
        # doesn't fail over.
        def failover(error, name, next_name, step)
          raise named(error, name), cause: nil unless FAILS_OVER.include?(error.rule)

          failed(name, error)
          next_name ? note(name, error, "trying #{next_name} (#{step})") : none_left(name, error, step)
          error
        end

        def failed(name, error)
          @down[name] = error if MARKS_DOWN.include?(error.rule) && !@down.key?(name)
        end

        # The line saying why name was left, by error's rule and reason,
        # then what happens next, rest: "trying groq (llm-rewrites)"
        # (RouterLines).
        def note(name, error, rest) = @progress&.note(line(name, error, rest))

        # error, naming the provider after its rule, when the providers are
        # named.
        def named(error, name) = @named ? error.naming(name) : error

        # The step's failure when its unit has no provider left: the last
        # rule of tried, with each provider, its rule, and its short reason,
        # and the request's sizes. From an llm block, it's the one
        # provider's failure as it is, though an earlier unit's, with the
        # API's own detail.
        def exhausted(ask, tried)
          return tried.last.last unless @named

          list = tried.map { |name, error| "#{name} (#{RouterLines.failed(error.rule, error.reason)})" }.join("; ")
          Error.new(tried.last.last.rule, "every LLM provider #{ask[:step]} may use failed: #{list}. #{sizes(ask)}")
        end

        # The step's failure when its unit has no provider left: pairing's,
        # under require_different, else exhausted's.
        def left(ask, pairing, tried)
          pairing&.required? ? pairing.failure(ask.fetch(:step), tried) : exhausted(ask, tried)
        end

        def sizes(ask)
          RequestSizes.new(step: ask[:step], system: Client.system(ask[:system], ask[:schema]),
                           messages: ask[:messages], max_tokens: ask[:max_tokens])
        end
      end
    end
  end
end
