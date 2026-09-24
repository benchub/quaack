# frozen_string_literal: true

require "open3"
require "rbconfig"

GEM_ROOT = File.expand_path("..", __dir__)

# Tells Quaack::Driver::LLM::Client, in this process and every child process a
# spec starts, that specs are running, so it refuses to call the real API.
ENV["QUAACK_SPECS"] = "1"

# Runs Ruby in a child process that inherits this bundle. Specs use it so
# that what they check (running an executable) happens in a clean process,
# not one where other specs already loaded things.
def run_ruby(*)
  Open3.capture3(RbConfig.ruby, *)
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
end
