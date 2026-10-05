# frozen_string_literal: true

require_relative "report/view"

module Quaack
  module Driver
    # DESIGN.md's report: the main report, as HTML, from the enclave's report
    # message (`quaacks report-payload`). It's templated from the payload,
    # never written by an LLM, and every value is HTML-escaped. It's one
    # file: plain CSS, no scripts, and nothing loaded from the network.
    #
    #   Report.render(payload, run_id:, llm_calls: burndown.llm_calls)  # => HTML String
    #   Report.write(payload, run_id:, path:)  # => path
    #
    # It's written for a reader who hasn't read DESIGN.md, so it shows no
    # internal label, stage number, or verdict name where it has words: a
    # candidate is the query it ran and the indexes it ran with, not
    # original:top:1. The exception is a rewrite rule's name (rewrite-rules), which
    # DESIGN.md's report says to give, and which a bug report needs.
    #
    # It calls each rewrite by its name (RewriteNames), such as "Rewrite
    # Silver Fox", never by its number, which the payload gives as
    # rewrite_3: named gives the payload's rewrites their names, and Words
    # maps the number in a label to the name.
    #
    # In order, it shows:
    #
    # - A QUAACK bug, only if the payload's rule_bugs lists a rule-made
    #   rewrite that a test disproved (DESIGN.md's rewrite-rules).
    # - The verdict.
    # - The original query, then every stored rewrite, pretty-printed, each
    #   rewrite with its source and what became of it (Rewrites).
    # - The ranking, every measured label that isn't ranked and why
    #   (Candidates), and each ranked candidate's measurements.
    # - Why the winner reads fewer blocks, with each plan as a table of
    #   its steps (Plans), or, when the payload carries negative, why
    #   nothing beat the original (negative-result).
    # - The built indexes (Indexes).
    # - Who proposed what (Accountability).
    # - The burndown (burndown, Stages), each table under its funnel
    #   (Funnel), with llm_calls, the driver's own Burndown#llm_calls.
    #
    # Where the payload doesn't carry a count, the report says "not
    # recorded". It never shows a zero for something that wasn't counted.
    #
    # The files under report/ each say one part. The HTML and CSS are in
    # report/template.html.erb.
    module Report
      module_function

      def render(payload, run_id:, llm_calls: {}) = View.new(named(payload, run_id), run_id, llm_calls).render

      def write(payload, run_id:, path:, llm_calls: {})
        File.write(path, render(payload, run_id:, llm_calls:))
        path
      end

      # The payload with each rewrite, and each rule_bugs entry, given its
      # name in the run (RewriteNames) as "name", next to its number in
      # "rewrite". The enclave only knows the number, so the driver adds
      # the name. An entry with no number, or past the last name, gets nil.
      def named(payload, run_id)
        name = ->(entry) { entry.merge("name" => RewriteNames.name(run_id, RewriteNames.number(entry["rewrite"]))) }
        lists = %w[rewrites rule_bugs].select { payload[it] }
        payload.merge(lists.to_h { [it, payload[it].map(&name)] })
      end
    end
  end
end
