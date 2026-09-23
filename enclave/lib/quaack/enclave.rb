# frozen_string_literal: true

require "pg_query"
require_relative "enclave/version"
require_relative "enclave/cli"
require_relative "enclave/table_name"
require_relative "enclave/index_candidate"
require_relative "enclave/statistics"
require_relative "enclave/generator_two"

module Quaack
  # The enclave script. It runs on the production jump server and does
  # everything that touches a database or a real value. See README.md,
  # "Where QUAACK runs."
  module Enclave
  end
end
