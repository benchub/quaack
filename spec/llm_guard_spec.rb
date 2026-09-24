# frozen_string_literal: true

require "open3"
require "rbconfig"

# The root spec helper sets QUAACK_SPECS too, so a child process a root spec
# starts can't build a driver LLM client that calls the real API.
RSpec.describe "the LLM guard in a child process of the root suite" do
  it "refuses a real LLM client" do
    code = 'require "quaack/driver"; ' \
           'Quaack::Driver::LLM::Client.new(api_key: "k", burndown: Quaack::Driver::Burndown.new)'
    _, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(REPO_ROOT, "driver", "lib"), "-e", code)

    expect(status).not_to be_success
    expect(err).to include("RealClientInSpecs")
  end
end
