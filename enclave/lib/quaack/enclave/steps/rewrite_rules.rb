# frozen_string_literal: true

require "pg_query"
require_relative "../burndown"
require_relative "../rewrite_rules"
require_relative "../rewrite_rules/catalog"
require_relative "rewrite_check"
require "quaack/protocol/step_counts"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-rules --run <run ID>` (DESIGN.md's rewrite-rules): runs the
      # mechanical rewrite rules on the redacted query and stores the
      # rewrites that pass rewrite-check's checks. It takes no input and
      # needs no LLM.
      #
      # The generator (Enclave::RewriteRules) reads the catalog on the
      # racetrack connection, where assumption-check's AssumptionCheck reads it too. Each
      # rewrite it gives then goes through RewriteCheck.check, the code
      # `quaacks rewrite-check` runs, so in the same order: the inbound
      # check, assumption-check, structural-discard, and clock anchoring. A
      # rule's rewrite gets no pass for being QUAACK's own.
      #
      # A survivor is stored as rewrite_<n>, in RewriteCheck's store format,
      # with "source" => "rule" and "rules" => the names of the rules
      # applied, in order. Its "transformation" is those rules' descriptions,
      # in order, and its "assumptions" are the ones the rules stated. A
      # rewrite the checks reject is counted in rewrite-rules' failed_checks
      # only, not in plan-pruning; a survivor enters plan-pruning in
      # rewrite-prune.
      #
      # It records the rewrite-rules burndown stage (DESIGN.md's burndown), search rewrites:
      # added is every result the generator counted, by the name of the last
      # rule applied; dropped is duplicate, over_cap, and failed_checks, the
      # ones any of the checks above rejected; out is the survivors. A rule's
      # name is QUAACK's own constant, never anything read from the query.
      #
      # It writes the rewrite_rules_applied marker, which `quaacks status`
      # reports, so a resumed run doesn't run the rules again. The marker
      # holds what the generator dropped: "duplicates" and "over_cap".
      #
      # Running it again changes nothing, so a call that died before its
      # marker can be repeated. The writes go in this order: each survivor,
      # then the rewrite-rules burndown record, then the
      # marker. A survivor an earlier call stored is found again by its SQL
      # and kept, not stored twice (stored, and RewriteCheck.check). The
      # burndown is recorded only if it holds no rewrite-rules record yet.
      #
      # Its output is one rewrite_outcome per rewrite, as rewrite-check
      # sends: index, outcome, rule (why it was rejected, one of the check's
      # constants), rewrite (the entry name), and warnings, always []. Then
      # one step_counts whose rules are the names of the rules applied in
      # any rewrite the generator gave, in Protocol::StepCounts::RULE_NAMES
      # order. Only a name on that list goes out. Nothing of the SQL or the
      # literals goes out.
      #
      # rules is there for specs, to give the step fake rules.
      module RewriteRules
        STAGE = "rewrite-rules"

        module_function

        def call(store:, rules: Enclave::RewriteRules::RULES, **)
          generated = nil
          recorded = Burndown.read(store)["stages"].key?(STAGE)
          also = ->(outcomes) { [[STAGE, :rewrites, counts(generated, outcomes)]] unless recorded }
          outcomes = RewriteCheck.check(store, source: "rule", also:) do |connection|
            generated = generate(store, connection, rules)
            generated.rewrites.map { rewrite(it) }
          end
          store.write("rewrite_rules_applied", "duplicates" => generated.duplicates, "over_cap" => generated.over_cap)
          [*outcomes, { type: :step_counts, rules: fired(generated) }]
        end

        # The shared list's names of the rules applied in any rewrite the
        # generator gave.
        def fired(generated)
          applied = generated.rewrites.flat_map { it.rules.map(&:name) }
          Protocol::StepCounts::RULE_NAMES.select { applied.include?(it) }
        end

        # The rewrite-rules burndown record's counts.
        def counts(generated, outcomes)
          accepted = outcomes.count { it[:outcome] == :accepted }
          { in: 0, added: generated.made.transform_keys(&:to_sym), out: accepted,
            dropped: { duplicate: generated.duplicates, over_cap: generated.over_cap,
                       failed_checks: outcomes.size - accepted } }
        end

        def generate(store, connection, rules)
          parse = PgQuery.parse(store.read("redacted_query"))
          literals = Enclave::RewriteRules::Literals.new(connection, store.read("placeholder_map"))
          Enclave::RewriteRules.generate(parse, Enclave::RewriteRules::Catalog.new(connection), literals, rules:)
        end

        # A generated candidate as RewriteCheck takes a rewrite, with its
        # rule names.
        def rewrite(candidate)
          { "sql" => candidate.sql, "transformation" => candidate.rules.map(&:description).join(" "),
            "assumptions" => candidate.assumptions, "rules" => candidate.rules.map(&:name) }
        end
      end
    end
  end
end
