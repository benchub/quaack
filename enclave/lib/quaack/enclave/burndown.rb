# frozen_string_literal: true

require "quaack/protocol/burndown"
require_relative "store"

module Quaack
  module Enclave
    # The enclave script's side of DESIGN.md's burndown: per-stage counts
    # and work totals, kept in the governed store as each step runs, in one
    # entry named burndown.
    #
    #   Burndown.record(store, "index-dedupe", :original, in: 10, dropped: { duplicate: 2 }, set_aside: 1, out: 7)
    #   Burndown.add_totals(store, hypothetical_explains: 12)
    #   Burndown.read(store)
    #   # => { "stages" => { "index-dedupe" => { "original" => { "in" => 10, "added" => {},
    #   #                                                         "dropped" => { "duplicate" => 2 },
    #   #                                                         "set_aside" => 1, "out" => 7, "extra" => {} } } },
    #   #      "totals" => { "hypothetical_explains" => 12 } }
    #   Egress.serialize(Burndown.message(store))  # the burndown type on the whitelist
    #
    # Stages that have a result object record it through an adapter:
    #
    #   since = Burndown.record_dedupe(store, dedupe, search: :original)               # index-dedupe
    #   Burndown.record_single_candidate_test(store, report, search: :original)        # index-test
    #   Burndown.record_llm_round(store, stage: "llm-index-ideas", search: :original,  # llm-index-ideas
    #                             dedupe:, since:, report: llm_report)
    #
    # A stage is one of Protocol::Burndown::STAGES. A search is :original
    # for the original query, or a Symbol naming a rewrite, since index-dedupe
    # through index-rank run again for each rewrite in plan-pruning and
    # rewrite-index-ideas. A record's fields:
    #
    # - in: how many items came into the stage.
    # - added: how many the stage added, by source, such as generator_one.
    # - dropped: how many it dropped, by reason, such as duplicate.
    # - set_aside: how many it held back untested, such as index-dedupe's GIN and
    #   GiST candidates.
    # - out: how many went on.
    # - extra: counts that don't move items, such as untested atoms or vacuity-guard
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
      # The LLM rounds record_llm_round records.
      ROUNDS = %w[llm-index-ideas llm-index-refine].freeze

      FIELDS = Protocol::Burndown::FIELDS
      BREAKDOWNS = Protocol::Burndown::BREAKDOWNS

      module_function

      # Adds one run of a stage to the burndown, for one search.
      def record(store, stage, search, **counts) = add(store, [[stage, search, counts]], {})

      # Adds one run of each of several stages in one write, so a call that
      # dies never leaves some of them stored. records are [stage, search,
      # counts] triples, each as record takes them.
      def record_all(store, records) = add(store, records, {})

      # Adds to the work totals, such as hypothetical_explains,
      # indexes_built, measurement_runs, and fixture_loads.
      def add_totals(store, **counts) = add(store, [], counts)

      # Records the [stage, search, counts] triples and totals in one write,
      # as record_all and add_totals do, unless the burndown already has a
      # record of the first triple's stage for its search. A step that runs
      # once per search, then writes its marker, records this way first, so
      # a call that died before its marker and is run again counts nothing
      # twice.
      def record_once(store, records, totals: {})
        stage, search, = records.first
        searches = read(store)["stages"][Input.stage(stage)]
        add(store, records, totals) unless searches&.key?(Input.name(search, "search"))
      end

      # Records one Dedupe search as an index-dedupe run: in is every candidate it
      # considered, dropped is by Drop reason, set_aside is its GIN, GiST,
      # and SP-GiST candidates, and out is its proposals, which go on to
      # index-test. It returns the counts it recorded, for the since of the LLM
      # round that follows (see record_llm_round).
      def record_dedupe(store, dedupe, search:)
        record = dedupe_record(dedupe, search:)
        add(store, [record], {})
        record.last
      end

      # record_dedupe's [stage, search, counts], for record_all or record_once.
      def dedupe_record(dedupe, search:) = ["index-dedupe", search, dedupe_counts(dedupe)]

      # A Dedupe's counts as record_dedupe records them, such as the since
      # of the LLM round about to filter through it (see record_llm_round).
      def dedupe_counts(dedupe) = Adapters.dedupe_counts(dedupe)

      # Records a SingleCandidateTest report as an index-test run: in is every
      # candidate tested, out is the ones the planner used for some literal
      # set, and the rest are dropped as never_used or, if HypoPG wouldn't
      # create them, hypopg_refused. Each plan with a hypothetical index adds
      # one to the hypothetical_explains total. The baseline's plans have
      # none, so they don't count. set_aside is the unused candidates held
      # for index-build to build for real (IndexSearch's "set_aside"), which count
      # as set aside rather than never_used.
      def record_single_candidate_test(store, report, search:, set_aside: [])
        add(store, [single_candidate_test_record(report, search:, set_aside:)], tested_totals(report))
      end

      # record_single_candidate_test's [stage, search, counts], and its
      # totals, tested_totals, for record_all or record_once.
      def single_candidate_test_record(report, search:, set_aside: [])
        ["index-test", search, Adapters.tested_counts(report, set_aside)]
      end

      def tested_totals(report) = Adapters.tested_totals(report)

      # Records one LLM round, llm-index-ideas or llm-index-refine, as one record. A round filters
      # the LLM's candidates through the search's own Dedupe, which already
      # holds the mechanical proposals, and then tests what's left in index-test.
      # The two are a chain, so the round's record covers both:
      #
      # - in is 0, and added is { llm: the candidates the round filtered,
      #   and the ones it refused before filtering }.
      # - dropped holds the refused ones by rule, and the round's index-dedupe
      #   reasons and its index-test ones.
      # - set_aside is what the round's filtering set aside.
      # - out is what the planner used, from report.
      # - extra is the caller's, such as how many candidates fell short
      #   before llm-index-refine.
      #
      # refused is { rule: count } for the LLM's DDL that never reached the
      # Dedupe, such as too_many or unqualified_table (see GeneratorThree).
      #
      # since is the counts that the search's last record_dedupe or
      # record_llm_round returned, so only this round's filtering counts.
      # report must test exactly the candidates this round's filtering
      # kept, or the record won't add up and it's refused. It returns the
      # search's counts, for the since of the next round.
      def record_llm_round(store, stage:, search:, dedupe:, since:, report:, refused: {}, extra: {}) # rubocop:disable Metrics/ParameterLists
        raise Error, "an LLM round's stage must be llm-index-ideas or llm-index-refine" unless ROUNDS.include?(stage)

        counts = Adapters.dedupe_counts(dedupe)
        round = Adapters.round_counts(counts, Adapters.since(since), report)
        add(store, [[stage, search, Adapters.with_refused(round, refused).merge(extra:)]],
            Adapters.tested_totals(report))
        counts
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

      # Checks every record and total, then adds them all to the entry in
      # one write. records are [stage, search, counts] triples.
      def add(store, records, totals)
        records = records.map { |stage, search, counts| Input.stage_record(stage, search, counts) }
        totals = Input.breakdown(totals, "totals")
        burndown = read(store)
        records.each { |stage, search, record| Entry.add_record(burndown, stage, search, record) }
        burndown["totals"] = Entry.add_breakdowns(burndown["totals"], totals)
        store.write(ENTRY, burndown)
        nil
      end

      private_class_method :add

      # Turns stage results into counts for record.
      module Adapters
        module_function

        def dedupe_counts(dedupe)
          { in: dedupe.considered, dropped: dedupe.drops.map(&:reason).tally,
            set_aside: dedupe.set_aside.size, out: dedupe.proposals.size }
        end

        def tested_counts(report, set_aside = [])
          results = report.results
          used = results.count(&:used?)
          refused = results.count(&:refusal)
          held = held(results, set_aside)
          dropped = { never_used: results.size - used - refused - held, hypopg_refused: refused }
          { in: results.size, dropped: dropped.reject { |_, n| n.zero? }, set_aside: held, out: used }
        end

        def held(results, set_aside) = results.count { !it.used? && !it.refusal && set_aside.include?(it.candidate) }

        def tested_totals(report) = { hypothetical_explains: report.results.sum { it.plans.size } }

        def round_counts(counts, since, report)
          tested = tested_counts(report)
          { in: 0, added: { llm: counts[:in] - since[:in] },
            dropped: drops_since(counts[:dropped], since[:dropped]).merge(tested[:dropped]),
            set_aside: counts[:set_aside] - since[:set_aside], out: tested[:out] }
        end

        # The round's counts with the refused DDL added by the LLM and
        # dropped by rule.
        def with_refused(round, refused)
          refused = Input.breakdown(refused, "dropped")
          round.merge(added: { llm: round[:added][:llm] + refused.values.sum },
                      dropped: round[:dropped].merge(refused.transform_keys(&:to_sym)))
        end

        # Each reason's drops since the earlier ones, leaving out a reason
        # with none.
        def drops_since(drops, earlier)
          drops.to_h { |reason, n| [reason, n - earlier.fetch(reason, 0)] }.reject { |_, n| n.zero? }
        end

        # since, if it's counts as dedupe_counts gives them.
        def since(since)
          return since if since.is_a?(Hash) && since.keys.sort == %i[dropped in out set_aside] &&
                          %i[in set_aside out].all? { count?(since[it]) } && drops?(since[:dropped])

          raise Error, "since must be the counts an earlier record_dedupe or record_llm_round returned"
        end

        def drops?(drops) = drops.is_a?(Hash) && drops.all? { |reason, n| reason.is_a?(Symbol) && count?(n) }

        def count?(count) = count.is_a?(Integer) && count >= 0
      end

      # Checks what callers pass in, which has Symbol names, and gives it
      # back with String ones, as the entry keeps it.
      module Input
        module_function

        # [stage, search, record] with String names, as the entry keeps them.
        def stage_record(stage, search, counts)
          stage = stage(stage)
          [stage, name(search, "search"), record(stage, counts)]
        end

        def stage(stage)
          # The protocol's own String goes in the entry, never the caller's.
          index = Protocol::Burndown::STAGES.index(stage)
          return Protocol::Burndown::STAGES[index] if index

          raise Error, "the stage must be one of the DESIGN.md burndown stages"
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
          return record if Protocol::Burndown.adds_up?(record)

          raise Error, "the #{stage} record's in + added - dropped - set_aside must equal out"
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

        def add_record(burndown, stage, search, record)
          searches = burndown["stages"][stage] ||= {}
          searches[search] = searches.key?(search) ? add_records(searches[search], record) : record
        end

        def add_records(old, new)
          FIELDS.to_h do |field|
            [field, BREAKDOWNS.include?(field) ? add_breakdowns(old[field], new[field]) : old[field] + new[field]]
          end
        end

        def add_breakdowns(old, new) = old.merge(new) { |_, a, b| a + b }

        # Whether data is a whole burndown, stages and totals and nothing
        # else. Protocol::Burndown.valid? is the check, the same one egress
        # makes.
        def burndown?(data)
          data.is_a?(Hash) && data.keys.sort == %w[stages totals] &&
            Protocol::Burndown.valid?(stages: data["stages"], totals: data["totals"])
        end
      end

      private_constant :Input, :Entry, :Adapters
    end
  end
end
