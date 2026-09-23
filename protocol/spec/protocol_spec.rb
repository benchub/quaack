# frozen_string_literal: true

RSpec.describe "quaack-protocol" do
  # Both the driver and the enclave load this gem, so it must not pull in
  # anything else. Load it with RubyGems disabled and no bundle: if it needed
  # any other gem, the require would fail.
  it "loads on its own, with no other gems available" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::VERSION')
    end

    expect(out).to match(/\A\d+\.\d+\.\d+\z/), "stdout was #{out.inspect}, stderr was #{err}"
    expect(status).to be_success
  end
end
