# frozen_string_literal: true

require_relative "../index_build"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-build --run <run ID>` (README 12a): builds and hides
      # every ranked and set-aside index on the racetrack (IndexBuild) and
      # writes index_build. Its only line is DONE.
      module IndexBuild
        module_function

        def call(store:, **)
          connection = Enclave::RunServer.connect(store, :racetrack)
          Enclave::IndexBuild.build(store, connection)
          []
        ensure
          connection&.close
        end
      end
    end
  end
end
