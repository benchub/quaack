# frozen_string_literal: true

require_relative "driver/version"
require_relative "driver/cli"
require_relative "driver/burndown"
require_relative "driver/transport"

module Quaack
  # The driver. It runs on an engineer's laptop, outside the production
  # enclave, and never holds a production value. See README.md, "Where QUAACK
  # runs."
  module Driver
  end
end
