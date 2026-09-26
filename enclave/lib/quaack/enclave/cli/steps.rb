# frozen_string_literal: true

require_relative "step"
require_relative "../steps/version"
require_relative "../steps/intake"
require_relative "../steps/teardown"
require_relative "../steps/inventory"
require_relative "../steps/run_server"
require_relative "../steps/qualify"
require_relative "../steps/schema_dump"
require_relative "../steps/statistics"
require_relative "../steps/volatility"
require_relative "../steps/classify"
require_relative "../steps/redact"
require_relative "../steps/literals"
require_relative "../steps/anchor"
require_relative "../steps/racetrack_setup"
require_relative "../steps/index_search"
require_relative "../steps/index_payload"
require_relative "../steps/index_test"

module Quaack
  module Enclave
    class CLI
      # Each subcommand and its step. To add a step, require its file above
      # and add one line here. The requires are written out, never built
      # from argv or a directory listing, so argv can't pick a file to load.
      STEPS = {
        "version" => Step.new(handler: Steps::Version),
        "intake" => Step.new(handler: Steps::Intake, new_run: true, options: Steps::Intake::OPTIONS,
                             required: Steps::Intake::REQUIRED),
        "teardown" => Step.new(handler: Steps::Teardown, run_id: true),
        "inventory" => Step.new(handler: Steps::Inventory, run: true),
        "run-server" => Step.new(handler: Steps::RunServer, run: true, options: Steps::RunServer::OPTIONS,
                                 required: Steps::RunServer::REQUIRED),
        "qualify" => Step.new(handler: Steps::Qualify, run: true),
        "schema-dump" => Step.new(handler: Steps::SchemaDump, run: true),
        "statistics" => Step.new(handler: Steps::Statistics, run: true),
        "volatility" => Step.new(handler: Steps::Volatility, run: true),
        "classify" => Step.new(handler: Steps::Classify, run: true),
        "redact" => Step.new(handler: Steps::Redact, run: true),
        "literals" => Step.new(handler: Steps::Literals, run: true),
        "anchor" => Step.new(handler: Steps::Anchor, run: true),
        "racetrack-setup" => Step.new(handler: Steps::RacetrackSetup, run: true),
        "index-search" => Step.new(handler: Steps::IndexSearch, run: true, options: Steps::IndexSearch::OPTIONS),
        "index-payload" => Step.new(handler: Steps::IndexPayload, run: true, options: Steps::IndexPayload::OPTIONS),
        "index-test" => Step.new(handler: Steps::IndexTest, run: true, input: true, options: Steps::IndexTest::OPTIONS)
      }.freeze
    end
  end
end
