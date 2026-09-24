# frozen_string_literal: true

require_relative "../version"

module Quaack
  module Enclave
    module Steps
      # `quaacks version`, or `quaacks --version`: the enclave script's
      # version, so the driver can check it's talking to the one it expects.
      module Version
        module_function

        def call(**) = [{ type: :version, version: VERSION }]
      end
    end
  end
end
