# frozen_string_literal: true

module Quaack
  module Protocol
    # Why a result comparison refused, rule unsupported_order (DESIGN.md's
    # result-comparison): the check that refused, so the enclave and the
    # driver share one list, and the report names the check, not just the
    # rule. A reason is one of the enclave's own constants, set where the
    # check refuses, never text from Postgres, a query, or the data.
    #
    # - nondeterministic_collation: a nondeterministic collation can call
    #   values equal that print differently.
    # - hidden_tie: rows tied on every column the tiebreaker sorts by can
    #   differ in one it can't sort by.
    # - inner_cut: a LIMIT or OFFSET below the top level isn't
    #   deterministic.
    # - with_ties: FETCH FIRST ... WITH TIES.
    # - original_pick, rewrite_pick: an arbitrary pick (DISTINCT, DISTINCT
    #   ON, GROUP BY, min, max, or an aggregate that follows its rows'
    #   order) had a real choice on the data, in the original or the
    #   rewrite.
    # - unforceable_pick: a DISTINCT ON's pick can't be forced.
    # - pick_run_failed: a query with its picks forced or checked failed
    #   another way.
    # - unsteady_order: the rewrite's tiebreaker runs fit the original's tie
    #   groups but aren't reversed groups of their own.
    # - cut_tie: a LIMIT or OFFSET cuts a tie group in a way CutTies can't
    #   check, or a DISTINCT ON picks from one.
    # - unstable_original: the original has no LIMIT or OFFSET, but its two
    #   tiebreaker runs, over the same data, returned different rows.
    # - full_run_timed_out, full_run_too_many_rows: on production, a run
    #   without the LIMIT, to check a tie at the cut, timed out or held too
    #   many rows.
    module RefusalReasons
      NAMES = %w[nondeterministic_collation hidden_tie inner_cut with_ties original_pick rewrite_pick
                 unforceable_pick pick_run_failed unsteady_order cut_tie unstable_original
                 full_run_timed_out full_run_too_many_rows].freeze

      module_function

      def valid?(reason) = NAMES.include?(reason)
    end
  end
end
