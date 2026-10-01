# frozen_string_literal: true

require_relative "../index_build"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-build --run <run ID>` (DESIGN.md 12a): builds and hides
      # every ranked and set-aside index on the racetrack (IndexBuild) and
      # writes index_build. Before each index it sends an
      # index_build_progress line, with the index's DDL through
      # CandidateDdlRedaction. Its only other line is DONE.
      module IndexBuild
        module_function

        def call(store:, progress:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          Enclave::IndexBuild.build(store, connection, progress:)
          []
        ensure
          connection&.close
        end
      end
    end
  end
end
