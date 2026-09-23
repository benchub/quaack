# frozen_string_literal: true

require "open3"
require "rbconfig"

GEM_ROOT = File.expand_path("..", __dir__)

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
end
