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
    # (DESIGN.md's clock-anchor), and it's what every step runs, plans, or binds. Every entry has
    # one: a store written before anchoring is refused by StoreFormat, so
    # an entry without one raises KeyError rather than run unanchored.
    module RewriteEntry
      module_function

      def run_sql(entry) = entry.fetch("anchored_sql")
    end
  end
end
