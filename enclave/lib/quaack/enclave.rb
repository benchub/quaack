# frozen_string_literal: true

require "pg_query"
require_relative "enclave/version"
require_relative "enclave/cli"
require_relative "enclave/egress"
require_relative "enclave/error_filter"
require_relative "enclave/connections"
require_relative "enclave/store"
require_relative "enclave/table_name"
require_relative "enclave/index_candidate"
require_relative "enclave/statistics"
require_relative "enclave/generator_one"
require_relative "enclave/generator_two"
require_relative "enclave/relation_qualifier"
require_relative "enclave/canonical_plan"
require_relative "enclave/predicate_atoms"
require_relative "enclave/volatility_check"
require_relative "enclave/dedupe"
require_relative "enclave/single_candidate_test"
require_relative "enclave/arena_runner"
require_relative "enclave/result_comparator"
require_relative "enclave/result_comparison"
require_relative "enclave/supported_sql"
require_relative "enclave/rewrite_candidate_check"

module Quaack
  # The enclave script. It runs on the production jump server and does
  # everything that touches a database or a real value. See README.md,
  # "Where QUAACK runs."
  module Enclave
  end
end
