# frozen_string_literal: true

require "quaack/protocol/burndown"
require_relative "store"

module Quaack
  module Enclave
    # The enclave script's side of the README 15b burndown: per-stage counts
    # and work totals, kept in the governed store as each step runs, in one
    # entry named burndown.
    #
    #   Burndown.record(store, "5a-3", :original, in: 10, dropped: { duplicate: 2 }, set_aside: 1, out: 7)
    #   Burndown.add_totals(store, hypothetical_explains: 12)
    #   Burndown.read(store)
    #   # => { "stages" => { "5a-3" => { "original" => { "in" => 10, "added" => {}, "dropped" => { "duplicate" => 2 },
    #   #                                                 "set_aside" => 1, "out" => 7, "extra" => {} } } },
    #   #      "totals" => { "hypothetical_explains" => 12 } }
    #   Egress.serialize(Burndown.message(store))  # the burndown type on the whitelist
    #
    # A stage is one of Protocol::Burndown::STAGES. A search is :original
    # for the original query, or a Symbol naming a rewrite, since 5a-3
    # through 5a-7 run again for each rewrite in steps 8 and 11. A record's
    # fields:
    #
    # - in: how many items came into the stage.
    # - added: how many the stage added, by source, such as generator_one.
    # - dropped: how many it dropped, by reason, such as duplicate.
    # - set_aside: how many it held back untested, such as 5a-3's GIN and
    #   GiST candidates.
    # - out: how many went on.
    # - extra: counts that don't move items, such as untested atoms or 9c
    #   retries. They're kept, not summed.
    #
    # in and out are required. The rest default to none.
    #
    # Consistency. Every record must have in + added - dropped - set_aside
    # == out, or it's refused and nothing is stored. There's no separate
    # "close" step: each call records a whole run of the stage, so each one
    # must add up on its own. Adding records that add up gives one that adds
    # up too, so the stored sum always does.
    #
    # Accumulating. Each call to the enclave script is its own process, so
    # each record reads the entry, adds its counts, and writes it back.
    # Separate calls for the same stage and search add together. The driver
    # runs one call at a time. If two calls ever raced, both would read the
    # same entry and the later write would win, losing the other's counts.
    # The entry would still add up, since each write is atomic and whole.
    #
    # Trust boundary. Counts are shape-class data, so they may leave the
    # enclave, but only counts. Every count must be an Integer of zero or
    # more, and every name a Symbol that's a lowercase word (see
    # Protocol::Burndown::NAME). A value from the database comes back as a
    # String, so asking for Symbols catches one passed by mistake. A name
    # can't be told from a value that happens to be a lowercase word, so
    # callers name reasons and sources with their own constants, never with
    # anything read from a database. Reading the entry checks it the same
    # way, so a stored entry that isn't a burndown never gets out. Errors are
    # Burndown::Error. They name only the stage, when it's one of STAGES, and
    # the field, never a value or a key that was refused, and they have no
    # cause.
    module Burndown
      class Error < StandardError; end

      ENTRY = "burndown"

      FIELDS = %w[in added dropped set_aside out extra].freeze
      COUNTS = %w[in set_aside out].freeze
      BREAKDOWNS = %w[added dropped extra].freeze

      module_function

      # Adds one run of a stage to the burndown, for one search.
      def record(store, stage, search, **counts)
        stage = Input.stage(stage)
        search = Input.name(search, "search")
        new_record = Input.record(stage, counts)
        update(store) do |burndown|
          searches = burndown["stages"][stage] ||= {}
          searches[search] = searches.key?(search) ? Entry.add_records(searches[search], new_record) : new_record
        end
      end

      # Adds to the work totals, such as hypothetical_explains,
      # indexes_built, measurement_runs, and fixture_loads.
      def add_totals(store, **counts)
        counts = Input.breakdown(counts, "totals")
        update(store) { |burndown| burndown["totals"] = Entry.add_breakdowns(burndown["totals"], counts) }
      end

      # The burndown so far, with String keys, or an empty one.
      def read(store)
        return { "stages" => {}, "totals" => {} } unless store.entry?(ENTRY)

        data = store.read(ENTRY)
        return data if Entry.burndown?(data)

        raise Error, "the burndown entry in run #{store.run_id} isn't a burndown"
      end

      # The burndown message for Egress.serialize.
      def message(store)
        burndown = read(store)
        { type: :burndown, stages: burndown["stages"], totals: burndown["totals"] }
      end

      def update(store)
        burndown = read(store)
        yield burndown
        store.write(ENTRY, burndown)
        nil
      end

      private_class_method :update

      # Checks what callers pass in, which has Symbol names, and gives it
      # back with String ones, as the entry keeps it.
      module Input
        module_function

        def stage(stage)
          return stage if stage.instance_of?(String) && Protocol::Burndown::STAGES.include?(stage)

          raise Error, "the stage must be one of the README 15b stages"
        end

        def name(name, what)
          return name.name if name.instance_of?(Symbol) && Protocol::Burndown::NAME.match?(name.name)

          raise Error, "each name in #{what} must be a Symbol that's a lowercase word"
        end

        def count(count, what)
          return count if count.instance_of?(Integer) && count >= 0

          raise Error, "#{what} must be an Integer of zero or more"
        end

        # The record's counts with String keys and the defaults filled in,
        # if they're all counts and they add up.
        def record(stage, counts)
          check_fields(stage, counts)
          counts = counts.transform_keys(&:name)
          record = FIELDS.to_h do |field|
            given = counts.fetch(field) { default(stage, field) }
            [field, BREAKDOWNS.include?(field) ? breakdown(given, field) : count(given, field)]
          end
          return record if Entry.adds_up?(record)

          raise Error, "a #{stage} record's in + added - dropped - set_aside must equal out"
        end

        def check_fields(stage, counts)
          return if counts.each_key.all? { |key| key.instance_of?(Symbol) && FIELDS.include?(key.name) }

          raise Error, "a #{stage} record has a field that isn't one of #{FIELDS.join(", ")}"
        end

        def default(stage, field)
          return {} if BREAKDOWNS.include?(field)
          return 0 if field == "set_aside"

          raise Error, "a #{stage} record needs #{field}"
        end

        def breakdown(counts, what)
          raise Error, "#{what} must be a Hash of counts" unless counts.instance_of?(Hash)

          counts.to_h { |key, value| [name(key, what), count(value, what)] }
        end
      end

      # The entry as stored, with String names: checking it and adding to it.
      module Entry
        module_function

        def adds_up?(record)
          came = record["in"] + record["added"].values.sum
          came - record["dropped"].values.sum - record["set_aside"] == record["out"]
        end

        def add_records(old, new)
          FIELDS.to_h do |field|
            [field, BREAKDOWNS.include?(field) ? add_breakdowns(old[field], new[field]) : old[field] + new[field]]
          end
        end

        def add_breakdowns(old, new) = old.merge(new) { |_, a, b| a + b }

        # Whether data is a whole burndown: stages and totals, every stage
        # one of STAGES, every name a lowercase word, every count an Integer
        # of zero or more, and every record adding up.
        def burndown?(data)
          data.instance_of?(Hash) && data.keys.sort == %w[stages totals] &&
            names?(data["totals"]) { |count| count?(count) } &&
            data["stages"].instance_of?(Hash) &&
            data["stages"].all? do |stage, searches|
              Protocol::Burndown::STAGES.include?(stage) && names?(searches) { |r| record?(r) }
            end
        end

        def record?(record)
          record.instance_of?(Hash) && record.keys.sort == FIELDS.sort &&
            COUNTS.all? { |field| count?(record[field]) } &&
            BREAKDOWNS.all? { |field| names?(record[field]) { |count| count?(count) } } &&
            adds_up?(record)
        end

        # Whether hash is a Hash whose keys are lowercase-word Strings and
        # whose values pass the block.
        def names?(hash, &)
          hash.instance_of?(Hash) && hash.all? do |name, value|
            name.instance_of?(String) && Protocol::Burndown::NAME.match?(name) && yield(value)
          end
        end

        def count?(count) = count.instance_of?(Integer) && count >= 0
      end

      private_constant :Input, :Entry
    end
  end
end
