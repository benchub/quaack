# frozen_string_literal: true

require_relative "format"
require_relative "rewrites"
require_relative "words"

module Quaack
  module Driver
    module Report
      # Mixed into View beside Rewrites. A rewrite's fate as HTML, escaped
      # as h escapes it, with a phrase linked to the docs page that explains
      # it, in a new tab:
      # - Rewrites::FLOAT_PHRASE to docs/float-values.md, when its fate says
      #   the rewrite failed only on float noise (Rewrites#float_noise?, task
      #   20261111-192302-1).
      # - Words::UNSTABLE_PHRASE to docs/unstable-original.md, when its test
      #   refused unsupported_order because the original's own two runs
      #   differed (unstable_original, task 20261112-171103-1).
      module DocLinks
        DOCS = "https://github.com/benchub/quaack/blob/main/docs/"
        FLOAT_PAGE = "#{DOCS}float-values.md".freeze
        UNSTABLE_PAGE = "#{DOCS}unstable-original.md".freeze

        def self.link(page, phrase) = %(<a href="#{Format.h(page)}" target="_blank" rel="noopener">#{phrase}</a>)

        FLOAT_LINK = link(FLOAT_PAGE, Rewrites::FLOAT_PHRASE).freeze
        UNSTABLE_LINK = link(UNSTABLE_PAGE, Words::UNSTABLE_PHRASE).freeze

        def fate_html(entry) = doc_link(entry, Format.h(fate(entry)))
        def fate_line_html(entry) = doc_link(entry, Format.h(fate_line(entry)))

        private

        def doc_link(entry, html)
          return html.sub(Rewrites::FLOAT_PHRASE, FLOAT_LINK) if float_noise?(entry)
          return html.sub(Words::UNSTABLE_PHRASE, UNSTABLE_LINK) if unstable_original?(entry)

          html
        end

        def unstable_original?(entry) = entry["rule"] == "unsupported_order" && entry["reason"] == "unstable_original"
      end
    end
  end
end
