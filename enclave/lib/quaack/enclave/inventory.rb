# frozen_string_literal: true

require_relative "inventory/error"
require_relative "inventory/memory"
require_relative "inventory/production"

module Quaack
  module Enclave
    # Step 2's production inventory (README), which `quaacks inventory`
    # takes (see Steps::Inventory). The run keeps it as its inventory entry,
    # a Hash with:
    #
    # - server_version_num and major_version, such as 180001 and 18.
    # - extensions: each installed extension's name and version.
    # - memory_bytes: the instance memory, from the memory command, or nil
    #   when no command is configured.
    # - settings: shared_buffers, effective_cache_size, work_mem,
    #   random_page_cost, and jit.
    # - parallel_settings: every setting named for parallel query, plus
    #   max_worker_processes.
    # - plan_settings: production's own value of each setting the input
    #   plan's SETTINGS lists, or nil for one production doesn't have. The
    #   plan's values are the operator's session's, so they aren't used.
    # - database: pg_database's datname, datcollate, datctype,
    #   datlocprovider, datlocale, and datcollversion.
    # - default_text_search_config.
    #
    # Settings are as SHOW prints them, such as "128MB". It's all production
    # configuration, so it stays in the enclave.
    #
    # A failure is an Error (see Production and Memory for the rules), or a
    # Config::Error for the config.
    module Inventory
      module_function

      # The inventory of host, the run's server. plan is the run's EXPLAIN
      # output. memory_command is the config's, or nil.
      def take(host:, plan:, memory_command:)
        inventory = read(host, plan[0].fetch("Settings", {}).keys)
        memory = Memory.bytes(memory_command, host) if memory_command
        { **inventory, "memory_bytes" => memory }
      end

      def read(host, plan_settings)
        connection = Production.connect(host)
        Production.read(connection, plan_settings:)
      ensure
        connection&.close
      end
    end
  end
end
