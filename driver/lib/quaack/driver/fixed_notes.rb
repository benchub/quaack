# frozen_string_literal: true

module Quaack
  module Driver
    # The driver's own fixed notes, by the enclave rule they follow
    # (EnclaveError#rule_with_note). The enclave's error line holds only the
    # rule, so the driver says what it means.
    module FixedNotes
      BY_RULE = {
        # The run's store is in an older format, whose entries this version
        # would misread.
        "run_from_older_version" => "an older version of QUAACK started this run, and this version can't " \
                                    "resume it. Start a new run with quaack start.",
        # run-server got neither all four flags nor a run_server_command.
        "run_server_unspecified" => "name the run server with --host, --port, --racetrack-db, and --arena-db, " \
                                    "or set run_server_command in ~/.quaack/config.json on the jump server",
        # intake refused quaack start's --captured-at.
        "bad_captured_at" => "--captured-at must be an ISO-8601 time with a zone, such as 2026-10-01T09:30:00Z " \
                             "or 2026-10-01T09:30:00-04:00, no earlier than 1970 and no more than one day ahead " \
                             "of the jump server's clock"
      }.freeze
    end
  end
end
