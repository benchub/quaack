# frozen_string_literal: true

require "tmpdir"

RSpec.describe RepoGems do
  it "loads a repo gemspec" do
    expect(described_class.load(File.join(REPO_ROOT, "enclave", "quaacks.gemspec")).name).to eq("quaacks")
  end

  it "names the gemspec it couldn't load" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.gemspec")
      File.write(path, "raise 'broken'\n")

      expect { described_class.load(path) }.to raise_error(RuntimeError, "couldn't load the gemspec #{path}")
    end
  end
end
