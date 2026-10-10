# frozen_string_literal: true

module Quaack
  module Protocol
    # Why `quaacks intake` couldn't read the query or plan file (DESIGN.md's
    # input): the rules that may carry a reason, and the fixed causes the
    # enclave may name, so the enclave and the driver share one list. A
    # reason is never a path or an operating system message.
    module UnreadableReasons
      RULES = %w[query_unreadable plan_unreadable].freeze
      NAMES = %w[missing symlink not_regular_file permission_denied name_too_long io_error].freeze
    end
  end
end
