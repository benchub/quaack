# frozen_string_literal: true

require_relative "enclave_error"
require_relative "transport/base"
require_relative "transport/local"
require_relative "transport/ssh"

module Quaack
  module Driver
    # The driver's side of the link to the enclave script (DESIGN.md, "Where
    # QUAACK runs"). A transport runs `quaacks <subcommand> [--name value
    # ...]`, with any larger input as one JSON object on stdin, waits for it
    # to end, and reads what it printed (see Reply):
    #
    #   transport = Transport::Ssh.new(host: "jump-1.example")
    #   transport.call("version").messages
    #   # => [{"type" => "version", "version" => "0.1.0"}]
    #
    # call (see Base#call) returns a Result, or raises EnclaveError if the
    # run failed. Transport::Ssh runs the script on the jump server, and
    # Transport::Local runs it here, in a child process, for tests. Neither
    # ever loads the enclave gem.
    module Transport
    end
  end
end
