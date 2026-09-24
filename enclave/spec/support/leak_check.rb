# frozen_string_literal: true

require_relative "leak_check/sentinels"
require_relative "leak_check/scanner"
require_relative "leak_check/positive_control"
require_relative "leak_check/quaacks"
require_relative "leak_check/fixture"

# Leak tests for the trust boundary (README, "Trust boundary"): run a step on
# data that holds known sentinel values, and fail if any of them shows up in
# what the step puts out. Every enclave task that touches production values
# should have one. The enclave suite's spec_helper loads this file and calls
# LeakCheck.configure, so every enclave spec has expect_no_leaks.
#
# It lives in the enclave suite, not the root spec/support, since only the
# enclave holds production values. It reuses the root's IsolatedInstall and
# TestPostgres, the way the suite already reaches test_postgres.rb.
#
# A leak test has four parts:
#
#   sentinels = LeakCheck::Sentinels.new
#
# 1. Expose the step to the sentinels, in the positions real values take.
#    Sentinels gives a text literal, a word that's a valid identifier, a
#    nine-digit number, a date, a JSON object, and a LIKE pattern. For data
#    in Postgres, LeakCheck::Fixture.plant(test_database, sentinels) puts
#    them in rows, most common values, and histogram bounds, and gives a
#    query whose literals they are. For a fixture file with literals baked
#    in, name them with Sentinels.new(extra: { email: "..." }).
#
# 2. Run the step. For the real thing, the way the jump server runs it:
#
#      quaacks = LeakCheck::Quaacks.new       # its own temporary HOME
#      outcome = quaacks.run("intake", "--query", path, ...)
#      quaacks.remove                          # in an after hook
#
#    quaacks.run_ruby(source) runs Ruby the same way, such as CLI.main with
#    a test step plugged in. In-process specs can pass what they captured.
#
# 3. Show the exposure was real, so the test isn't vacuous: check that the
#    sentinels reached the step, such as by finding them in the run's store,
#    in pg_stats, or in the error the step raised.
#
# 4. Scan everything that leaves or could be shown:
#
#      expect_no_leaks(sentinels, outcome)
#      expect_no_leaks(sentinels, stdout: out.string, objects: { error:, verdict: })
#
#    It looks in stdout, stderr, the exit status, and each object: its
#    inspect and to_s, an error's message, detailed_message, full_message,
#    backtrace, and cause chain, and every instance variable, element, key,
#    and value inside. Before it scans, it runs LeakCheck.check_scanner!,
#    which plants each sentinel in each of those places and fails if the
#    scanner misses one, so a broken scanner can't pass a leak.
#
# Don't scan what's meant to hold production values, such as the store or
# an error the step raises and the CLI filters. Scan what goes out: the
# child's stdout and stderr, and the objects a step hands to egress.
module LeakCheck
  module Helpers
    # Fails, listing each sentinel found and where, if any sentinel of
    # sentinels is in outcome (a Quaacks::Outcome) or in the channels, the
    # stdout:, stderr:, status:, and objects: that LeakCheck.findings takes.
    # why goes at the front of the failure message.
    def expect_no_leaks(sentinels, outcome = nil, why: nil, **channels)
      channels = { stdout: outcome.stdout, stderr: outcome.stderr, status: outcome.status, **channels } if outcome
      LeakCheck.check_scanner!(sentinels)
      found = LeakCheck.findings(sentinels, **channels)
      message = "#{"#{why}: " if why}sentinels leaked:\n#{found.map { "  #{it}" }.join("\n")}"
      expect(found.map(&:to_s)).to eq([]), message
    end
  end

  module_function

  def configure(config) = config.include(Helpers)
end
