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
require_relative "../steps/arena_setup"
require_relative "../steps/index_search"
require_relative "../steps/index_feedback"
require_relative "../steps/index_rank"
require_relative "../steps/status"
require_relative "../steps/index_payload"
require_relative "../steps/index_test"
require_relative "../steps/rewrite_payload"
require_relative "../steps/rewrite_check"
require_relative "../steps/rewrite_rules"
require_relative "../steps/rewrite_prune"
require_relative "../steps/counterexamples"
require_relative "../steps/index_build"
require_relative "../steps/baseline"
require_relative "../steps/index_baseline"
require_relative "../steps/candidate_runs"
require_relative "../steps/minimax"
require_relative "../steps/result_comparison"
require_relative "../steps/selection"
require_relative "../steps/report_payload"

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
        "arena-setup" => Step.new(handler: Steps::ArenaSetup, run: true),
        "index-search" => Step.new(handler: Steps::IndexSearch, run: true, options: Steps::IndexSearch::OPTIONS),
        "index-payload" => Step.new(handler: Steps::IndexPayload, run: true, options: Steps::IndexPayload::OPTIONS),
        "index-feedback" => Step.new(handler: Steps::IndexFeedback, run: true,
                                     options: Steps::IndexFeedback::OPTIONS),
        "index-rank" => Step.new(handler: Steps::IndexRank, run: true, options: Steps::IndexRank::OPTIONS),
        "status" => Step.new(handler: Steps::Status, run: true),
        "index-test" => Step.new(handler: Steps::IndexTest, run: true, input: true, options: Steps::IndexTest::OPTIONS),
        "rewrite-payload" => Step.new(handler: Steps::RewritePayload, run: true),
        "rewrite-rules" => Step.new(handler: Steps::RewriteRules, run: true),
        "rewrite-check" => Step.new(handler: Steps::RewriteCheck, run: true, input: true),
        "rewrite-prune" => Step.new(handler: Steps::RewritePrune, run: true, options: Steps::RewritePrune::OPTIONS,
                                    required: Steps::RewritePrune::REQUIRED),
        "rewrite-test" => Step.new(handler: Steps::Counterexamples::RewriteTest, run: true,
                                   options: Steps::Counterexamples::OPTIONS, required: Steps::Counterexamples::REQUIRED),
        "counterexample-payload" => Step.new(handler: Steps::Counterexamples::Payload, run: true,
                                             options: Steps::Counterexamples::OPTIONS,
                                             required: Steps::Counterexamples::REQUIRED),
        "counterexample-round" => Step.new(handler: Steps::Counterexamples::Round, run: true, input: true,
                                           options: Steps::Counterexamples::Round::OPTIONS,
                                           required: Steps::Counterexamples::Round::REQUIRED),
        "index-build" => Step.new(handler: Steps::IndexBuild, run: true, progress: true),
        "baseline" => Step.new(handler: Steps::Baseline, run: true),
        "index-baseline" => Step.new(handler: Steps::IndexBaseline, run: true),
        "candidate-runs" => Step.new(handler: Steps::CandidateRuns, run: true),
        "minimax" => Step.new(handler: Steps::Minimax, run: true),
        "result-comparison" => Step.new(handler: Steps::ResultComparison, run: true),
        "selection" => Step.new(handler: Steps::Selection, run: true),
        "report-payload" => Step.new(handler: Steps::ReportPayload, run: true)
      }.freeze
    end
  end
end
