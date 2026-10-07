# frozen_string_literal: true

require_relative "../candidate_ddl_redaction"
require_relative "../index_build"
require_relative "../index_candidate"
require_relative "../rewrite_burndown"
require_relative "../run_server"

module Quaack
  module Enclave
    module Steps
      # `quaacks index-build --run <run ID> [--index <n>]` (DESIGN.md's
      # index-build). Without --index, it builds and hides
      # every ranked and set-aside index on the racetrack (IndexBuild) and
      # writes index_build. Before each index it sends an
      # index_build_progress line: its position, the total, and its DDL.
      # Its only other line is DONE. Before it writes index_build, it records
      # rewrite-index-ideas' burndown and the indexes it built
      # (RewriteBurndown.record_build).
      #
      # With --index n, it builds only the nth index (build_one),
      # sends its one progress line, and writes nothing else. Past the last
      # index it sends nothing. The driver calls it once per index, so each
      # gets its own timeout, then calls without --index, which skips them
      # all as built. An --index that isn't a positive whole number is
      # refused as index_build_bad_index.
      #
      # Trust boundary. The stored DDL can hold a literal, so the progress
      # line's DDL goes through CandidateDdlRedaction, named with the
      # index's quaack_ name, which the report carries too.
      module IndexBuild
        OPTIONS = { "index" => :value }.freeze

        class Error < StandardError
          attr_reader :rule

          def initialize(rule)
            @rule = rule
            super
          end
        end

        module_function

        def call(store:, progress:, options:, **)
          number = number(options["index"])
          redaction = CandidateDdlRedaction.new(store.read("classification")["outbound_statistics"])
          connection = Enclave::RunServer.connect(store, :racetrack)
          starting = lambda { |index, total, ddl|
            progress.call(type: :index_build_progress, index:, total:, ddl: shown(redaction, ddl))
          }
          build(store, connection, number, starting)
          []
        ensure
          connection&.close
        end

        def build(store, connection, number, starting)
          return build_one(store, connection, number, starting) if number

          built = ->(indexes) { RewriteBurndown.record_build(store, indexes.size) }
          Enclave::IndexBuild.build(store, connection, starting:, built:)
        end

        # Builds only the number-th (1-based) of IndexBuild.build's indexes,
        # in the same order, telling starting first. It writes nothing, and
        # does nothing past the last index. An index already there is
        # skipped (IndexBuild.create).
        def build_one(store, connection, number, starting)
          ddls = Enclave::IndexBuild.combinations(store).values.flatten.uniq
          ddl = ddls[number - 1] or return

          Enclave::IndexBuild::SETTINGS.each { |k, v| connection.exec("SET #{k} = '#{v}'") }
          starting.call(number, ddls.size, ddl)
          Enclave::IndexBuild.create(connection, Enclave::IndexBuild.name(ddl), ddl)
        end

        # --index as an Integer, or nil without one.
        def number(value)
          return if value.nil?
          raise Error, "index_build_bad_index" unless value.match?(/\A[1-9][0-9]*\z/)

          value.to_i
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
