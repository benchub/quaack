# frozen_string_literal: true

REPO_ROOT = File.expand_path("..", __dir__)

# Tells the driver's LLM client, in every child process a spec starts, that
# specs are running, so it refuses to call the real API.
ENV["QUAACK_SPECS"] = "1"

require_relative "../rakelib/full_replay"

Dir[File.join(__dir__, "support", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
  TestPostgres.configure(config)
end
