# frozen_string_literal: true

require_relative "protocol/version"

module Quaack
  # The messages the driver and the enclave script exchange. Both sides load
  # this gem, so it must never depend on anything else.
  module Protocol
  end
end
