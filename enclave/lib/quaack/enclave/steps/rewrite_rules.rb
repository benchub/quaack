# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_rules"
require_relative "../rewrite_rules/catalog"
require_relative "rewrite_check"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-rules --run <run ID>` (DESIGN.md 6c): runs the
      # mechanical rewrite rules on the redacted query and stores the
      # rewrites that pass rewrite-check's checks. It takes no input and
      # needs no LLM.
      #
      # The generator (Enclave::RewriteRules) reads the catalog on the
      # racetrack connection, where 6b's AssumptionCheck reads it too. Each
      # rewrite it gives then goes through RewriteCheck.check, the code
      # `quaacks rewrite-check` runs, so in the same order: the inbound
      # check, 6b, step 8's structural discards, and clock anchoring. A
      # rule's rewrite gets no pass for being QUAACK's own.
      #
      # A survivor is stored as rewrite_<n>, in RewriteCheck's store format,
      # with "source" => "rule" and "rules" => the names of the rules
      # applied, in order. Its "transformation" is those rules' descriptions,
      # in order, and its "assumptions" are the ones the rules stated. Its
      # counts go to the step 8 burndown as rewrite-check's do.
      #
      # It writes the rewrite_rules_applied marker, which `quaacks status`
      # reports, so a resumed run doesn't run the rules again. The marker
      # holds what the generator dropped: "duplicates" and "over_cap".
      #
      # Its only output is one rewrite_outcome per rewrite, as rewrite-check
      # sends: index, outcome, rule (why it was rejected, one of the check's
      # constants), rewrite (the entry name), and warnings, always [].
      # Nothing of the SQL or the literals goes out.
      #
      # rules is there for specs, to give the step fake rules.
      module RewriteRules
        module_function

        def call(store:, rules: Enclave::RewriteRules::RULES, **)
          generated = nil
          outcomes = RewriteCheck.check(store, source: "rule") do |connection|
            generated = generate(store, connection, rules)
            generated.rewrites.map { rewrite(it) }
          end
          store.write("rewrite_rules_applied", "duplicates" => generated.duplicates, "over_cap" => generated.over_cap)
          outcomes
        end

        def generate(store, connection, rules)
          parse = PgQuery.parse(store.read("redacted_query"))
          Enclave::RewriteRules.generate(parse, Enclave::RewriteRules::Catalog.new(connection), rules:)
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
