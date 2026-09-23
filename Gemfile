# frozen_string_literal: true

source "https://rubygems.org"

# One bundle for the whole repo, so development stays simple. Each gem
# still declares its own runtime dependencies in its gemspec, and
# spec/boundary_spec.rb checks that the enclave and driver gems never depend
# on each other.
gemspec path: "protocol"
gemspec path: "enclave"
gemspec path: "driver"

group :development do
  # Only the test database harness in spec/support/test_postgres.rb uses pg
  # for now, so it's a development gem. It isn't in any gemspec.
  gem "pg", "~> 1.6"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.0", require: false
end
