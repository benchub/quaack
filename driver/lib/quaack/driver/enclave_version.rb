# frozen_string_literal: true

require_relative "enclave_error"
require_relative "version"

module Quaack
  module Driver
    # Checks, before start or run touches a run, that the jump server's
    # quaacks is the version this driver speaks to, ENCLAVE_VERSION (DESIGN.md,
    # "Deploying the enclave"). The enclave's version reply is its gem's
    # VERSION constant, never anything read from a run.
    module EnclaveVersion
      # The jump server's quaacks is missing or another version. The
      # message says to run `quaack deploy`.
      class Mismatch < StandardError; end

      # What a version is shown as, so nothing else lands in a message.
      SHOWN = /\A[0-9A-Za-z.-]{1,32}\z/

      module_function

      def check!(transport, host)
        version = remote(transport, host)
        return if version == ENCLAVE_VERSION

        shown = version.is_a?(String) && SHOWN.match?(version) ? version : "of an unknown version"
        raise Mismatch, "#{host} has quaacks #{shown}, but this driver needs #{ENCLAVE_VERSION}. #{deploy(host)}"
      end

      def remote(transport, host)
        transport.call("version").messages.find { it["type"] == "version" }&.fetch("version", nil)
      rescue EnclaveError => e
        raise e if e.rule == "ssh_failed"

        raise Mismatch, "quaacks isn't installed on #{host}, or isn't on PATH for non-interactive ssh there. " \
                        "#{deploy(host)}", cause: nil
      end

      def deploy(host) = "Run `quaack deploy --host #{host}`."
    end
  end
end
