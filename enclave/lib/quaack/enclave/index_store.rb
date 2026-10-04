# frozen_string_literal: true

require_relative "dedupe"
require_relative "index_candidate"
require_relative "table_name"

module Quaack
  module Enclave
    # IndexCandidate and Dedupe as plain data for the governed store, and
    # back, so one enclave call can save an index search and a later one go
    # on with it (DESIGN.md's index-search: llm-index-ideas filters the LLM's candidates through the
    # same index-dedupe search as the mechanical ones).
    #
    #   IndexStore.candidate(IndexStore.candidate_plain(c)) == c  # sources too
    #   IndexStore.dedupe(IndexStore.dedupe_plain(search), statistics:, low_cardinality:)
    #
    # A Dedupe's statistics and low-cardinality columns aren't saved: they're
    # the run's own statistics and classification entries, which the caller
    # loads again. Everything else is: proposals, set-aside candidates,
    # drops with what covered each, and the count considered.
    #
    # Trust boundary: a partial candidate's predicate and a key expression
    # can hold a real literal, so the plain data is value-class. It goes to
    # the store only, never through egress.
    module IndexStore
      module_function

      def candidate_plain(candidate)
        { "table" => { "schema" => candidate.table.schema, "name" => candidate.table.name },
          "key" => candidate.key.map { key_plain(it) },
          "include" => candidate.include, "access_method" => candidate.access_method.to_s,
          "predicate" => candidate.predicate, "unique" => candidate.unique,
          "sources" => candidate.sources.map(&:to_s).sort }
      end

      def candidate(plain)
        IndexCandidate.new(
          table: TableName.new(schema: plain["table"]["schema"], name: plain["table"]["name"]),
          key: plain["key"].map { key_column(it) }, include: plain["include"],
          access_method: plain["access_method"], predicate: plain["predicate"], unique: plain["unique"],
          sources: plain["sources"]
        )
      end

      def dedupe_plain(search)
        { "proposals" => search.proposals.map { candidate_plain(it) },
          "set_aside" => search.set_aside.map { candidate_plain(it) },
          "drops" => search.drops.map { drop_plain(it) },
          "considered" => search.considered }
      end

      def dedupe(plain, statistics:, low_cardinality:)
        Dedupe.restore(statistics:, low_cardinality:,
                       proposals: plain["proposals"].map { candidate(it) },
                       set_aside: plain["set_aside"].map { candidate(it) },
                       drops: plain["drops"].map { drop(it) }, considered: plain["considered"])
      end

      def key_plain(column)
        { "name" => column.name, "expression" => column.expression, "direction" => column.direction.to_s,
          "nulls" => column.nulls.to_s, "opclass" => column.opclass, "collation" => column.collation }
      end

      def key_column(plain)
        IndexCandidate::KeyColumn.new(name: plain["name"], expression: plain["expression"],
                                      direction: plain["direction"], nulls: plain["nulls"],
                                      opclass: plain["opclass"], collation: plain["collation"])
      end

      # covered_by is nil, an existing index (its name and definition), or
      # the earlier proposal.
      def drop_plain(drop)
        covered = drop.covered_by
        covered_plain =
          case covered
          when Dedupe::ExistingIndex then { "existing" => covered.name, "definition" => candidate_plain(covered.definition) }
          when IndexCandidate then { "proposal" => candidate_plain(covered) }
          end
        { "candidate" => candidate_plain(drop.candidate), "reason" => drop.reason.to_s, "covered_by" => covered_plain }
      end

      def drop(plain)
        covered = plain["covered_by"]
        covered_by =
          if covered.nil? then nil
          elsif covered.key?("existing")
            Dedupe::ExistingIndex.new(name: covered["existing"], definition: candidate(covered["definition"]))
          else candidate(covered["proposal"])
          end
        Dedupe::Drop.new(candidate: candidate(plain["candidate"]), reason: plain["reason"].to_sym, covered_by:)
      end
    end
  end
end
