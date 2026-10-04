# frozen_string_literal: true

module Quaack
  module Enclave
    # A stored rewrite_<n> entry (see Steps::RewriteCheck).
    #
    #   RewriteEntry.run_sql(store.read("rewrite_1"))   # => the SQL to run or plan
    #
    # "sql" is the candidate as accepted, with its clock functions and
    # clock-literal placeholders as written: that's what the LLM and the
    # report see. "anchored_sql" is the same SQL anchored as the original is
    # (DESIGN.md's clock-anchor), and it's what every step runs, plans, or binds. An entry
    # without one (written before anchoring existed, or by a spec that
    # doesn't care about the clock) runs its "sql".
    module RewriteEntry
      module_function

      def run_sql(entry) = entry.fetch("anchored_sql") { entry.fetch("sql") }
    end
  end
end
