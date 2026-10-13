# frozen_string_literal: true

REPO_ROOT = File.expand_path("..", __dir__)

# Tells the driver's LLM client, in every child process a spec starts, that
# specs are running, so it refuses to call the real API.
ENV["QUAACK_SPECS"] = "1"

# rewrite-test's fuzz search in every quaacks child a spec starts counts
# trials, a floor of 40 and a cap of 400, instead of running its 30-second
# floor (Fuzz::StopRule), so a replay's verdict never depends on the
# machine's speed and the suite stays fast.
ENV["QUAACKS_FUZZ_TRIALS"] = "40"

# rewrite-test's enumerate stage (task 20261012-3), which runs after a
# fuzz pass for up to 30 seconds, is off in every quaacks child a spec
# starts, so the recorded replays' verdicts stay what fuzz and rewrite-test
# decide. The enclave's own specs turn it on where they test it.
ENV["QUAACKS_ENUMERATE_WORLDS"] = "0"

require_relative "../rakelib/full_replay"

Dir[File.join(__dir__, "support", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
  TestPostgres.configure(config)
end
