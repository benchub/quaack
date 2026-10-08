# frozen_string_literal: true

require_relative "../private_files"
require_relative "../store"
require_relative "teardown"

module Quaack
  module Enclave
    # Store.sweep, kept apart from the rest of Store (store.rb). Require
    # this file to use it.
    class Store
      # How old an unfinished run must be before sweep deletes it. An intake
      # takes seconds, so a run this old isn't one a concurrent intake is
      # still writing.
      ORPHAN_AGE = 24 * 60 * 60

      # The entry that says a run finished intake: the plan, which intake
      # writes last, once every check has passed (see Steps::Intake). Any
      # file at its name counts, even one that can't be read.
      FINISHED_ENTRY = "plan"

      # What the teardown block raises to keep a run that finished intake
      # after sweep first looked at it.
      class Finished < StandardError; end
      private_constant :Finished

      # Deletes every run under base that started more than ORPHAN_AGE
      # before now, by its run ID's time, and never finished intake: it has
      # no FINISHED_ENTRY. Such a run is an orphan, one an intake was
      # killed partway through, so it may hold production literals and no
      # one has its run ID. Each new run calls it (CLI#with_new_run).
      #
      # Each delete is Store.teardown's, so it never deletes through a
      # symlink or a run directory another user owns. A run that finished
      # just before the delete is kept, since the check runs again inside
      # teardown's block. Names that aren't run IDs are left alone.
      #
      # It never raises: a sweep that fails mustn't fail the new run. A run
      # it can't delete, or a base it can't list, is skipped quietly, and
      # the next run's sweep tries again. It returns nil.
      def self.sweep(base: default_base, now: Time.now, current_uid: Process.euid)
        orphan_candidates(base, now).each { sweep_one(it, base, current_uid) }
        nil
      rescue StandardError
        nil
      end

      def self.orphan_candidates(base, now)
        Dir.children(base).select { RUN_ID.match?(it) && started(it) <= now - ORPHAN_AGE }
      end

      def self.sweep_one(run_id, base, current_uid)
        teardown(run_id, base:, current_uid:) { raise Finished if it.entry?(FINISHED_ENTRY) }
      rescue StandardError
        nil
      end

      # The UTC time in the run ID's first part, or the far future for one
      # that isn't a time, so it's never swept.
      def self.started(run_id)
        Time.utc(*run_id.unpack("A4A2A2xA2A2A2").map { Integer(it, 10) })
      rescue ArgumentError, RangeError
        Time.utc(9999)
      end
      private_class_method :orphan_candidates, :sweep_one, :started
    end
  end
end
