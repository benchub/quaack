# frozen_string_literal: true

require "open3"
require "rbconfig"

GEM_ROOT = File.expand_path("..", __dir__)
REPO_ROOT = File.expand_path("..", GEM_ROOT)

require_relative "support/enclave_commands"

# Tells Quaack::Driver::LLM::Client, in this process and every child process a
# spec starts, that specs are running, so it refuses to call the real API.
ENV["QUAACK_SPECS"] = "1"
# Lets the enclave script run from this checkout, whose bundle holds the
# driver gem. Without it, quaacks refuses with driver_present.
ENV["QUAACKS_DEV_CHECKOUT"] = "1"
require_relative "../../spec/support/no_network"

# Runs Ruby in a child process that inherits this bundle. Specs use it so
# that what they check (running an executable) happens in a clean process,
# not one where other specs already loaded things.
def run_ruby(*)
  Open3.capture3(RbConfig.ruby, *)
end

# Sets each environment variable in changes, a nil value unsetting it, for
# the block, then puts every one back.
def with_env(changes)
  original = changes.keys.to_h { [it, ENV.fetch(it, nil)] }
  changes.each { |k, v| ENV[k] = v }
  yield
ensure
  original&.each { |k, v| ENV[k] = v }
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
end
