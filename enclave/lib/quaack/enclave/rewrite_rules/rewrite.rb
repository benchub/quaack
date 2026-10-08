# frozen_string_literal: true

module Quaack
  module Enclave
    module RewriteRules
      # One rule's rewrite: the rewritten query's PgQuery::ParseResult, and
      # the catalog facts it relies on (see RewriteRules).
      Rewrite = Data.define(:tree, :assumptions)
    end
  end
end
