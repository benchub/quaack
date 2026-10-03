# frozen_string_literal: true

require "json"
require_relative "spec_helper"

FULL_REPLAY_STAMP = File.join(REPO_ROOT, "spec", "fixtures", "full_replay_versions.json")
FULL_REPLAY_VERSION_FILES = {
  "protocol" => "protocol/lib/quaack/protocol/version.rb",
  "driver" => "driver/lib/quaack/driver/version.rb",
  "enclave" => "enclave/lib/quaack/enclave/version.rb"
}.freeze

RSpec.describe "the full replay stamp" do
  def version(path)
    File.read(File.join(REPO_ROOT, path))[/(?:^|\s)VERSION = "([^"]+)"/, 1]
  end

  it "matches the versions that last passed rake full" do
    skip "rake full refreshes the stamp after all suites pass" if FullReplay.on?

    current = FULL_REPLAY_VERSION_FILES.to_h { |name, path| [name, version(path)] }
    stamped = File.exist?(FULL_REPLAY_STAMP) ? JSON.parse(File.read(FULL_REPLAY_STAMP)) : {}

    expect(stamped).to eq(current),
                       "The full replay stamp is stale for the current gem versions. Run `bundle exec rake full` " \
                       "and commit spec/fixtures/full_replay_versions.json."
  end
end
