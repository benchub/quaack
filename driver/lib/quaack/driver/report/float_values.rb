# frozen_string_literal: true

require_relative "format"
require_relative "rewrites"

module Quaack
  module Driver
    module Report
      # Mixed into View beside Rewrites. A rewrite's fate as HTML, escaped
      # as h escapes it, with Rewrites::FLOAT_PHRASE linked to
      # docs/float-values.md, in a new tab, when its fate says the rewrite
      # failed only on float noise (Rewrites#float_noise?, task
      # 20261111-192302-1).
      module FloatValues
        PAGE = "https://github.com/benchub/quaack/blob/main/docs/float-values.md"
        LINK = %(<a href="#{Format.h(PAGE)}" target="_blank" rel="noopener">#{Rewrites::FLOAT_PHRASE}</a>).freeze

        def fate_html(entry) = float_link(entry, Format.h(fate(entry)))
        def fate_line_html(entry) = float_link(entry, Format.h(fate_line(entry)))

        private

        def float_link(entry, html) = float_noise?(entry) ? html.sub(Rewrites::FLOAT_PHRASE, LINK) : html
      end
    end
  end
end
