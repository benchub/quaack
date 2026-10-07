# frozen_string_literal: true

module Quaack
  module Driver
    VERSION = "0.1.17"
    # The quaacks version this driver speaks to. `quaack deploy` installs
    # it, and start and run refuse a jump server with any other. The driver
    # can't load the enclave gem, so it's written out here, and a spec
    # checks it against the enclave's VERSION.
    ENCLAVE_VERSION = "0.1.17"
  end
end
