# frozen_string_literal: true

require_relative "../private_files"
require_relative "../store"

module Quaack
  module Enclave
    # Store.teardown, kept apart from the rest of Store (store.rb). Require
    # this file to use it.
    class Store
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
      # it first, is :already_gone too. A base open would refuse, such as a
      # file, one under a directory it can't search, or a symlink, raises
      # BadBase, even with nothing at the run's path.
      #
      # A block, if given, gets the opened Store just before the delete, so
      # what it reads is from the same open the delete uses. An error from
      # it leaves the run alone. The block can run long, as destroy_command
      # can, so the run directory is checked again after it, as open checks
      # it. A run that fails that check is kept, and teardown raises BadRun,
      # as a rerun would.
      def self.teardown(run_id, base: default_base, current_uid: Process.euid)
        path = run_path(run_id, base)
        # A fast path only: the recheck below would say already_gone too.
        return :already_gone unless look_up(run_id, base) { PrivateFiles.lstat(path) }

        opened(run_id, path, base, current_uid) { yield it if block_given? }.teardown
        :deleted
      rescue BadBase
        # Not a run that went: the run's path can't be trusted to say.
        raise
      rescue Error
        # The run went while this call deleted it, as when another teardown
        # got there first. Anything else, or a recheck that can't look, is
        # raised again.
        raise if path.nil? || still_there?(path)

        :already_gone
      end

      # Opens the run and yields it, then checks the run directory again, as
      # open checks it, since the block can run long.
      def self.opened(run_id, path, base, current_uid)
        store = self.open(run_id, base:, current_uid:)
        yield store
        check_run_directory(run_id, path, base, current_uid)
        store
      end

      def self.still_there?(path)
        PrivateFiles.lstat(path)
      rescue SystemCallError
        true
      end
      private_class_method :opened, :still_there?
    end
  end
end
