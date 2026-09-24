# frozen_string_literal: true

require_relative "../store"

module Quaack
  module Enclave
    class CLI
      # The store's base can't be used (Store::BadBase), so no run could be
      # started or opened. The CLI sends it as an error line with its rule
      # and exits EX_SOFTWARE, as for a step that fails, since it's the
      # jump server's setup at fault, not the call. It's raised with no
      # cause, since a Store::Error can name the base.
      class BadStoreBase < StandardError
        def self.from_store
          yield
        rescue Store::BadBase
          raise self, "bad_store_base", cause: nil
        end

        def rule = "bad_store_base"
      end
    end
  end
end
