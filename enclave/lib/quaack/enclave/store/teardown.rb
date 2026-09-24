# frozen_string_literal: true

require_relative "../private_files"
require_relative "../store"

module Quaack
  module Enclave
    # Store.teardown, kept apart from the rest of Store (store.rb). Require
    # this file to use it.
    class Store
      # What teardown raises for a base it can't look in.
      class BadBase < Error; end

      # Deletes the run's directory by run ID, for `quaacks teardown`. It
      # returns :deleted, or :already_gone if nothing is at the run's path,
      # so a second teardown of a run succeeds too. The run ID is checked as
      # open checks it, so it can't name a path outside base. Anything else
      # at the run's path must be a run directory open would open, or it's
      # left alone and teardown raises BadRun: it never deletes through a
      # symlink, which could point out of the store. A symlink inside the
      # run directory is removed, not followed.
      #
      # A run that vanishes partway, as when another teardown of it deletes
      # it first, is :already_gone too. A base it can't look in, such as a
      # file or one under a directory it can't search, raises BadBase.
      def self.teardown(run_id, base: default_base, current_uid: Process.euid)
        path = run_path(run_id, base)
        return :already_gone unless PrivateFiles.lstat(path)

        self.open(run_id, base:, current_uid:).teardown
        :deleted
      rescue SystemCallError
        raise BadBase, "couldn't look up run #{run_id} in the store's base", cause: nil
      rescue Error
        # The run went while this call deleted it, as when another teardown
        # got there first. Anything else is raised again.
        raise if path.nil? || PrivateFiles.lstat(path)

        :already_gone
      end
    end
  end
end
