# frozen_string_literal: true

require "quaack/protocol/candidate_kinds"

module Quaack
  module Driver
    module Report
      # The ranked candidates by kind of change (DESIGN.md's selection and report).
      module Kinds
        # What each kind (Protocol::CandidateKinds) is called above its ranked rows.
        KIND_NAMES = { "rewrite_new_indexes" => "A rewrite of your query, with new indexes",
                       "rewrite_same_indexes" => "A rewrite of your query, with no new indexes",
                       "original_new_indexes" => "Your query as it is, with new indexes" }.freeze

        # A ranked entry's kind: the payload's, else the one its label says.
        def kind_of(entry) = entry["kind"] || Protocol::CandidateKinds.of(entry["label"])

        # The ranked entries by kind, in the report's order, each as [kind, entries], with only the
        # kinds that have any. Each kind's entries stay in their ranked order.
        def ranked_by_kind
          Protocol::CandidateKinds::KINDS.filter_map do |kind|
            entries = top.select { kind_of(it) == kind }
            [kind, entries] unless entries.empty?
          end
        end
      end
    end
  end
end
