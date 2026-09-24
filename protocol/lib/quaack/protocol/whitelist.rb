# frozen_string_literal: true

module Quaack
  module Protocol
    # The one list of what may leave the production enclave (README, "Trust
    # boundary"). Each key is a type of message the enclave script prints,
    # and its value is the only fields that message may carry. The enclave's
    # egress function sends each message as its type plus these fields, and
    # drops every other field and every message of a type not listed here.
    #
    # These are the fields of QUAACK's own messages, not database columns, so
    # this changes only when a step changes what it prints. Every field
    # listed here goes out as is, with no check on its value. So add a field
    # only if every value it can ever hold is shape-class data, and treat each
    # change to this file as a change to the trust boundary.
    WHITELIST = {
      # Derived statistics for one column, from step 3f. mcv_freqs are the
      # MCV frequencies without their values. low_card_values are the MCV
      # values themselves, and 3f sets them only for low-cardinality columns.
      column_stats: %i[table column n_distinct null_frac correlation mcv_freqs low_card_values].freeze,
      # A failed step: which step, which rule it broke, and the Postgres
      # SQLSTATE if there was one. Never the error's message text, which can
      # hold a real value.
      error: %i[step rule sqlstate].freeze,
      # The enclave script's version, from `quaacks --version`. It's the
      # gem's VERSION constant, never anything read from a run.
      version: %i[version].freeze,
      # The run `quaacks intake` started, for the driver to name in each
      # later call. run_id is only ever a Store run ID: the UTC time the run
      # started and eight random hex characters, never anything from the
      # operator's inputs.
      run: %i[run_id].freeze,
      # What `quaacks teardown` did with a run. run_id comes from argv, and
      # the CLI sends it back only once it matches the Store run ID form:
      # the UTC time the run started and eight random hex characters. store
      # is deleted or already_gone. next_step is always destroy_run_server,
      # since the enclave can't destroy the run server itself, so the
      # operator must. store and next_step are the enclave's own constants.
      # None of the three is ever read from the run.
      teardown: %i[run_id store next_step].freeze,
      # What `quaacks inventory` recorded, as shape only. major_version is
      # an Integer, production's server_version_num divided by 10,000, such
      # as 18. memory_known is true or false: whether the operator's memory
      # command gave the instance memory. The inventory itself, its settings,
      # locale names, and extensions, stays in the store.
      inventory: %i[major_version memory_known].freeze,
      # The README 15b burndown. Its values are nested Hashes, so unlike
      # every other field, they're checked on the way out: the egress
      # function sends them only if Protocol::Burndown.valid? passes, so
      # every count is an Integer and every key is a stage from
      # Protocol::Burndown::STAGES, a record field, or a lowercase word.
      # The enclave's store makes the same check on its burndown entry.
      # stages maps each stage to its searches and each search to its
      # counts. totals maps each work total to its count.
      burndown: %i[stages totals].freeze,
      # The last line of every call to the enclave script that succeeded,
      # after the step's own lines. It carries nothing.
      done: [].freeze
    }.freeze
  end
end
