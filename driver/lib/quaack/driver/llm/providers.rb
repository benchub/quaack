# frozen_string_literal: true

require "quaack/protocol/burndown"

module Quaack
  module Driver
    module LLM
      # DESIGN.md, "Several LLM providers": the llms list may replace the llm
      # block, and llm_routing says how steps use it. QUAACK_LLM keeps some
      # of its entries for one run.
      LIST = "llms"
      ROUTING = "llm_routing"
      PICK_ENV = "QUAACK_LLM"
      MOST_ENTRIES = 9
      # An entry's name shows up in progress lines, messages, and the report.
      ENTRY_NAME = /\A[a-z0-9_-]{1,32}\z/

      # One provider of the run: its name and what its adapter is built from.
      Entry = Data.define(:name, :settings)

      # The run's entries, in order, and its Routing. named says the entries
      # came from llms, so a message about one names it.
      Providers = Data.define(:entries, :routing, :named) do
        # What the block builds from each entry's settings, in order, such
        # as its client. An Error or ConfigError the block raises names the
        # entry, when named.
        def build
          entries.map do |entry|
            yield entry.settings
          rescue Error, ConfigError => e
            raise unless named

            raise naming(e, entry.name), cause: e.cause
          end
        end

        private

        def naming(error, name)
          return ConfigError.new("#{name}: #{error.message}") if error.is_a?(ConfigError)

          Error.new(error.rule, "#{name}: #{error.message.delete_prefix("#{error.rule}: ")}")
        end
      end

      # llm_routing, checked. steps holds each step's routing as the file
      # gives it. names are the run's entries, after QUAACK_LLM. Nothing acts
      # on it yet: every unit goes to the first entry.
      Routing = Data.define(:mode, :counterexample_pairing, :steps, :names) do
        # The step's pool: its pinned providers, else every entry, less
        # those QUAACK_LLM dropped.
        def pool(step) = steps.dig(step, "providers")&.select { names.include?(it) } || names
      end

      # The checks for llm_routing, by key, as [values, problem].
      module RoutingChecks
        MODES = %w[round_robin failover].freeze
        PAIRINGS = %w[any prefer_different require_different].freeze
        KEYS = %w[mode counterexample_pairing steps].freeze
        STEP_KEYS = %w[providers mode fan_out].freeze
        FAN_OUT_STEPS = %w[llm-rewrites llm-index-ideas rewrite-llm-index-ideas].freeze
        STEPS = Protocol::Burndown::LLM_STEPS
        PAIRED = "llm-counterexamples"

        def self.list(words) = "#{words[0..-2].join(", ")}, or #{words.last}"
        def self.and_list(words) = "#{words[0..-2].join(", ")}, and #{words.last}"
        def self.modes = MODES.join(" or ")

        # raw (nil without it) as a Routing, for all the names in llms and
        # kept, those QUAACK_LLM kept, or raises ConfigError.
        def self.routing(raw, all, kept)
          raw = {} if raw.nil?
          object!(raw, ROUTING)
          unknown!(raw, ROUTING, KEYS)
          mode = one_of!(raw.fetch("mode", "round_robin"), "#{ROUTING}.mode", MODES, modes)
          pairing = one_of!(raw.fetch("counterexample_pairing", "any"), "#{ROUTING}.counterexample_pairing",
                            PAIRINGS, list(PAIRINGS))
          steps = steps!(raw.fetch("steps", {}), all)
          Routing.new(mode:, counterexample_pairing: pairing, steps:, names: kept).tap { pools!(it, pairing) }
        end

        def self.steps!(steps, all)
          object!(steps, "#{ROUTING}.steps")
          steps.each do |step, value|
            at = "#{ROUTING}.steps.#{step}"
            raise ConfigError, "#{at} in #{FILE} isn't an LLM step: use #{list(STEPS)}" unless STEPS.include?(step)

            step!(value, at, step, all)
          end
        end

        def self.step!(value, at, step, all)
          object!(value, at)
          unknown!(value, at, STEP_KEYS)
          one_of!(value["mode"], "#{at}.mode", MODES, modes) if value.key?("mode")
          fan_out!(value["fan_out"], at, step) if value.key?("fan_out")
          providers!(value["providers"], at, all) if value.key?("providers")
        end

        def self.fan_out!(value, at, step)
          unless FAN_OUT_STEPS.include?(step)
            raise ConfigError, "#{at}.fan_out in #{FILE} applies only to #{and_list(FAN_OUT_STEPS)}"
          end
          raise ConfigError, "#{at}.fan_out in #{FILE} must be true or false" unless [true, false].include?(value)
        end

        def self.providers!(value, at, all)
          return if value.is_a?(Array) && value.any? && value.uniq.size == value.size && value.all? { all.include?(it) }

          raise ConfigError, "#{at}.providers in #{FILE} must be a list of different names from #{LIST}"
        end

        # Raises when QUAACK_LLM leaves a pinned step nothing, or when
        # require_different has fewer than two providers to pair from.
        def self.pools!(routing, pairing)
          routing.steps.each_key do |step|
            next unless routing.pool(step).empty?

            raise ConfigError, "#{PICK_ENV} keeps none of #{ROUTING}.steps.#{step}.providers in #{FILE}"
          end
          return unless pairing == "require_different" && routing.pool(PAIRED).size < 2

          raise ConfigError, "#{ROUTING}.counterexample_pairing in #{FILE} is require_different, but " \
                             "#{PAIRED} has fewer than two providers"
        end

        def self.object!(value, at)
          raise ConfigError, "#{at} in #{FILE} must be an object" unless value.is_a?(Hash)
        end

        def self.unknown!(value, at, keys)
          value.each_key do |name|
            raise ConfigError, "#{at}.#{name} in #{FILE} isn't a setting: use #{list(keys)}" unless keys.include?(name)
          end
        end

        def self.one_of!(value, at, values, words)
          values.include?(value) ? value : raise(ConfigError, "#{at} in #{FILE} must be #{words}")
        end
      end

      # The run's Providers, from config, the parsed driver config (nil when
      # there's none), and env. Raises ConfigError naming the key or the
      # variable, never a value.
      #
      # Without llms, it's the llm block's one entry, or Anthropic's with no
      # block, named after its provider, with the block's overrides (see
      # `settings`). With llms, each entry is checked as the llm block is,
      # with its position in the key, plus its name. QUAACK_MODEL,
      # QUAACK_LLM_PROVIDER, and QUAACK_LLM_BASE_URL don't apply to llms.
      # QUAACK_LLM keeps only the entries it names, in its order, after every
      # entry is checked.
      def self.providers(config, env: ENV)
        config ||= {}
        raise ConfigError, "use #{BLOCK} or #{LIST} in #{FILE}, not both" if config.key?(BLOCK) && config.key?(LIST)
        return one_provider(config, env) unless config.key?(LIST)

        refuse_overrides(env)
        entries = list_entries(config[LIST])
        kept = picked(entries, env, named: true)
        Providers.new(entries: kept, routing: RoutingChecks.routing(config[ROUTING], entries.map(&:name),
                                                                    kept.map(&:name)), named: true)
      end

      def self.one_provider(config, env)
        if config.key?(ROUTING)
          raise ConfigError, "#{ROUTING} in #{FILE} needs #{LIST}, since one provider has nothing to route"
        end

        settings = settings(config[BLOCK], env:)
        entries = picked([Entry.new(name: settings.provider, settings:)], env, named: false)
        Providers.new(entries:, routing: RoutingChecks.routing(nil, [], entries.map(&:name)), named: false)
      end

      def self.refuse_overrides(env)
        VARIABLES.each_value do |variable|
          next if env[variable].nil? || env[variable].empty?

          raise ConfigError, "#{variable} doesn't apply to #{LIST} in #{FILE}: use #{PICK_ENV} instead"
        end
      end

      def self.list_entries(list)
        unless list.is_a?(Array) && (1..MOST_ENTRIES).cover?(list.size)
          raise ConfigError, "#{LIST} in #{FILE} must be a list of one to nine objects"
        end

        seen = {}
        list.each_with_index.map do |entry, index|
          at = "#{LIST}[#{index}]"
          name = entry_name(entry, at, seen)
          seen[name] = at
          Entry.new(name:, settings: settings(entry.except("name"), env: {}, at:))
        end
      end

      def self.entry_name(entry, at, seen)
        raise ConfigError, "#{at} in #{FILE} must be an object" unless entry.is_a?(Hash)

        RoutingChecks.unknown!(entry, at, ["name", *KEYS])
        name = entry.fetch("name") { raise ConfigError, "#{at}.name in #{FILE} is required" }
        unless name.is_a?(String) && ENTRY_NAME.match?(name)
          raise ConfigError, "#{at}.name in #{FILE} must be 1 to 32 lowercase letters, digits, _, or -"
        end
        raise ConfigError, "#{at}.name in #{FILE} is the same as #{seen[name]}.name" if seen.key?(name)

        name
      end

      # entries, or only those QUAACK_LLM names, in its order. named says
      # they came from llms, not the one provider of a lone llm block or none.
      def self.picked(entries, env, named:)
        value = env[PICK_ENV]
        return entries if value.nil? || value.empty?

        names = value.split(",", -1)
        by_name = entries.to_h { [it.name, it] }
        return names.map { by_name[it] } if names.uniq.size == names.size && names.all? { by_name.key?(it) }

        raise ConfigError, unpicked(entries, named)
      end

      # What a QUAACK_LLM that doesn't pick from entries is told.
      def self.unpicked(entries, named)
        return "#{PICK_ENV} must be different names from #{LIST} in #{FILE}, separated by commas" if named

        "#{PICK_ENV} must be #{entries.first.name}, the one provider's name, since #{FILE} has no #{LIST}"
      end

      private_class_method :one_provider, :refuse_overrides, :list_entries, :entry_name, :picked, :unpicked
    end
  end
end
