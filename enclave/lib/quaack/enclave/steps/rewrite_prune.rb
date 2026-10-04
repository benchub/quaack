# frozen_string_literal: true

require_relative "../rewrite_entry"
require_relative "../burndown"
require_relative "../index_store"
require_relative "../literal_set"
require_relative "../run_server"
require_relative "../three_configuration_pruning"
require_relative "index_search"

module Quaack
  module Enclave
    module Steps
      # `quaacks rewrite-prune --run <run ID> --search rewrite_<n>` (DESIGN.md
      # step 8's three-configuration pruning): whether a rewrite can't run
      # any differently from the original, by ThreeConfigurationPruning
      # against index_ranking_original's top three and the rewrite's own
      # (index_ranking_rewrite_<n>).
      #
      # It refuses a search that isn't a stored rewrite
      # (rewrite_prune_unknown_search) and one missing either ranking
      # (rewrite_prune_no_ranking), before connecting. It writes
      # rewrite_pruned_<n> => { "discarded" => Boolean }, and adds to the
      # step 8 burndown under the search pruning: in 1, dropped same_plans.
      # Its only line is DONE.
      module RewritePrune
        OPTIONS = { "search" => :value }.freeze
        REQUIRED = %w[search].freeze

        class Error < IndexSearch::Error; end

        module_function

        def call(store:, options:, **)
          search = check(store, options.fetch("search"))
          connection = Enclave::RunServer.connect(store, :racetrack)
          discarded = discard?(store, connection, search)
          store.write("rewrite_pruned_#{search.delete_prefix("rewrite_")}", "discarded" => discarded)
          Burndown.record(store, "plan-pruning", :pruning, in: 1, dropped: { same_plans: discarded ? 1 : 0 },
                                                           out: discarded ? 0 : 1)
          []
        ensure
          connection&.close
        end

        def check(store, search)
          unless search.is_a?(String) && search != "original" && IndexSearch.search?(store, search)
            raise Error, "rewrite_prune_unknown_search"
          end

          rankings = ["original", search].map { "index_ranking_#{it}" }
          raise Error, "rewrite_prune_no_ranking" unless rankings.all? { store.entry?(it) }

          search
        end

        def discard?(store, connection, search)
          original = store.read("anchored_query")
          rewrite = RewriteEntry.run_sql(store.read(search))
          ThreeConfigurationPruning.discard?(
            connection, original:, rewrite:, literal_sets: IndexSearch.values(LiteralSet.load(store).sets),
                        top: { original: top(store, "original"), rewrite: top(store, search) },
                        types: { original: IndexSearch.types(store, original),
                                 rewrite: IndexSearch.types(store, rewrite) }
          )
        end

        # The search's top three, as candidates: each ranked DDL looked up
        # among the index search's tested candidates.
        def top(store, search)
          entry = store.read("index_search_#{search}")
          candidates = (entry["results"] + (entry["llm_results"] || [])).map { IndexStore.candidate(it["candidate"]) }
          store.read("index_ranking_#{search}")["top"].flat_map do |ranked|
            ranked["ddl"].map { |ddl| candidates.find { it.to_ddl == ddl } }
          end.compact
        end
      end
    end
  end
end
