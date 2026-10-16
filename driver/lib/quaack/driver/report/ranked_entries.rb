# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the heading of each ranked candidate's entry in the
      # Ranking section's subsections (DESIGN.md's report).
      module RankedEntries
        # A ranked entry's heading, as HTML, after its rank. Its subsection's
        # title already says its kind, so it names only the rewrite, linked to
        # its SQL, and says "with new indices:" ahead of the list of them, or
        # that they're not recorded, without the label's entry.
        #
        #   entry_heading("rewrite_2:top:1")  # => '<a href="#rewrite-2">Rewrite Silver Fox</a>, with new indices:'
        #   entry_heading("original:top:1")   # => "With new indices:"
        #   entry_heading("rewrite_2:none")   # => '<a href="#rewrite-2">Rewrite Silver Fox</a>'
        def entry_heading(label)
          search = label.to_s.split(":").first
          name = rewrite_link(search) unless search == "original"
          indexes = new_indexes(label)
          return name if indexes && indexes.empty?

          with = "with new indices:#{" #{h Words::MISSING}" unless indexes}"
          name ? "#{name}, #{with}" : Words.upper(with)
        end

        # The rewrite's name, linked to its SQL, or unlinked if the payload doesn't hold it.
        def rewrite_link(search)
          r = rewrite_of(search) or return h(Words.rewrite(search, run_id))

          %(<a href="##{h anchor(search)}">#{h called(r)}</a>)
        end

        # The stored rewrite a label ran, or nil for the original query.
        def rewrite_of(label) = rewrites.find { it["rewrite"] == label.to_s.split(":").first }

        # The new indexes a label ran with, [] for none, or nil if the
        # payload doesn't say which, for a label whose name says it had some.
        def new_indexes(label)
          (entry = measured(label)) ? entry["indexes"] : ([] if label.to_s.end_with?(":none"))
        end
      end
    end
  end
end
