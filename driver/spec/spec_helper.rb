# frozen_string_literal: true

require "open3"
require "rbconfig"
require "timeout"

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
require_relative "../../spec/support/no_real_credentials"

# Runs Ruby in a child process that inherits this bundle. Specs use it so
# that what they check (running an executable) happens in a clean process,
# not one where other specs already loaded things.
def run_ruby(*)
  Open3.capture3(RbConfig.ruby, *)
end

# An LLM::Error's message without the request sizes LLM::Client adds to
# every failed ask, for specs about the rest of the message. It drops only
# a trailing report that's there, so a message without one is unchanged.
def sans_sizes(message) = message.sub(/ \[step [^\]]*\]\z/, "")

# Everything an error could show in a crash report or a debugger: the
# message, class, and inspect of it and each error in its cause chain, with
# the body an API error carries, and its full message with a backtrace,
# which prints the causes too.
def error_text(error)
  chain = []
  seen = error
  while seen
    chain << "#{seen.class}: #{seen.message} #{seen.inspect}"
    chain << seen.body.inspect if seen.respond_to?(:body)
    seen = seen.cause
  end
  [*chain, error.full_message(highlight: false)].join("\n")
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

# Fails an example that runs past a time limit, so a hang, such as a Pump
# bug that never returns, fails the suite with a clear message instead of
# hanging rake. The slowest example takes about 7s, and the longest wait any
# example allows for itself is 60s, so 120s stays clear of both even on a
# heavily loaded machine. QUAACK_EXAMPLE_TIME_LIMIT, in seconds, overrides
# it. The error isn't a StandardError, so an example's own rescue can't
# swallow it.
module ExampleTimeLimit
  DEFAULT = 120
  ENV_NAME = "QUAACK_EXAMPLE_TIME_LIMIT"

  class Exceeded < Exception; end # rubocop:disable Lint/InheritException

  def self.seconds(env = ENV) = Float(env.fetch(ENV_NAME, DEFAULT))

  def self.run(example, seconds: self.seconds)
    message = "ran past #{format("%g", seconds)}s, the per-example limit (#{ENV_NAME}). It probably hung."
    Timeout.timeout(seconds, Exceeded, message) { example.run }
  end
end

RSpec.configure do |config|
  config.around { ExampleTimeLimit.run(it) }
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.order = :random
  Kernel.srand config.seed
end
