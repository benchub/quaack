# frozen_string_literal: true

require "pg_query"
require_relative "enclave/version"
require_relative "enclave/cli"

module Quaack
  # The enclave script. It runs on the production jump server and does
  # everything that touches a database or a real value. See README.md,
  # "Where QUAACK runs."
  module Enclave
  end
end
