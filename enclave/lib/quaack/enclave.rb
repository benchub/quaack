# frozen_string_literal: true

require "pg_query"
require_relative "enclave/version"
require_relative "enclave/cli"
require_relative "enclave/egress"
require_relative "enclave/table_name"
require_relative "enclave/index_candidate"
require_relative "enclave/statistics"
require_relative "enclave/generator_one"
require_relative "enclave/generator_two"
require_relative "enclave/relation_qualifier"
require_relative "enclave/canonical_plan"
require_relative "enclave/predicate_atoms"
require_relative "enclave/dedupe"

module Quaack
  # The enclave script. It runs on the production jump server and does
  # everything that touches a database or a real value. See README.md,
  # "Where QUAACK runs."
  module Enclave
  end
end
