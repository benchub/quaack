# frozen_string_literal: true

require_relative "protocol/version"
require_relative "protocol/whitelist"
require_relative "protocol/burndown"
require_relative "protocol/plan_nodes"
require_relative "protocol/index_sources"
require_relative "protocol/hidden_statistics"
require_relative "protocol/port"
require_relative "protocol/step_counts"
require_relative "protocol/error_rules"

module Quaack
  # The messages the driver and the enclave script exchange. Both sides load
  # this gem, so it must never depend on anything else.
  module Protocol
  end
end
