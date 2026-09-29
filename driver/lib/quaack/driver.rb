# frozen_string_literal: true

require_relative "driver/version"
require_relative "driver/cli"
require_relative "driver/runs"
require_relative "driver/start"
require_relative "driver/burndown"
require_relative "driver/transport"
require_relative "driver/llm"
require_relative "driver/generator_three"
require_relative "driver/counterexamples"

module Quaack
  # The driver. It runs on an engineer's laptop, outside the production
  # enclave, and never holds a production value. See DESIGN.md, "Where QUAACK
  # runs."
  module Driver
  end
end
