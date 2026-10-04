# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_build"
require_relative "../index_candidate"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-build --run <run ID>` (DESIGN.md's index-build): builds and hides
      # every ranked and set-aside index on the racetrack (IndexBuild) and
      # writes index_build. Before each index it sends an
      # index_build_progress line: its position, the total, and its DDL.
      # Its only other line is DONE.
      #
      # Trust boundary. The stored DDL can hold a literal, so the progress
      # line's DDL goes through CandidateDdlRedaction, named with the
      # index's quaack_ name, which the report carries too.
      module IndexBuild
        module_function

        def call(store:, progress:, **)
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          connection = Enclave::RunServer.connect(store, :racetrack)
          Enclave::IndexBuild.build(store, connection, starting: lambda { |index, total, ddl|
            progress.call(type: :index_build_progress, index:, total:, ddl: shown(redaction, ddl))
          })
          []
        ensure
          connection&.close
        end

        # ddl through redaction, with the index's name, or nil if it can't
        # be read as a candidate.
        def shown(redaction, ddl)
          candidate = IndexCandidate.from_ddl(ddl, sources: [:llm]) or return
          redaction.ddl(candidate).sub(/\ACREATE INDEX ON /, "CREATE INDEX #{Enclave::IndexBuild.name(ddl)} ON ")
        end
      end
    end
  end
end
