# frozen_string_literal: true

require_relative "index_build"
require_relative "literal_set"
require_relative "measurement"
require_relative "redaction"

module Quaack
  module Enclave
    # DESIGN.md's index-share (task 20261017-2): pairs each candidate with
    # the indexes that made another candidate's ranking, so an index
    # proposed for one candidate is measured with the others too.
    #
    #   IndexShare.combinations(connection, store, build, { "original" => sql, "rewrite_1" => sql })
    #   # => { "original:shared:1" => [name], "rewrite_1:shared:1" => [name] }
    #
    # build is index_build as IndexBuild has built it ("indexes" and
    # "combinations", by built name). searches are the candidates that go
    # on to measurement, each with the SQL it runs. A candidate's pool is
    # every index in another candidate's ranked combinations (its top
    # entries and its combination, never its set-aside ones), each on its
    # own, less any index in the candidate's own combinations. Each one is
    # shown alone, and a plain EXPLAIN of the candidate on the slow values
    # keeps it only if the plan uses it, so it's on a table the candidate
    # reads and could change its blocks. Of those kept, choose keeps the
    # ones the planner prices lowest against the candidate's plan with no
    # new index: PER_CANDIDATE for each candidate, and TOTAL in all. Every
    # built index is hidden again after.
    #
    # Nothing here is sent: the labels are QUAACK's own, and the names are
    # built names index_build already holds.
    module IndexShare
      PER_CANDIDATE = 3
      TOTAL = 42
      RANKED = /\A(?<search>[^:]+):(?:top:[1-9]\d*|combination)\z/

      module_function

      def combinations(connection, store, build, searches)
        slow = LiteralSet.load(store).sets.to_h.fetch(Measurement::TIMED_SET)
        scored = searches.flat_map do |search, sql|
          score(connection, build, search, pool(build["combinations"], search, searches.keys),
                Redaction.binding(sql, slow))
        end
        label(choose(scored), searches.keys)
      ensure
        IndexBuild.hide_all(connection, build)
      end

      # The built names search could share, in the order the other
      # candidates ranked them.
      def pool(combinations, search, searches)
        ranked = combinations.select do |key, _|
          (owner = RANKED.match(key)&.[](:search)) && owner != search && searches.include?(owner)
        end
        own = combinations.select { |key, _| key.start_with?("#{search}:") }.values.flatten
        ranked.values.flatten.uniq - own
      end

      # [{ "search", "name", "ratio" }] for each of names the plan of bound
      # uses, ratio its estimated cost over the cost with no new index.
      def score(connection, build, search, names, bound)
        return [] if names.empty?

        params = Measurement.params(connection, bound)
        bare = cost(explain(connection, build, [], bound.sql, params))
        names.filter_map do |name|
          plan = explain(connection, build, [name], bound.sql, params)
          next unless IndexBuild.index_names(plan).include?(name)

          { "search" => search, "name" => name, "ratio" => bare.positive? ? cost(plan) / bare : 1.0 }
        end
      end

      # The scored pairs kept: each candidate's PER_CANDIDATE lowest ratios,
      # then the TOTAL lowest of those. Ties keep the order they came in.
      def choose(scored)
        order = scored.each_with_index.to_h
        lowest = ->(pairs, n) { pairs.sort_by { [it["ratio"], order[it]] }.first(n) }
        lowest.call(scored.group_by { it["search"] }.values.flat_map { lowest.call(it, PER_CANDIDATE) }, TOTAL)
      end

      # The chosen pairs as combinations, "<search>:shared:<n>" in searches'
      # order, numbered from the lowest ratio up.
      def label(chosen, searches)
        searches.flat_map do |search|
          chosen.select { it["search"] == search }
                .each_with_index.map { |pair, i| ["#{search}:shared:#{i + 1}", [pair["name"]]] }
        end.to_h
      end

      # The plain EXPLAIN of sql with only visible shown among build's indexes.
      def explain(connection, build, visible, sql, params)
        schemas = IndexBuild.schemas(build)
        IndexBuild.hide(connection, build["indexes"].keys - visible, schemas:)
        IndexBuild.set_valid(connection, visible, true, schemas:)
        IndexBuild.parse_plan(connection.exec_params("EXPLAIN (FORMAT JSON) #{sql}", params).getvalue(0, 0))
      end

      def cost(plan) = plan[0]["Plan"]["Total Cost"].to_f
    end
  end
end
