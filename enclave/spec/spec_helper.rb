# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
GEM_ROOT = File.expand_path("..", __dir__)
# The root suite's spec_helper defines it too. The harness files shared from
# the root's spec/support, such as repo_gems.rb, find the repo by it.
REPO_ROOT = File.expand_path("..", GEM_ROOT)

require_relative "../../spec/support/test_postgres"
require_relative "support/leak_check"

# Runs Ruby in a child process that inherits this bundle. Specs use it so
# that what they check (loading a gem, running an executable) happens in a
# clean process, not one where other specs already loaded things.
def run_ruby(*)
  Open3.capture3(RbConfig.ruby, *)
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
  TestPostgres.configure(config)
  LeakCheck.configure(config)
end
