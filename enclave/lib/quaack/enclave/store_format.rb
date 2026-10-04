# frozen_string_literal: true

module Quaack
  module Enclave
    # The store's format, which Store.create marks every new run with, as
    # its store_format entry. FORMAT changes when entry names or what they
    # hold change in a way that an older run would be misread by, such as
    # the step slugs that replaced DESIGN.md's old step IDs as burndown
    # stages. A run with another format, or none, was started by an older
    # version, and the CLI refuses to open it (see CLI#open_store).
    module StoreFormat
      FORMAT = 2
      ENTRY = "store_format"

      module_function

      def mark(store) = store.write(ENTRY, { "format" => FORMAT })

      # Whether this version started the run: its store_format entry holds
      # FORMAT. A missing or unreadable one is an older version's.
      def current?(store)
        store.entry?(ENTRY) && store.read(ENTRY) == { "format" => FORMAT }
      rescue Store::Error
        false
      end
    end
  end
end
