# frozen_string_literal: true

require_relative "enclave_error"
require_relative "transport/local"

module Quaack
  module Driver
    module Transport
      Result = Data.define(:messages)
    end
  end
end
