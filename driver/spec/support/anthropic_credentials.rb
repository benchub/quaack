# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The credentials the anthropic gem finds on its own, set up for a spec.
module AnthropicCredentials
  # Every variable the gem finds credentials in is unset, and its config
  # directory is an empty one, so nothing on this machine is found, for the
  # block. changes then set some. Yields the config directory.
  def without_anthropic_credentials(changes = {})
    Dir.mktmpdir("quaack-anthropic") do |dir|
      unset = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_BASE_URL
                 ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID ANTHROPIC_IDENTITY_TOKEN
                 ANTHROPIC_IDENTITY_TOKEN_FILE].to_h { [it, nil] }
      with_env(unset.merge("ANTHROPIC_CONFIG_DIR" => dir, **changes)) { yield dir }
    end
  end

  # Writes the default profile `ant auth login` leaves, a user_oauth one,
  # into the config directory dir, with token as its access token, or none.
  def write_profile(dir, token)
    FileUtils.mkdir_p([File.join(dir, "configs"), File.join(dir, "credentials")])
    File.write(File.join(dir, "configs", "default.json"), JSON.generate(authentication: { type: "user_oauth" }))
    path = File.join(dir, "credentials", "default.json")
    File.write(path, JSON.generate(token ? { access_token: token } : {}))
    File.chmod(0o600, path)
  end
end
