# frozen_string_literal: true

require "open3"
require "rbconfig"

# Task 20261002-1: each rule file can be required alone, with what its
# rewrites are made of, in a Ruby that has loaded nothing else of QUAACK.
RSpec.describe "A rewrite rule file required alone" do
  lib = File.expand_path("../lib", __dir__)
  shared = %w[rewrite_rules/literals rewrite_rules/rewrite]
  helpers = %w[rewrite_rules/catalog rewrite_rules/tree]
  rules = File.read(File.join(lib, "quaack/enclave/rewrite_rules.rb"))
              .scan(%r{require_relative "(rewrite_rules/[a-z_]+)"}).flatten - shared

  # Derived, so a new rule file is covered without editing this spec. The
  # directory listing is a second source: a rule the generator forgot to
  # require, or a require this spec's scan no longer matches, shows as a
  # difference. The helpers are the files the rules share, which the
  # generator doesn't require itself.
  it "covers every rule file in the rewrite_rules directory" do
    on_disk = Dir.children(File.join(lib, "quaack/enclave/rewrite_rules"))
                 .grep(/\.rb\z/).map { "rewrite_rules/#{it.delete_suffix(".rb")}" } - shared - helpers
    expect(rules).not_to be_empty
    expect(rules.sort).to eq(on_disk.sort)
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
