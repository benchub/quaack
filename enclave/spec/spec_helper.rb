# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
GEM_ROOT = File.expand_path("..", __dir__)
# The root suite's spec_helper defines it too. The harness files shared from
# the root's spec/support, such as repo_gems.rb, find the repo by it.
REPO_ROOT = File.expand_path("..", GEM_ROOT)

# What a parse refusal adds after its message, written out rather than taken
# from ParserVersion, so a spec sees the exact text that leaves the enclave.
PARSER_NOTE = "(pg_query parses with the Postgres 17 grammar; Postgres 18-only syntax isn't supported yet)"

require_relative "../../spec/support/test_postgres"
require_relative "support/leak_check"

# Runs Ruby in a child process that inherits this bundle. Specs use it so
# that what they check (loading a gem, running an executable) happens in a
# clean process, not one where other specs already loaded things.
def run_ruby(*)
  Open3.capture3(RbConfig.ruby, *)
end

# Lets exe/quaacks run from this checkout, whose bundle holds the driver gem.
# Without it, quaacks refuses (see cli_spec.rb).
ENV["QUAACKS_DEV_CHECKOUT"] = "1"

# What a step that reports counts prints when it succeeds: its step_counts
# line, its counts in whitelist order as egress writes them, then DONE.
def counts_then_done(**counts)
  require "quaack/protocol/whitelist"
  ordered = Quaack::Protocol::WHITELIST.fetch(:step_counts).select { counts.key?(it) }.to_h { [it, counts[it]] }
  raise ArgumentError, "not a step_counts field" unless ordered.size == counts.size

  "#{JSON.generate({ type: "step_counts", **ordered })}\n{\"type\":\"done\"}\n"
end

# Sets each environment variable in changes, a nil value unsetting it, for
# the block, then puts every one back.
def with_env(changes)
  original = changes.keys.to_h { [it, ENV.fetch(it, nil)] }
  changes.each { |k, v| ENV[k] = v }
  yield
ensure
  original.each { |k, v| ENV[k] = v }
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
  TestPostgres.configure(config)
  LeakCheck.configure(config)
end
