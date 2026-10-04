# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "rewrite_rules/cte_hoist_dedupe"
require_relative "rewrite_rules/distinct_join_to_exists"
require_relative "rewrite_rules/implied_predicate_removal"
require_relative "rewrite_rules/key_in_self_join"
require_relative "rewrite_rules/literals"
require_relative "rewrite_rules/not_in_to_not_exists"
require_relative "rewrite_rules/or_to_union"
require_relative "rewrite_rules/transitive_predicate_copy"
require_relative "rewrite_rules/union_outer_filter_removal"

module Quaack
  module Enclave
    # DESIGN.md 6c: the mechanical rewrite rules, and the generator that
    # chains them.
    #
    #   generated = RewriteRules.generate(PgQuery.parse(sql), RewriteRules::Catalog.new(connection))
    #   generated.rewrites   # => [Candidate(sql:, parse:, rules: [rule, ...], assumptions: [...]), ...]
    #
    # A rule is one object that answers three things:
    #
    #   name                      its name, such as "key_in_self_join"
    #   description               one sentence saying what it does
    #   rewrites(parse, catalog)  zero or more Rewrite(tree:, assumptions:)
    #
    # parse is a PgQuery::ParseResult, which the rule must not change, and
    # catalog the catalog facts (see Catalog). Each Rewrite's tree is the
    # rewritten query's PgQuery::ParseResult, and its assumptions are the
    # catalog facts it relies on, in 6b's vocabulary (see
    # RewriteAssumptions). A rule fires only when the catalog proves them. A
    # rule's name and description are QUAACK's own constants, never anything
    # read from the query, so they're shape-class data.
    #
    # The generator knows nothing about any one rule: it holds RULES. To add
    # a rule, add its file under rewrite_rules/, require it above, and add
    # one line to RULES.
    #
    # Rules chain. Every rule runs on the original, in list order. Then
    # every rule runs on each of those results, in the order they were made,
    # so every one-rule result comes before any two-rule one. Nothing goes
    # deeper than DEPTH rules. A rule may run on its own output, which is
    # how two matches in one query both get rewritten. A result whose
    # deparsed SQL is the original's, or was already produced, is dropped
    # and counted in duplicates. So is one pg_query can't deparse faithfully
    # (see Deparse), though it isn't counted. The first MAX results are
    # kept, and over_cap counts the rest. made counts every result that was
    # kept, a duplicate, or over the cap, by the name of the last rule
    # applied to make it, for the 6c burndown (DESIGN.md 15b).
    #
    # A Candidate's sql is its tree deparsed, parse that SQL's own parse,
    # rules the rules applied, in order, and assumptions those of every rule
    # applied, each once.
    module RewriteRules
      Rewrite = Data.define(:tree, :assumptions)
      Candidate = Data.define(:sql, :parse, :rules, :assumptions)
      Generated = Data.define(:rewrites, :duplicates, :over_cap, :made)
      # A result whose SQL was already produced, and the rule that made it.
      Duplicate = Data.define(:rule)

      RULES = [
        ImpliedPredicateRemoval.new,
        TransitivePredicateCopy.new,
        KeyInSelfJoin.new,
        OrToUnion.new,
        NotInToNotExists.new,
        DistinctJoinToExists.new,
        CteHoistDedupe.new,
        UnionOuterFilterRemoval.new
      ].freeze

      DEPTH = 2
      MAX = 10

      module_function

      def generate(parse, catalog, literals = nil, rules: RULES)
        original = Candidate.new(sql: Deparse.faithfully(parse.tree), parse:, rules: [], assumptions: [])
        made = chain([original], rules, catalog, literals, { original.sql => true })
        kept = made.grep(Candidate)
        Generated.new(rewrites: kept.first(MAX), duplicates: made.size - kept.size, over_cap: [kept.size - MAX, 0].max,
                      made: tally(made))
      end

      # How many of made, Candidates and Duplicates, each rule made, by the
      # name of the last rule applied.
      def tally(made) = made.map { (it.is_a?(Candidate) ? it.rules.last : it.rule).name }.tally

      # Every result DEPTH rounds of the rules make of from, shallowest
      # first, with a Duplicate in place of each one already seen.
      def chain(from, rules, catalog, literals, seen)
        Array.new(DEPTH) { from = step(from, rules, catalog, literals, seen) }.flatten
      end

      # Every rule's results for every candidate in from, with a Duplicate
      # in place of each one already seen.
      def step(from, rules, catalog, literals, seen)
        from.grep(Candidate).flat_map do |candidate|
          rules.flat_map do |rule|
            rule.rewrites(candidate.parse, catalog, literals).filter_map { chained(candidate, rule, it, seen) }
          end
        end
      end

      # The candidate that rule's rewrite makes of from, a Duplicate if its
      # SQL was already produced, or nil if it doesn't deparse.
      def chained(from, rule, rewrite, seen)
        parse = Deparse.faithful_parse(rewrite.tree)
        return Duplicate.new(rule:) if seen.key?(parse.query)

        seen[parse.query] = true
        Candidate.new(sql: parse.query, parse:, rules: from.rules + [rule],
                      assumptions: (from.assumptions + rewrite.assumptions).uniq)
      rescue Deparse::Error
        nil
      end
    end
  end
end
