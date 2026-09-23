# frozen_string_literal: true

REPO_ROOT = File.expand_path("..", __dir__)

Dir[File.join(__dir__, "support", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
  TestPostgres.configure(config)
end
