# frozen_string_literal: true

require_relative "../config"
require_relative "../inventory"

module Quaack
  module Enclave
    module Steps
      # `quaacks inventory --run <run ID>` (DESIGN.md's inventory): connects to the
      # run's production server, and records what later steps compare the
      # run server with, and what they need to know about production, in
      # the run's inventory entry (see Inventory).
      #
      # It reads the quaacks config first, so a bad one fails before any
      # connection, then reads production, then runs the memory command.
      # Anything that fails writes nothing.
      #
      # Its one line is shape only: the major version, an Integer, and
      # whether the memory is known, true or false. The settings, the locale
      # names, and the extensions are production configuration, and stay in
      # the store.
      module Inventory
        module_function

        def call(store:, **)
          config = Config.load
          inventory = Enclave::Inventory.take(production: Enclave::Inventory::Production.params(store),
                                              plan: store.read("plan"), memory_command: config.memory_command)
          store.write("inventory", inventory)
          [{ type: :inventory, major_version: inventory.fetch("major_version"),
             memory_known: !inventory.fetch("memory_bytes").nil? }]
        end
      end
    end
  end
end
