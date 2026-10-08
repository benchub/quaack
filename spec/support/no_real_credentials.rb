# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Keeps specs off the developer's real anthropic credential files. The
# anthropic gem's Client constructor reads <config dir>/active_config even
# when it's handed an api_key, and its config dir is ~/.config/anthropic
# unless ANTHROPIC_CONFIG_DIR names another. So this points
# ANTHROPIC_CONFIG_DIR at an empty directory of its own for the whole spec
# process and every child it starts. A child that starts from
# Bundler.with_unbundled_env loses it, so IsolatedInstall passes env along.
# The root and driver suites share it, and each suite's
# spec/network_guard_spec.rb tests it.
module NoRealCredentials
  DIR = Dir.mktmpdir("quaack-anthropic-config")
  OWNER = Process.pid
  at_exit { FileUtils.rm_rf(DIR) if Process.pid == OWNER }
  ENV["ANTHROPIC_CONFIG_DIR"] = DIR

  # The variables a child process needs to stay off the real files.
  def self.env = { "ANTHROPIC_CONFIG_DIR" => DIR }

  # Runs the block with HOME at a new directory whose
  # .config/anthropic/active_config is a directory, so anything that reads
  # the default config dir under HOME raises Errno::EISDIR, the way a
  # sandbox that blocks the real one raises Errno::EPERM. Yields HOME.
  def self.with_trapped_home
    Dir.mktmpdir("quaack-trapped-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".config", "anthropic", "active_config"))
      original = ENV.fetch("HOME", nil)
      begin
        ENV["HOME"] = home
        yield home
      ensure
        ENV["HOME"] = original
      end
    end
  end
end
