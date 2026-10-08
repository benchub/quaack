# frozen_string_literal: true

require_relative "../burndown"
require_relative "error"
require_relative "request_sizes"

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
      # provider the same way, and fails the step.
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

        # Why the router moved on from a provider, for the failover line.
        WHY = { "llm_rate_limited" => "is rate limited", "llm_unavailable" => "is unavailable" }.freeze
        REFUSED = "the API refused the credentials"
        NOT_LOGGED_IN = "the copilot command said it isn't logged in"
        FIX = "Fix its credentials before the next run."
        STILL = "though later asks may still use it"

        # One unit: every ask goes to the provider its first ask went to.
        class Session
          # The name of the entry that answered the unit's first ask, or nil
          # before one has.
          attr_reader :provider

          def initialize(router)
            @router = router
          end

          # Asks as Client#ask does.
          def ask(**ask)
            return @router.later(@provider, ask) if @provider

            @provider, reply = @router.first(ask)
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

        # Asks as a unit of one.
        def ask(**) = session.ask(**)

        # A unit's first ask: the name of the provider that answered, and its
        # reply. Session calls it. tried holds each pool provider that was
        # already down, with its rule, then each that failed, with its Error,
        # for the failure when none is left.
        def first(ask)
          step = ask.fetch(:step)
          order = order(step)
          tried = @down.slice(*@routing.pool(step)).to_a
          order.each_with_index do |name, i|
            return [name, call(name, ask)]
          rescue Error => e
            tried << [name, failover(e, name, order[i + 1], step)]
          end
          raise exhausted(ask, tried)
        end

        # A later ask in name's unit. Session calls it.
        def later(name, ask)
          call(name, ask)
        rescue Error => e
          failed(name, e.rule)
          raise named(e, name)
        end

        private

        def call(name, ask) = @clients.fetch(name).ask(**ask, provider: name, shown: (name if @named))

        # The healthy providers of step's pool, in the order its unit tries
        # them. A round_robin unit turns the cursor to where it starts.
        def order(step)
          healthy = @routing.pool(step).reject { @down.key?(it) }
          return healthy if (@routing.steps.dig(step, "mode") || @routing.mode) == "failover"

          names = @routing.names
          start = @cursor ? names.index(@cursor) + 1 : 0
          names.rotate(start).select { healthy.include?(it) }.tap { @cursor = it.first if it.any? }
        end

        # error, once its provider, name, is marked down or dropped as its
        # rule says, and the line says why the unit tries next_name, if
        # there's one. Raises error, named, for a rule that doesn't fail
        # over.
        def failover(error, name, next_name, step)
          raise named(error, name) unless FAILS_OVER.include?(error.rule)

          failed(name, error.rule)
          say(name, error.rule, next_name, step) if next_name
          error
        end

        def failed(name, rule)
          @down[name] = rule if MARKS_DOWN.include?(rule) && !@down.key?(name)
        end

        # The failover line, saying why name was left and that the unit tries
        # next_name.
        def say(name, rule, next_name, step)
          trying = "trying #{next_name} (#{step})"
          @progress&.note(
            case rule
            when "llm_auth" then "#{dropped(name)} #{trying.capitalize}"
            when "llm_bad_response" then "#{name}'s reply couldn't be used, #{STILL}; #{trying}"
            else "#{name} #{WHY.fetch(rule)}, so the rest of this run skips it; #{trying}"
            end
          )
        end

        def dropped(name)
          refused = @kinds[name] == "copilot_cli" ? NOT_LOGGED_IN : REFUSED
          "llm_auth: #{name}: #{refused}, so the rest of this run skips #{name}. #{FIX}"
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
