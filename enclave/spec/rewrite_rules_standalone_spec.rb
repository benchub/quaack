# frozen_string_literal: true

require "open3"
require "rbconfig"

# Task 20261002-1: each rule file can be required alone, with what its
# rewrites are made of, in a Ruby that has loaded nothing else of QUAACK.
RSpec.describe "A rewrite rule file required alone" do
  lib = File.expand_path("../lib", __dir__)
  rules = File.read(File.join(lib, "quaack/enclave/rewrite_rules.rb"))
              .scan(%r{require_relative "(rewrite_rules/[a-z_]+)"}).flatten - %w[rewrite_rules/literals rewrite_rules/rewrite]

  it "covers every rule the generator requires" do
    expect(rules.size).to eq(12)
  end

  rules.each do |file|
    it "defines RewriteRules::Rewrite when it's #{file}" do
      out, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e",
                                    "require 'quaack/enclave/#{file}'; " \
                                    "p Quaack::Enclave::RewriteRules::Rewrite.members")
      expect([out, status.success?]).to eq(["[:tree, :assumptions]\n", true])
    end
  end
end
