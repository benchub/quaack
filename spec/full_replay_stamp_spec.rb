# frozen_string_literal: true

require "json"
require_relative "spec_helper"
require_relative "../protocol/lib/quaack/protocol/version"
require_relative "../driver/lib/quaack/driver/version"
require_relative "../enclave/lib/quaack/enclave/version"

FULL_REPLAY_STAMP = File.join(REPO_ROOT, "spec", "fixtures", "full_replay_versions.json")

# The Rakefile stamps the versions it reads from the version files' text.
# This compares the stamp with the constants the gems load, so a stamp that
# misread them can't pass.
RSpec.describe "the full replay stamp" do
  it "matches the versions that last passed rake full" do
    skip "rake full refreshes the stamp after all suites pass" if FullReplay.on?

    current = {
      "protocol" => Quaack::Protocol::VERSION,
      "driver" => Quaack::Driver::VERSION,
      "enclave" => Quaack::Enclave::VERSION
    }
    stamped = File.exist?(FULL_REPLAY_STAMP) ? JSON.parse(File.read(FULL_REPLAY_STAMP)) : {}

    expect(stamped).to eq(current),
                       "The full replay stamp is stale for the current gem versions. Run `bundle exec rake full` " \
                       "and commit spec/fixtures/full_replay_versions.json."
  end
end
