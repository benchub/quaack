# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Keeps specs off the developer's real anthropic and AWS credential files.
# The anthropic gem's Client constructor reads <config dir>/active_config
# even when it's handed an api_key, and its config dir is
# ~/.config/anthropic unless ANTHROPIC_CONFIG_DIR names another. The AWS
# SDK's credential chain, which the Bedrock adapter uses when it's handed no
# keys, reads ~/.aws/config and ~/.aws/credentials unless AWS_CONFIG_FILE
# and AWS_SHARED_CREDENTIALS_FILE name others, then asks the EC2 metadata
# endpoint unless AWS_EC2_METADATA_DISABLED is true. Its SSO and login
# caches under ~/.aws are read only for a profile in those files that names
# them. So this points each at an empty directory or file of its own, and
# turns the endpoint off, for the whole spec process and every child it
# starts. A child that starts from
# Bundler.with_unbundled_env loses them, so IsolatedInstall passes env
# along. The root and driver suites share it, and each suite's
# spec/network_guard_spec.rb tests it. AWSCredentials sets its own AWS files
# for a block, then puts these back.
module NoRealCredentials
  DIR = Dir.mktmpdir("quaack-anthropic-config")
  AWS_DIR = Dir.mktmpdir("quaack-aws-config")
  OWNER = Process.pid
  at_exit { FileUtils.rm_rf([DIR, AWS_DIR]) if Process.pid == OWNER }

  # The variables a child process needs to stay off the real files.
  ENV_VARS = {
    "ANTHROPIC_CONFIG_DIR" => DIR,
    "AWS_CONFIG_FILE" => File.join(AWS_DIR, "config"),
    "AWS_SHARED_CREDENTIALS_FILE" => File.join(AWS_DIR, "credentials"),
    "AWS_EC2_METADATA_DISABLED" => "true"
  }.freeze
  FileUtils.touch(ENV_VARS.values_at("AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE"))
  ENV.update(ENV_VARS)

  def self.env = ENV_VARS

  # The default credential files under HOME that with_trapped_home blocks.
  TRAPS = [".config/anthropic/active_config", ".aws/config", ".aws/credentials"].freeze

  # Runs the block with HOME at a new directory whose
  # .config/anthropic/active_config, .aws/config, and .aws/credentials are
  # directories, so anything that reads the default files under HOME raises
  # Errno::EISDIR, the way a sandbox that blocks the real ones raises
  # Errno::EPERM. Yields HOME.
  def self.with_trapped_home
    Dir.mktmpdir("quaack-trapped-home") do |home|
      TRAPS.each { FileUtils.mkdir_p(File.join(home, it)) }
      original = Dir.home
      begin
        ENV["HOME"] = home
        yield home
      ensure
        ENV["HOME"] = original
      end
    end
  end
end
